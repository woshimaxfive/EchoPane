"""Compose the EchoPane workspace, live session, and caption window."""

import sqlite3
import tkinter as tk
from dataclasses import replace
from datetime import datetime
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

import theme
from audition import VoiceAudition
from cloud import service_url
from history import CaptionHistory
from native_windows import monitor_work_area
from overlay import CaptionOverlay
from preferences import CAPTION_SIZES, load_appearance, load_sidebar_collapsed, save_appearance, save_sidebar_collapsed
from screen_view import ScreenPage
from session import LiveSession, Phase
from transcripts import TranscriptArchive, export_transcript
from usage import UsageHistory
from usage_view import UsagePage
from views import (
    APPEARANCE_TITLE, CAPTION_SAMPLE, CAPTION_SAMPLE_ORIGINAL, KEY_HINT, LIVE_TITLE,
    CaptionPage, LivePage, SessionBar, SettingsPage,
)
from window_frame import WindowFrame, set_window_transitions


DEFAULT_WINDOW_SIZE = (820, 560)
MIN_WINDOW_SIZE = (640, 460)


class LiveCaptions:
    def __init__(self, root):
        self.root = root
        usage_history = UsageHistory()
        self.session = LiveSession(usage_history)
        self.appearance = load_appearance()
        self.audition = None
        self.history = None
        self.archive = TranscriptArchive()
        self.saved_sessions = {}
        self.refresh_saved_sessions()
        self.save_on_finish = False
        self.archive_notice = ""
        self.closing = False
        self.validation_message = ""
        self.rendered_phase = Phase.IDLE
        self.rendered_active = False

        theme.configure(root)
        root.title("EchoPane")
        scale = max(1.0, float(root.tk.call("tk", "scaling")) * 0.75)
        self.default_geometry = self.configure_size(scale)
        root.geometry(self.default_geometry)
        root.columnconfigure(0, weight=1)
        root.rowconfigure(1, weight=1)

        self.header = theme.WindowHeader(root, scale)
        self.header.grid(row=0, column=0, sticky="ew")
        self.tabs = theme.Workspace(root, header=self.header, collapsed=load_sidebar_collapsed(), on_toggle=self.save_sidebar)
        self.tabs.grid(row=1, column=0, sticky="nsew")
        self.live = LivePage(self.tabs, self.input_changed, self.open_history, self.open_audition)
        self.caption = CaptionPage(
            self.tabs, self.appearance, scale,
            change_size=self.set_caption_size, change_background=self.set_caption_background,
            change_lock=self.set_caption_lock, change_bilingual=self.set_caption_bilingual, show_overlay=self.show_overlay,
        )
        self.usage_page = UsagePage(self.tabs, usage_history, self.session.current_usage, scale,
                                    open_live=lambda: self.tabs.select(self.live),
                                    can_recall=self.can_recall, open_history=self.open_history)
        self.settings = SettingsPage(self.tabs, self.input_changed)
        self.screen_page = ScreenPage(
            self.tabs, hide_windows=self.hide_capture_windows, configuration=self.settings.configuration,
            configure_service=lambda: self.show_input_page(self.settings, self.settings.key_entry),
        )
        for page, title, icon in (
            (self.live, LIVE_TITLE, "live"), (self.caption, APPEARANCE_TITLE, "captions"),
            (self.screen_page, "屏幕翻译", "screen"),
            (self.usage_page, "用量", "usage"), (self.settings, "设置", "settings"),
        ):
            self.tabs.add_page(page, title, icon)

        self.footer_divider = ttk.Frame(root, height=1, style="Divider.TFrame")
        self.footer_divider.grid(row=2, column=0, sticky="ew")
        self.footer = SessionBar(root, self.start, self.stop)
        self.footer.grid(row=3, column=0, sticky="ew")
        self.overlay = CaptionOverlay(
            root, self.appearance, self.dismiss_overlay, self.stop,
            self.step_caption_size, self.position_changed,
            change_background=self.set_caption_background, change_lock=self.lock_changed,
        )

        self.tabs.bind("<<NotebookTabChanged>>", self.render_session, add="+")
        self.live.refresh()
        root.protocol("WM_DELETE_WINDOW", self.close)
        root.update_idletasks()
        self.configure_frame()

    def configure_size(self, scale):
        screen_width, screen_height = self.root.winfo_screenwidth(), self.root.winfo_screenheight()
        work = monitor_work_area((0, 0, 1, 1))
        if work:
            screen_width, screen_height = work.right - work.left, work.bottom - work.top
        available = max(1, screen_width - 32), max(1, screen_height - 56)
        width, height = (min(round(value * scale), space) for value, space in zip(DEFAULT_WINDOW_SIZE, available))
        self.root.minsize(*(min(round(value * scale), size) for value, size in zip(MIN_WINDOW_SIZE, (width, height))))
        return f"{width}x{height}"

    def configure_frame(self):
        self.window_frame = WindowFrame(self.root)
        if self.window_frame.attach():
            self.header.show_controls(self.close)
            self.header.bind_drag(self.window_frame, self.tabs.brand, self.tabs.rail_divider)
            self.root.geometry(self.default_geometry)
        else:
            theme.color_title_bar(self.root)

    def hide_capture_windows(self):
        windows = [self.root]
        if self.history_open():
            windows.append(self.history)
        visible = [(window, window.state()) for window in windows if window.winfo_ismapped()]
        self.overlay.suspend_for_capture()
        for window, _state in reversed(visible):
            set_window_transitions(window, disabled=True)
            window.withdraw()

        def restore():
            for window, state in visible:
                if window.winfo_exists():
                    window.state(state)
                    set_window_transitions(window, disabled=False)
            self.overlay.resume_after_capture()

        return restore

    @property
    def running(self):
        return self.session.state.active

    def save_sidebar(self, collapsed):
        try:
            save_sidebar_collapsed(collapsed)
        except OSError:
            # A write failure should not prevent use of the current layout.
            pass

    def input_changed(self, *_args):
        self.validation_message = ""
        self.session.reset()
        self.render_session()

    def render_session(self, _event=None):
        state = self.session.state
        if state.active != self.rendered_active:
            self.live.set_active(state.active)
            self.settings.set_active(state.active)
            self.caption.set_active(state.active)
            self.overlay.set_active(state.active)
            self.rendered_active = state.active
        if state.phase is Phase.STOPPING and self.rendered_phase is not Phase.STOPPING:
            self.overlay.set_stopping()
        self.rendered_phase = state.phase
        self.live.set_levels(state.level, self.session.microphone_level)

        live_page = self.tabs.select() == str(self.live)
        if not live_page and not state.active:
            if self.footer.winfo_manager():
                self.footer_divider.grid_remove()
                self.footer.grid_remove()
            return
        if not self.footer.winfo_manager():
            self.footer_divider.grid()
            self.footer.grid()
        if state.phase is not Phase.IDLE:
            self.footer.show(state, "", "", compact=not live_page)
            return
        if not self.live.input_ready():
            label, detail = "待选择音源", self.live.source_prompt()
        elif not self.settings.configuration()[0]:
            label, detail = "待配置", KEY_HINT
        else:
            label, detail = "可以开始", "字幕会显示在桌面浮窗。"
        self.footer.show(state, label, self.validation_message or detail)

    def show_input_page(self, page, field):
        self.tabs.select(page)
        if self.root.state() == "iconic":
            self.root.deiconify()
        field.focus_set()

    def start(self):
        if self.running or self.audition is not None:
            return
        field = self.live.source
        try:
            open_source = self.live.capture_factory()
            field = self.live.call_microphone
            microphone = self.live.microphone_factory()
        except RuntimeError as exc:
            self.session.reset()
            self.validation_message = str(exc)
            self.show_input_page(self.live, field)
            self.render_session()
            return
        configuration = self.service_configuration()
        if configuration is None:
            return

        self.tabs.select(self.live)
        self.validation_message = ""
        self.session.start(open_source, *configuration, bilingual=self.appearance.bilingual, microphone=microphone)
        if self.running:
            self.save_on_finish = False
            self.archive_notice = ""
            if self.history_open():
                if self.history.archive_id is None:
                    self.select_history_session(None)
                else:
                    self.update_history_choices()
            self.overlay.begin()
            self.root.after(40, self.poll)
        self.render_session()

    def open_audition(self):
        if self.running or self.audition is not None or self.live.mode != "call":
            return
        try:
            microphone = self.live.microphone_factory()
        except RuntimeError as exc:
            self.validation_message = str(exc)
            self.show_input_page(self.live, self.live.call_microphone)
            self.render_session()
            return
        configuration = self.service_configuration()
        if configuration is not None:
            self.audition = VoiceAudition(self.root, microphone, *configuration, on_close=self.audition_closed)

    def audition_closed(self):
        self.audition = None
        if self.closing:
            self.close()

    def service_configuration(self):
        key, workspace = self.settings.configuration()
        if not key:
            self.show_service_error(KEY_HINT, self.settings.key_entry)
            return
        try:
            service_url(workspace)
        except ValueError as exc:
            self.settings.show_advanced(True)
            self.show_service_error(str(exc), self.settings.workspace_entry)
        else:
            return key, workspace

    def show_service_error(self, message, field):
        self.session.reset()
        self.validation_message = message
        self.settings.notice.set(message)
        self.show_input_page(self.settings, field)
        self.render_session()

    def stop(self):
        self.session.stop()
        self.render_session()

    def close(self):
        self.closing = True
        if self.running:
            self.stop()
        elif self.audition is not None:
            self.audition.close()
        else:
            if self.save_on_finish and not self.save_current_transcript():
                messagebox.showwarning("字幕未更新", "无法更新本场字幕，已保留上次保存的版本。", parent=self.root)
            self.root.destroy()

    def poll(self):
        usage_changed = False
        usage_finished = False
        for kind, data in self.session.poll():
            if kind == "caption":
                self.overlay.set_captions(self.session.recent_captions(), original=self.session.latest_original())
                if self.history_open() and self.history.archive_id is None:
                    self.history.update_line(data.ident, self.session.caption_text(data.ident))
            elif kind == "usage":
                usage_changed = True
            else:
                usage_finished = True
                if self.closing:
                    self.close()
                    return
                if self.save_on_finish:
                    self.save_current_transcript()
                self.finish_overlay(kind, data)
        if self.usage_page.winfo_ismapped():
            if usage_finished:
                self.usage_page.refresh()
            elif usage_changed:
                self.usage_page.update_current()
        self.render_session()
        if self.running:
            self.root.after(40, self.poll)

    def finish_overlay(self, kind, message):
        if kind == "content_blocked":
            self.overlay.show_interruption("百炼内容审核中断")
        elif message and self.overlay.lines:
            self.overlay.show_interruption("翻译已中断")
        elif not self.overlay.lines:
            self.overlay.hide()

    def history_open(self):
        return self.history is not None and self.history.winfo_exists()

    def refresh_saved_sessions(self):
        try:
            self.saved_sessions = self.archive.sessions()
        except (OSError, sqlite3.Error):
            return False
        return True

    def can_recall(self, session_id):
        return session_id == self.session.recall_session_id() or session_id in self.saved_sessions

    def open_history(self, session_id=None):
        read_ok = self.refresh_saved_sessions()
        if session_id is not None and not self.can_recall(session_id):
            return
        if self.history_open():
            self.history.deiconify()
            self.history.lift()
        else:
            self.history = CaptionHistory(self.root, self.session.recall_anchor, self.select_history_session,
                                          self.save_current_transcript, self.export_history)

        record = self.session.transcript_record
        if session_id is None and record is None:
            session_id = self.history.archive_id or next(iter(self.saved_sessions), None)
        if record is not None and session_id == record.ident:
            session_id = None
        self.select_history_session(session_id)
        if session_id is None:
            self.history.go_recent()
            if not read_ok:
                self.history.show_notice("暂时无法读取本机保存的字幕。")
        self.history.text.focus_set()

    def update_history_choices(self):
        record = self.session.transcript_record
        self.history.show_sessions(self.saved_sessions, record.ident if record is not None else None)

    def select_history_session(self, session_id):
        if session_id is None:
            self.history.reset(self.session.transcript(), self.session.transcript_record)
            self.history.show_notice(self.archive_notice)
        else:
            try:
                transcript = self.archive.load(session_id)
            except (OSError, sqlite3.Error, ValueError, TypeError):
                transcript = None
            if transcript is None:
                self.history.show_notice("无法读取这场字幕。")
            else:
                entries = {index: text for index, (_, text) in enumerate(transcript.captions)}
                self.history.reset(entries, transcript, archived=True)
        self.update_history_choices()

    def save_current_transcript(self):
        transcript = self.session.transcript_snapshot()
        if transcript is None:
            return False
        try:
            self.archive.save(transcript)
        except (OSError, sqlite3.Error):
            saved = False
            self.archive_notice = "字幕保存失败，请重试。"
        else:
            saved = True
            self.saved_sessions[transcript.ident] = transcript.started_at
            self.save_on_finish = self.running
            self.archive_notice = "已保存到本机，结束时会更新。" if self.running else "已保存到本机。"
        if self.history_open() and self.history.archive_id is None:
            self.history.show_notice(self.archive_notice)
        return saved

    def export_history(self):
        transcript = self.history.saved_transcript or self.session.transcript_snapshot()
        if transcript is None:
            return
        started = datetime.fromtimestamp(transcript.started_at).strftime("%Y-%m-%d-%H%M%S")
        filename = filedialog.asksaveasfilename(parent=self.history, title="导出字幕", initialfile=f"EchoPane-{started}",
                                                defaultextension=".srt", confirmoverwrite=True,
                                                filetypes=(("SRT 字幕", "*.srt"), ("TXT 文本", "*.txt")))
        if not filename:
            return
        try:
            export_transcript(Path(filename), transcript)
        except OSError:
            self.history.show_notice("字幕导出失败，请检查目标目录后重试。")
        except ValueError as exc:
            self.history.show_notice(str(exc))
        else:
            self.history.show_notice(f"已导出 {Path(filename).name}。")

    def show_overlay(self):
        if not self.running and not self.overlay.lines and not self.overlay.interruption:
            original = CAPTION_SAMPLE_ORIGINAL if self.appearance.bilingual else None
            self.overlay.reset(CAPTION_SAMPLE, original=original)
        self.overlay.reveal()

    def dismiss_overlay(self):
        self.overlay.hide()
        self.stop()

    def set_caption_size(self, size):
        self.overlay.set_size(size)
        self.update_appearance(caption_size=size)

    def step_caption_size(self, step):
        index = CAPTION_SIZES.index(self.appearance.caption_size) + step
        if 0 <= index < len(CAPTION_SIZES):
            self.set_caption_size(CAPTION_SIZES[index])

    def set_caption_background(self, background):
        self.overlay.set_background(background)
        self.update_appearance(background=background)

    def set_caption_bilingual(self, bilingual):
        if not self.running:
            self.update_appearance(bilingual=bilingual)
            if self.overlay.winfo_viewable() and not self.overlay.lines and not self.overlay.interruption:
                self.show_overlay()

    def set_caption_lock(self, locked):
        self.overlay.set_locked(locked)

    def lock_changed(self, locked):
        self.update_appearance(locked=locked)

    def position_changed(self, position):
        self.update_appearance(position=position)

    def update_appearance(self, **changes):
        appearance = replace(self.appearance, **changes)
        if self.appearance == appearance:
            return
        self.appearance = appearance
        self.caption.show_appearance(appearance)
        try:
            save_appearance(appearance)
        except OSError:
            self.caption.notice.configure(text="外观已应用，保存失败。")
        else:
            self.caption.notice.configure(text="")


if __name__ == "__main__":
    main = tk.Tk()
    main.withdraw()
    LiveCaptions(main)
    main.update_idletasks()
    main.deiconify()
    main.mainloop()


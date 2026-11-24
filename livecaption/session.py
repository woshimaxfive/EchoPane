"""Own a live caption session and hand its events to the interface."""

import asyncio
import queue
import sqlite3
import threading
import time
from dataclasses import dataclass, replace
from enum import Enum
from itertools import islice
from uuid import uuid4

from websockets.exceptions import ConnectionClosed, InvalidStatus

from cloud import LIVE_MODEL, CaptionUpdate, ContentInspectionFailed, subtitles
from transcripts import Transcript
from usage import UsageRecord


AUDIO_LEVEL_THRESHOLD = 0.03
FIRST_CAPTION_QUIET_SECONDS = 8
WAITING_FOR_AUDIO = "已连接。请确认所选窗口正在播放声音。"


class Phase(Enum):
    IDLE = "待开始"
    CONNECTING = "正在连接"
    WAITING = "等待声音"
    LISTENING = "正在收音"
    TRANSLATING = "正在翻译"
    STOPPING = "正在停止"
    STOPPED = "已停止"
    INTERRUPTED = "已中断"


@dataclass(frozen=True)
class SessionState:
    phase: Phase = Phase.IDLE
    message: str = ""
    level: float = 0.0

    @property
    def active(self):
        return self.phase not in (Phase.IDLE, Phase.STOPPED, Phase.INTERRUPTED)


@dataclass(frozen=True)
class TranscriptCaption:
    text: str
    final: bool
    first_shown: float


class OriginalCaptions:
    """Track source text by the IDs supplied in the live service events."""

    def __init__(self):
        self.sources = {}
        self.translations = {}
        self.originals = {}

    def link(self, translation, original):
        if translation in self.sources:
            return ()
        self.sources[translation] = original
        self.translations.setdefault(original, []).append(translation)
        return (translation,) if self.text(translation) else ()

    def update(self, original):
        previous = self.originals.get(original.ident)
        if previous and previous.final and not original.final:
            return ()
        self.originals[original.ident] = original
        if original.text == (previous.text if previous else ""):
            return ()
        return self.translations.get(original.ident, ())

    def text(self, translation):
        original = self.originals.get(self.sources.get(translation))
        return original.text if original else ""


class LiveSession:
    def __init__(self, usage_history=None):
        self.events = queue.SimpleQueue()
        self.stop_flag = threading.Event()
        self.state = SessionState()
        self.usage_history = usage_history
        self.usage = None
        self.usage_start = None
        self.usage_save_failed = False
        self.finished_at = None
        self.last_audio_at = None
        self.captions = {}
        self.bilingual = False
        self.originals = OriginalCaptions()

    def start(self, open_source, key, workspace, *, bilingual=False):
        if self.state.active:
            return
        record = UsageRecord(uuid4().hex, time.time(), LIVE_MODEL)
        usage_start = (record, time.monotonic())
        self.stop_flag = threading.Event()
        self.state = SessionState(Phase.CONNECTING, "正在连接百炼…")
        worker = threading.Thread(
            target=self.run,
            args=(open_source, key, workspace, self.stop_flag, self.emit),
            kwargs={"usage_history": self.usage_history, "usage_start": usage_start,
                    "bilingual": bilingual}, daemon=True,
        )
        try:
            worker.start()
        except RuntimeError:
            self.state = SessionState(Phase.INTERRUPTED, "无法开始翻译，请重试。")
        else:
            self.usage = None
            self.usage_save_failed = False
            self.usage_start = usage_start
            self.finished_at = None
            self.captions.clear()
            self.bilingual = bilingual
            self.originals = OriginalCaptions()

    def emit(self, kind, data):
        self.events.put((kind, data))

    def stop(self):
        if self.state.active and self.state.phase is not Phase.STOPPING:
            self.stop_flag.set()
            message = "正在取消连接…" if self.state.phase is Phase.CONNECTING else "正在接收最后一段译文…"
            self.state = replace(self.state, phase=Phase.STOPPING, message=message)

    def reset(self):
        if not self.state.active:
            self.state = SessionState()

    def transcript(self):
        return {ident: self.caption_text(ident) for ident in self.captions}

    def caption_text(self, ident):
        caption = self.captions[ident].text
        original = self.originals.text(ident)
        return f"{original}\n{caption}" if original else caption

    def transcript_snapshot(self):
        record = self.transcript_record
        captions = tuple((caption.first_shown, self.caption_text(ident)) for ident, caption in self.captions.items()
                         if caption.text.strip())
        if record is not None and captions:
            return Transcript(record.ident, record.started_at, self.elapsed(), captions)

    def recent_captions(self):
        recent = list(islice(reversed(self.captions.items()), 2))
        return {ident: caption.text for ident, caption in reversed(recent)}

    def latest_original(self):
        if self.bilingual:
            return self.originals.text(next(reversed(self.captions), None))

    @property
    def transcript_record(self):
        return self.usage_start[0] if self.usage_start is not None else None

    def recall_session_id(self):
        record = self.transcript_record
        return record.ident if record is not None and self.captions else None

    def recall_anchor(self):
        if not self.captions:
            return None
        cutoff = self.elapsed() - 30
        for ident, caption in self.captions.items():
            if caption.first_shown >= cutoff:
                return ident
        return next(reversed(self.captions))

    def elapsed(self):
        if self.usage_start is None:
            return 0.0
        end = self.finished_at if self.finished_at is not None else time.monotonic()
        return end - self.usage_start[1]

    def current_usage(self):
        record = self.transcript_record
        if self.state.active and record is not None:
            return record.snapshot(self.elapsed(), self.usage)

    def poll(self):
        """Handle worker events on the UI thread and yield changes for the workspace."""
        for _ in range(64):
            try:
                kind, data = self.events.get_nowait()
            except queue.Empty:
                return

            phase = self.state.phase
            if kind == "status" and phase is Phase.CONNECTING:
                self.last_audio_at = None
                self.state = replace(self.state, phase=Phase.WAITING, message=WAITING_FOR_AUDIO)
            elif kind == "level" and phase is not Phase.STOPPING:
                now = time.monotonic()
                message = self.state.message
                if data > AUDIO_LEVEL_THRESHOLD:
                    self.last_audio_at = now
                    if phase is Phase.WAITING:
                        phase, message = Phase.LISTENING, "已收到声音，等待首条译文。"
                elif (phase is Phase.LISTENING and self.last_audio_at is not None
                      and now - self.last_audio_at >= FIRST_CAPTION_QUIET_SECONDS):
                    phase, message = Phase.WAITING, WAITING_FOR_AUDIO
                self.state = replace(self.state, phase=phase, message=message, level=data)
            elif kind == "caption":
                previous = self.captions.get(data.ident)
                if previous and previous.text == data.text and previous.final == data.final:
                    continue
                if previous and previous.final and not data.final:
                    continue
                if self.state.active and phase not in (Phase.STOPPING, Phase.TRANSLATING):
                    self.state = replace(self.state, phase=Phase.TRANSLATING, message="字幕显示在桌面浮窗。")
                first_shown = previous.first_shown if previous else self.elapsed()
                self.captions[data.ident] = TranscriptCaption(data.text, data.final, first_shown)
                yield kind, data
            elif self.bilingual and kind in ("caption_link", "original"):
                changes = self.originals.link(*data) if kind == "caption_link" else self.originals.update(data)
                for ident in changes:
                    if (caption := self.captions.get(ident)) is not None:
                        yield "caption", CaptionUpdate(ident, caption.text, caption.final)
            elif kind == "usage":
                if self.usage != data:
                    self.usage = data
                    yield kind, data
            elif kind == "usage_save_failed":
                self.usage_save_failed = True
            elif kind in ("end", "content_blocked"):
                message = data or "已停止。"
                if self.usage is not None:
                    audio, text = self.usage
                    message += f" 百炼用量（Token） 音频输入 {audio}，文本输出 {text}。"
                if self.usage_save_failed:
                    message += " 本次用量保存失败。"
                self.finished_at = time.monotonic()
                self.state = SessionState(Phase.INTERRUPTED if data else Phase.STOPPED, message)
                yield kind, data

    @staticmethod
    def save_usage(usage_history, usage_start, tokens, error, emit):
        if usage_history is not None and usage_start is not None:
            record, began = usage_start
            outcome = "interrupted" if error else "completed"
            try:
                usage_history.save(record.snapshot(time.monotonic() - began, tokens, outcome))
            except (OSError, sqlite3.Error):
                emit("usage_save_failed", None)

    @staticmethod
    def run(open_source, key, workspace, stop, emit, *, usage_history=None, usage_start=None,
            bilingual=False):
        end_event = "end"
        error = ""
        latest_usage = None
        capturing = False

        def forward(kind, data):
            nonlocal latest_usage, capturing
            if kind == "status":
                capturing = True
            elif kind == "usage":
                # Every response reports the cumulative usage for this connection.
                latest_usage = data
            emit(kind, data)

        try:
            asyncio.run(subtitles(open_source, key, workspace, stop, forward, bilingual=bilingual))
        except ContentInspectionFailed:
            end_event = "content_blocked"
            error = "百炼内容审核中断，字幕已停止。请等当前片段结束或切换音源后重新开始。"
        except InvalidStatus as exc:
            error = f"连接被拒绝（HTTP {exc.response.status_code}），请检查北京地域 Key、业务空间或网络。"
        except ConnectionClosed:
            error = "翻译连接已断开，请重新开始。"
        except TimeoutError:
            error = "服务响应超时，请检查网络后重试。"
        except Exception as exc:
            error = str(exc).replace(key, "[已隐藏]")[:200] or "翻译中断，请重试。"
        finally:
            if capturing or latest_usage is not None:
                LiveSession.save_usage(usage_history, usage_start, latest_usage, error, emit)
            emit(end_event, error)


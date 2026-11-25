"""Read and export timed subtitle files through the format library."""

from collections import Counter
from html import escape, unescape
from pathlib import Path
from tempfile import NamedTemporaryFile

import webvtt
from webvtt.errors import WebVTTError

from text_translation import MAX_TEXT_LENGTH


FORMATS = {".srt": "srt", ".vtt": "vtt", ".webvtt": "vtt"}


class SubtitleFileError(ValueError):
    """An import or export error suitable for the subtitle file page."""


class SubtitleFile:
    def __init__(self, path):
        self.path = Path(path)
        self.format = FORMATS.get(self.path.suffix.casefold())
        if self.format is None:
            raise SubtitleFileError("请选择 SRT 或 WebVTT 字幕文件。")
        try:
            with self.path.open("rb") as source:
                self.document = webvtt.from_buffer(source, format=self.format)
                if self.format == "vtt" and self.document.parse_issues:
                    # Some subtitle files use spaces on otherwise blank block separators.
                    source.seek(0)
                    lines = source.read().decode("utf-8-sig").split("\n")
                    normalized = "\n".join(line if line.strip(" \t\r") else "" for line in lines)
                    self.document = webvtt.from_string(normalized, format="vtt")
        except UnicodeError:
            raise SubtitleFileError("无法读取字幕编码。请将文件另存为 UTF-8 后再导入。") from None
        except WebVTTError:
            raise SubtitleFileError("文件内容与字幕格式不匹配，请检查文件后再导入。") from None
        if self.document.parse_issues:
            issue = self.document.parse_issues[0]
            raise SubtitleFileError(f"第 {issue.line} 行附近的字幕格式有误，请修正后再导入。")

        self.texts = []
        for index, cue in enumerate(self.document.captions, 1):
            if cue.end_in_milliseconds <= cue.start_in_milliseconds:
                raise SubtitleFileError(f"第 {index} 段的结束时间须晚于开始时间。")
            text = unescape(cue.text).strip()
            if len(text) > MAX_TEXT_LENGTH:
                raise SubtitleFileError(f"第 {index} 段超过 {MAX_TEXT_LENGTH} 字符，请拆成较短的字幕段。")
            self.texts.append(text)
        self.counts = Counter(text for text in self.texts if text)
        self.total = sum(self.counts.values())
        if not self.total:
            raise SubtitleFileError("这个文件没有可翻译的字幕正文。")

    def export(self, destination, translations, *, bilingual):
        path = Path(destination)
        if FORMATS.get(path.suffix.casefold()) != self.format:
            raise SubtitleFileError(f"请使用与原字幕相同的 {self.format.upper()} 格式。")
        if path.resolve() == self.path.resolve() or (
            path.exists() and self.path.exists() and path.samefile(self.path)
        ):
            raise SubtitleFileError("请选择另一个文件名保存译文，保留原字幕文件。")
        if not all(translations.get(text) for text in self.counts):
            raise SubtitleFileError("请完成翻译后再导出。")

        output = self.document.copy()
        for cue, text in zip(output.captions, self.texts, strict=True):
            if text:
                lines = [escape(line, quote=False) for line in translations[text].splitlines() if line.strip()]
                cue.lines = [*cue.lines, *lines] if bilingual else lines
        write_document(output, path, self.format)


def write_document(document, destination, format_name):
    pending = NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n", dir=destination.parent, delete=False)
    staging = Path(pending.name)
    try:
        with pending:
            document.write(pending, format=format_name, keep_formatting=True)
        staging.replace(destination)
    finally:
        staging.unlink(missing_ok=True)

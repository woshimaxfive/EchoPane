"""Turn recognized words into readable captions and export their media times."""

from dataclasses import dataclass
from datetime import timedelta
from html import escape
from pathlib import Path

import webvtt

from subtitle_file import FORMATS, SubtitleFileError, write_document


@dataclass(frozen=True)
class TimedText:
    start: int
    end: int
    text: str


def make_captions(block, words):
    captions = []
    body = ""
    start = end = block.start
    for word in sorted(words, key=lambda item: item.start):
        begin, finish = block.offset + word.start, block.offset + word.end
        if not word.text.strip() or not block.start <= (begin + finish) / 2 < block.end:
            continue
        begin = max(block.start, begin)
        finish = min(block.end, max(begin + 1, finish))
        if body and (
            begin - end >= 650
            or finish - start > 6500
            or len(body) + len(word.text) > 74
            or body.rstrip().endswith((".", "?", "!", "。", "？", "！", "…"))
        ) and begin > start:
            captions.append(TimedText(start, min(end, begin), " ".join(body.split())))
            body = ""
        if not body:
            start, end = begin, finish
        body += word.text
        end = max(finish, end)
    if body:
        captions.append(TimedText(start, end, " ".join(body.split())))
    return captions


def export_captions(destination, captions, translations=None):
    path = Path(destination)
    format_name = FORMATS.get(path.suffix.casefold())
    if format_name is None:
        raise SubtitleFileError("请选择 .srt 或 .vtt 扩展名。")
    if not captions or (translations is not None and not all(translations.get(cue.text) for cue in captions)):
        raise SubtitleFileError("请完成字幕生成后再导出。")
    cues = []
    for item in captions:
        lines = [escape(item.text, quote=False)]
        if translations is not None:
            lines.extend(escape(line, quote=False) for line in translations[item.text].splitlines() if line.strip())
        cues.append(webvtt.Caption(timedelta(milliseconds=item.start), timedelta(milliseconds=item.end), text=lines))
    write_document(webvtt.WebVTT(captions=cues), path, format_name)

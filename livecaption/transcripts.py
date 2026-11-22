"""Keep explicitly saved subtitle sessions and export their displayed text."""

import json
import sqlite3
import tempfile
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path

from preferences import appearance_path


@dataclass(frozen=True)
class Transcript:
    ident: str
    started_at: float
    seconds: float
    captions: tuple[tuple[float, str], ...]


class TranscriptArchive:
    def __init__(self):
        self.path = appearance_path().with_name("captions.sqlite3")

    def save(self, transcript):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        captions = json.dumps(transcript.captions, ensure_ascii=False, separators=(",", ":"))
        with closing(sqlite3.connect(self.path, timeout=0.2)) as db, db:
            db.execute("""CREATE TABLE IF NOT EXISTS transcripts (
                ident TEXT PRIMARY KEY NOT NULL,
                started_at REAL NOT NULL,
                seconds REAL NOT NULL,
                captions TEXT NOT NULL
            )""")
            db.execute("""INSERT INTO transcripts (ident, started_at, seconds, captions)
                          VALUES (?, ?, ?, ?)
                          ON CONFLICT (ident) DO UPDATE SET seconds = excluded.seconds, captions = excluded.captions
                       """, (transcript.ident, transcript.started_at, transcript.seconds, captions))

    def _read(self, statement, parameters=()):
        if not self.path.is_file():
            return []
        uri = self.path.absolute().as_uri() + "?mode=ro"
        with closing(sqlite3.connect(uri, uri=True, timeout=0.2)) as db:
            return db.execute(statement, parameters).fetchall()

    def sessions(self):
        return dict(self._read("SELECT ident, started_at FROM transcripts ORDER BY started_at DESC, ident"))

    def load(self, ident):
        rows = self._read("SELECT started_at, seconds, captions FROM transcripts WHERE ident = ?", (ident,))
        if rows:
            started_at, seconds, captions = rows[0]
            lines = tuple((shown, text) for shown, text in json.loads(captions))
            return Transcript(ident, started_at, seconds, lines)


def srt_timestamp(milliseconds):
    seconds, milliseconds = divmod(milliseconds, 1000)
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours:02}:{minutes:02}:{seconds:02},{milliseconds:03}"


def srt_text(transcript):
    starts = []
    previous = -1
    for shown, _text in transcript.captions:
        previous = max(previous + 1, round(shown * 1000))
        starts.append(previous)
    end = max(previous + 1, round(transcript.seconds * 1000))
    blocks = []
    for index, ((_, text), start, stop) in enumerate(zip(transcript.captions, starts, starts[1:] + [end]), 1):
        lines = "\n".join(line for line in text.splitlines() if line.strip())
        blocks.append(f"{index}\n{srt_timestamp(start)} --> {srt_timestamp(stop)}\n{lines}\n\n")
    return "".join(blocks)


def export_transcript(path, transcript):
    extension = path.suffix.casefold()
    if extension == ".srt":
        text = srt_text(transcript)
    elif extension == ".txt":
        text = "\n\n".join(text for _, text in transcript.captions) + "\n"
    else:
        raise ValueError("请选择 .srt 或 .txt 文件。")
    pending = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False)
    staging = Path(pending.name)
    try:
        with pending:
            pending.write(text)
        staging.replace(path)
    finally:
        staging.unlink(missing_ok=True)

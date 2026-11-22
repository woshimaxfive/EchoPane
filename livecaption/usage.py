"""Local usage records for translation sessions."""

import sqlite3
from contextlib import closing
from dataclasses import asdict, dataclass, replace

from preferences import appearance_path


# Beijing list prices in yuan per million tokens, also micro-yuan per token.
# https://help.aliyun.com/zh/model-studio/model-pricing
BEIJING_PRICES = {"qwen3.5-livetranslate-flash-realtime": (40, 100)}


@dataclass(frozen=True)
class UsageRecord:
    ident: str
    started_at: float
    model: str
    seconds: int = 0
    audio_tokens: int | None = None
    text_tokens: int | None = None
    estimated_micros: int | None = None
    outcome: str = "active"

    def snapshot(self, seconds, tokens, outcome="active"):
        audio, text = tokens if tokens is not None else (None, None)
        rates = BEIJING_PRICES.get(self.model)
        estimate = audio * rates[0] + text * rates[1] if tokens is not None and rates else None
        return replace(self, seconds=int(seconds), audio_tokens=audio, text_tokens=text,
                       estimated_micros=estimate, outcome=outcome)


class UsageHistory:
    def __init__(self):
        self.path = appearance_path().with_name("usage.sqlite3")

    def save(self, record):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with closing(sqlite3.connect(self.path, timeout=1.0)) as db, db:
            db.execute("""CREATE TABLE IF NOT EXISTS sessions (
                ident TEXT PRIMARY KEY NOT NULL,
                started_at REAL NOT NULL,
                model TEXT NOT NULL,
                seconds INTEGER NOT NULL,
                audio_tokens INTEGER,
                text_tokens INTEGER,
                estimated_micros INTEGER,
                outcome TEXT NOT NULL
            )""")
            db.execute("CREATE INDEX IF NOT EXISTS sessions_by_start ON sessions (started_at)")
            db.execute("""INSERT INTO sessions
                (ident, started_at, model, seconds, audio_tokens, text_tokens, estimated_micros, outcome)
                VALUES (:ident, :started_at, :model, :seconds, :audio_tokens, :text_tokens, :estimated_micros, :outcome)
                ON CONFLICT (ident) DO NOTHING
            """, asdict(record))

    def between(self, start, end):
        if not self.path.is_file():
            return []
        uri = self.path.absolute().as_uri() + "?mode=ro"
        with closing(sqlite3.connect(uri, uri=True, timeout=0.1)) as db:
            db.row_factory = sqlite3.Row
            rows = db.execute("""SELECT ident, started_at, model, seconds, audio_tokens, text_tokens,
                                      estimated_micros, outcome FROM sessions
                                 WHERE started_at >= ? AND started_at < ?
                                 ORDER BY started_at DESC, ident""", (start, end))
            return [UsageRecord(**row) for row in rows]

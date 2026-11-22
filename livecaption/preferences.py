"""Persist local appearance and workspace preferences separately from credentials."""

import json
import os
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path


CAPTION_SIZES = (16, 18, 22, 26)
DEFAULT_CAPTION_SIZE = 22
BACKGROUNDS = {"transparent": "透明", "shade": "窄暗底"}


@dataclass(frozen=True)
class CaptionAppearance:
    caption_size: int = DEFAULT_CAPTION_SIZE
    background: str = "transparent"
    position: tuple[int, int] | None = None
    locked: bool = False


def appearance_path():
    base = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
    return base / "EchoPane" / "appearance.json"


def read_preferences(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def load_appearance():
    data = read_preferences(appearance_path())
    size = data.get("caption_size")
    background = data.get("background")
    if type(size) is not int or size not in CAPTION_SIZES:
        size = DEFAULT_CAPTION_SIZE
    if not isinstance(background, str) or background not in BACKGROUNDS:
        background = "transparent"
    return CaptionAppearance(size, background, load_position(data), data.get("locked") is True)


def load_position(data):
    position = data.get("position")
    if (isinstance(position, list) and len(position) == 2
            and all(type(value) is int and abs(value) <= 65536 for value in position)):
        return tuple(position)
    bounds = data.get("bounds")
    if (isinstance(bounds, list) and len(bounds) == 4
            and all(type(value) is int and abs(value) <= 32768 for value in bounds)
            and bounds[2] > 0 and bounds[3] > 0):
        left, top, width, height = bounds
        return left + width // 2, top + height
    return None


def save_appearance(appearance):
    write_preferences(appearance_path(), asdict(appearance))


def load_sidebar_collapsed():
    data = read_preferences(appearance_path().with_name("workspace.json"))
    return data.get("sidebar_collapsed") is True


def save_sidebar_collapsed(collapsed):
    path = appearance_path().with_name("workspace.json")
    data = read_preferences(path)
    data["sidebar_collapsed"] = collapsed
    write_preferences(path, data)


def write_preferences(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False)
    staging = Path(pending.name)
    try:
        with pending:
            json.dump(data, pending, ensure_ascii=False)
        staging.replace(path)
    finally:
        staging.unlink(missing_ok=True)

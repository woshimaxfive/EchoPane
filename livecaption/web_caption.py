"""Receive the selected browser tab's current caption over a local connection."""

import asyncio
import json
import re
from dataclasses import dataclass
from hmac import compare_digest
from http import HTTPStatus
from secrets import token_urlsafe
from socket import create_server
from threading import Lock, Thread

from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed, NegotiationError


EXTENSION_ORIGIN = re.compile(r"chrome-extension://[a-p]{32}")
PLAYER_STATES = frozenset(("no_video", "no_track", "off", "loading", "track_error", "seeking", "ended", "playing", "paused"))


@dataclass(frozen=True)
class PlayerCaption:
    state: str
    track: str
    text: str
    upcoming: str

    @classmethod
    def read(cls, message):
        if not isinstance(message, str):
            raise ValueError("Expected a caption message")
        data = json.loads(message)
        if not isinstance(data, dict) or set(data) != {"state", "track", "text", "upcoming"}:
            raise ValueError("Invalid caption fields")
        for name, limit in (("state", 16), ("track", 80), ("text", 1500), ("upcoming", 1500)):
            value = data[name]
            if not isinstance(value, str) or len(value) > limit or "\x00" in value:
                raise ValueError("Invalid caption text")
            value.encode("utf-8")
        state = data["state"]
        text = data["text"].strip()
        upcoming = data["upcoming"].strip()
        if state not in PLAYER_STATES or (text and state not in ("playing", "paused")):
            raise ValueError("Invalid playback state")
        if upcoming and state != "playing":
            raise ValueError("Invalid upcoming caption")
        return cls(state, data["track"].strip(), text, upcoming)


class BrowserCaptionConnection:
    def __init__(self):
        self._lock = Lock()
        self._caption = None
        self._connected_once = False
        self._finished = False
        self._loop = asyncio.new_event_loop()
        try:
            self._socket = create_server(("127.0.0.1", 0))
        except OSError:
            self._loop.close()
            raise
        port = self._socket.getsockname()[1]
        token = token_urlsafe(18)
        self.code = f"{port}-{token}"
        self._host = f"127.0.0.1:{port}"
        self._protocol = f"echopane-v1.{token}"
        self._stop = asyncio.Event()
        Thread(target=self._run, name="EchoPane browser captions", daemon=True).start()

    def snapshot(self):
        with self._lock:
            return self._caption, self._finished

    def _check_request(self, connection, request):
        if request.path != "/" or request.headers.get_all("Host") != [self._host]:
            return connection.respond(HTTPStatus.FORBIDDEN, "Invalid browser connection")
        if self._stop.is_set() or self._connected_once:
            return connection.respond(HTTPStatus.CONFLICT, "Start a new browser connection in EchoPane")
        return None

    def _select_protocol(self, _connection, offered):
        if len(offered) == 1 and compare_digest(offered[0], self._protocol):
            return offered[0]
        raise NegotiationError("Invalid browser connection code")

    async def _receive(self, connection):
        if self._connected_once or self._stop.is_set():
            return
        self._connected_once = True
        try:
            while True:
                message = await asyncio.wait_for(connection.recv(), timeout=12)
                caption = PlayerCaption.read(message)
                with self._lock:
                    self._caption = caption
        except (ConnectionClosed, TimeoutError):
            pass
        except (ValueError, RecursionError):
            await connection.close(1007, "Invalid caption message")
        finally:
            with self._lock:
                self._caption = None
                self._finished = True
            self._stop.set()

    async def _serve(self):
        async with serve(
            self._receive, sock=self._socket, origins=[EXTENSION_ORIGIN], process_request=self._check_request,
            select_subprotocol=self._select_protocol, compression=None, server_header=None,
            open_timeout=3, close_timeout=0.25, max_size=24 * 1024, max_queue=4,
        ):
            await self._stop.wait()

    def _run(self):
        try:
            self._loop.run_until_complete(self._serve())
        except OSError:
            pass
        finally:
            self._socket.close()
            self._loop.close()
            with self._lock:
                self._caption = None
                self._finished = True

    def close(self):
        try:
            self._loop.call_soon_threadsafe(self._stop.set)
        except RuntimeError:
            # A disconnected browser may have already closed the listener.
            pass

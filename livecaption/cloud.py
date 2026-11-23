"""Beijing DashScope realtime speech translation, text output only."""
import asyncio
import base64
import json
import re
import time
from typing import NamedTuple

from websockets.asyncio.client import connect

from capture import pcm_level


LIVE_MODEL = "qwen3.5-livetranslate-flash-realtime"


class ContentInspectionFailed(RuntimeError):
    """Bailian rejected the session under its content review policy."""


class CaptionUpdate(NamedTuple):
    ident: str
    text: str
    final: bool


def service_host(workspace):
    host = "dashscope.aliyuncs.com"
    if workspace:
        if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", workspace.lower()):
            raise ValueError("百炼业务空间 ID 格式有误。")
        host = workspace + ".cn-beijing.maas.aliyuncs.com"
    return host


def service_url(workspace):
    return f"wss://{service_host(workspace)}/api-ws/v1/realtime?model={LIVE_MODEL}"


def check_event(event):
    if event.get("type") == "error" or event.get("code"):
        detail = event.get("error") or {}
        code = detail.get("code") or event.get("code") or "请求失败"
        if str(code).casefold() in ("data_inspection_failed", "datainspectionfailed"):
            raise ContentInspectionFailed(code)
        raise RuntimeError(f"百炼返回错误（{code}）。")


async def expect(ws, kind):
    async with asyncio.timeout(10):
        while True:
            event = json.loads(await ws.recv())
            check_event(event)
            if event.get("type") == kind:
                return


async def subtitles(open_source, key, workspace, stop, emit, *, bilingual=False):
    ready = False

    async def run_session():
        nonlocal ready
        async with connect(service_url(workspace), additional_headers={"Authorization": "Bearer " + key},
                           open_timeout=8, close_timeout=2, max_size=2**20) as ws:
            await expect(ws, "session.created")
            if stop.is_set():
                return
            await ws.send(json.dumps({"type": "session.update", "session": {
                "modalities": ["text"], "translation": {"language": "zh"},
                "input_audio_format": "pcm", "sample_rate": 16000,
                "input_audio_transcription": {"model": "qwen3-asr-flash-realtime" if bilingual else None},
            }}))
            await expect(ws, "session.updated")
            if stop.is_set():
                return
            ready = True
            await stream(ws, open_source, stop, emit, bilingual=bilingual)

    if stop.is_set():
        return
    connection = asyncio.create_task(run_session())
    try:
        # A stop during setup cancels the connection. Once streaming starts,
        # send session.finish so the final caption can still arrive.
        while not ready and not connection.done():
            if stop.is_set():
                return
            await asyncio.sleep(0.05)
        await connection
    finally:
        if not connection.done():
            connection.cancel()
            await asyncio.gather(connection, return_exceptions=True)


def emit_caption(event, emit, *, bilingual=False):
    kind = event.get("type")
    if kind in ("response.text.text", "response.text.done"):
        # Keep the confirmed prefix. The stash can be rewritten by the server.
        ident = event.get("item_id") or event.get("response_id")
        text = (event.get("text") or "").strip()
        if ident and text:
            emit("caption", CaptionUpdate(ident, text, kind == "response.text.done"))
    elif bilingual and kind == "conversation.item.created":
        item = event.get("item") or {}
        previous = event.get("previous_item_id")
        if item.get("role") == "assistant" and item.get("id") and previous:
            emit("caption_link", (item["id"], previous))
    elif bilingual and kind in (
        "conversation.item.input_audio_transcription.text",
        "conversation.item.input_audio_transcription.completed",
        "conversation.item.input_audio_transcription.failed",
    ):
        ident = event.get("item_id")
        final = not kind.endswith(".text")
        if kind.endswith(".failed"):
            text = ""
        else:
            text = (event.get("transcript" if final else "text") or "").strip()
        if ident and (text or final):
            emit("original", CaptionUpdate(ident, text, final))


async def stream(ws, open_source, stop, emit, *, bilingual=False):
    async def send_audio():
        if stop.is_set():
            return
        pending = bytearray()
        with open_source() as source:
            emit("status", "正在采音，译文显示在字幕窗。")
            meter = bytearray()
            next_level = time.monotonic() + 0.12
            while not stop.is_set():
                now = time.monotonic()
                pcm = source.read()
                pending.extend(pcm)
                meter.extend(pcm)
                if now >= next_level:
                    emit("level", pcm_level(meter))
                    meter.clear()
                    next_level = now + 0.12
                if len(pending) > 64000:
                    raise RuntimeError("音频发送积压超过两秒，请检查网络并重新开始。")
                while len(pending) >= 3200:
                    await send_chunk(bytes(pending[:3200]))
                    del pending[:3200]
                await asyncio.sleep(0.012)
            pending.extend(source.read(last=True))
        if pending:
            await send_chunk(bytes(pending))

    async def send_chunk(chunk):
        async with asyncio.timeout(4):
            await ws.send(json.dumps({"type": "input_audio_buffer.append",
                                      "audio": base64.b64encode(chunk).decode("ascii")}))

    async def receive():
        async for message in ws:
            event = json.loads(message)
            check_event(event)
            kind = event.get("type")
            if kind == "response.done":
                response = event.get("response") or {}
                usage = response.get("usage") or {}
                audio = (usage.get("input_tokens_details") or {}).get("audio_tokens")
                text = (usage.get("output_tokens_details") or {}).get("text_tokens")
                if type(audio) is int and audio >= 0 and type(text) is int and text >= 0:
                    emit("usage", (audio, text))
                if response.get("status") in ("failed", "incomplete"):
                    raise RuntimeError("本次翻译未完整返回，请重新开始。")
            elif kind == "session.finished":
                return
            else:
                emit_caption(event, emit, bilingual=bilingual)
        raise RuntimeError("翻译连接已经关闭。")

    sender = asyncio.create_task(send_audio())
    receiver = asyncio.create_task(receive())
    try:
        done, _ = await asyncio.wait((sender, receiver), return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
        if receiver in done and not stop.is_set():
            raise RuntimeError("云端已结束本次翻译，请重新开始。")
        if sender in done and receiver not in done:
            async with asyncio.timeout(4):
                await ws.send('{"type":"session.finish"}')
            await asyncio.wait_for(receiver, timeout=8)
    finally:
        for task in (sender, receiver):
            task.cancel()
        await asyncio.gather(sender, receiver, return_exceptions=True)


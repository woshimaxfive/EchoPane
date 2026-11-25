"""Beijing DashScope realtime speech translation for captions."""
import asyncio
import base64
import json
import re
import time
from socket import gaierror
from typing import NamedTuple

from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed, InvalidStatus, WebSocketException

from capture import pcm_level


LIVE_MODEL = "qwen3.5-livetranslate-flash-realtime"


class ContentInspectionFailed(RuntimeError):
    """Bailian rejected the session under its content review policy."""


class ServiceEventError(RuntimeError):
    def __init__(self, code):
        self.code = code
        super().__init__(f"百炼返回错误（{code}）。")


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
        raise ServiceEventError(code)


async def expect(ws, kind):
    async with asyncio.timeout(10):
        while True:
            event = json.loads(await ws.recv())
            check_event(event)
            if event.get("type") == kind:
                return


def subtitle_connection(key, workspace):
    return connect(service_url(workspace), additional_headers={"Authorization": "Bearer " + key},
                   open_timeout=8, close_timeout=2, max_size=2**20)


async def configure_subtitles(ws, caption_mode, *, terms=()):
    options = {
        "modalities": ["text"], "translation": {"language": "zh"},
        "input_audio_format": "pcm", "sample_rate": 16000,
        "input_audio_transcription": {
            "model": "qwen3-asr-flash-realtime" if caption_mode != "translation" else None,
        },
    }
    if terms and caption_mode != "original":
        options["translation"]["corpus"] = {"phrases": dict(terms)}
    await ws.send(json.dumps({"type": "session.update", "session": options}, ensure_ascii=False))
    await expect(ws, "session.updated")


def connection_test_error(code):
    code = str(code).casefold().replace("_", "").partition(".")[0]
    if code in ("401", "invalidapikey", "unauthorized", "authenticationerror"):
        return "百炼未接受当前 Key，请检查 Key、北京地域和业务空间是否匹配。"
    if code in ("403", "accessdenied", "permissiondenied"):
        return "百炼拒绝访问，请检查业务空间、实时翻译模型权限和账户状态。"
    if code in ("404", "notfound", "modelnotfound", "workspacenotfound"):
        return "百炼找不到业务空间或实时翻译模型，请核对业务空间和模型开通状态。"
    if code == "407":
        return "代理服务器要求验证，请检查系统代理设置。"
    if code in ("429", "throttling", "insufficientquota", "limitrequests", "ratelimitexceeded"):
        return "百炼触发限流或额度限制，请检查额度或稍后重试。"
    if code == "arrearage":
        return "百炼提示账户欠费，请到百炼控制台检查账户状态。"
    if code in ("500", "502", "503", "504", "internalerror", "serviceunavailable"):
        return "百炼服务暂时不可用，请稍后重试。"
    return "百炼未接受实时字幕连接，请核对业务空间和模型开通状态后重试。"


async def test_subtitle_connection(key, workspace):
    """Verify the realtime configuration without opening an audio source."""
    try:
        async with asyncio.timeout(12):
            async with subtitle_connection(key, workspace) as ws:
                await expect(ws, "session.created")
                await configure_subtitles(ws, "translation")
    except InvalidStatus as exc:
        return connection_test_error(exc.response.status_code)
    except ServiceEventError as exc:
        return connection_test_error(exc.code)
    except TimeoutError:
        return "连接百炼超时，请检查网络后重试。"
    except ConnectionClosed:
        return "百炼在确认配置前关闭了连接，请重试。"
    except gaierror:
        return "无法解析百炼服务地址，请检查网络、DNS 和业务空间 ID。"
    except (OSError, WebSocketException):
        return "无法连接百炼，请检查网络或代理设置后重试。"
    except (ValueError, TypeError, AttributeError):
        return "百炼未返回可识别的连接响应，请重试。"
    return "连接成功，百炼已接受实时字幕配置。"


async def subtitles(open_source, key, workspace, stop, emit, *, caption_mode="translation", terms=()):
    ready = False

    async def run_session():
        nonlocal ready
        async with subtitle_connection(key, workspace) as ws:
            await expect(ws, "session.created")
            if stop.is_set():
                return
            await configure_subtitles(ws, caption_mode, terms=terms)
            if stop.is_set():
                return
            ready = True
            await stream(ws, open_source, stop, emit, caption_mode=caption_mode)

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


def emit_caption(event, emit, *, caption_mode="translation"):
    kind = event.get("type")
    if kind in ("response.text.text", "response.text.done"):
        if caption_mode == "original":
            return
        # Keep the confirmed prefix. The stash can be rewritten by the server.
        ident = event.get("item_id") or event.get("response_id")
        text = (event.get("text") or "").strip()
        if ident and text:
            emit("caption", CaptionUpdate(ident, text, kind == "response.text.done"))
    elif caption_mode == "bilingual" and kind == "conversation.item.created":
        item = event.get("item") or {}
        previous = event.get("previous_item_id")
        if item.get("role") == "assistant" and item.get("id") and previous:
            emit("caption_link", (item["id"], previous))
    elif caption_mode != "translation" and kind in (
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
        if ident and caption_mode == "original" and text:
            emit("caption", CaptionUpdate(ident, text, final))
        elif ident and caption_mode == "bilingual" and (text or final):
            emit("original", CaptionUpdate(ident, text, final))


async def stream(ws, open_source, stop, emit, *, caption_mode="translation"):
    async def send_audio():
        if stop.is_set():
            return
        pending = bytearray()
        with open_source() as source:
            started_at = time.monotonic()
            emit("status", "正在采音，字幕会显示在浮窗。")
            meter = bytearray()
            next_level = started_at + 0.12
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
                emit_caption(event, emit, caption_mode=caption_mode)
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


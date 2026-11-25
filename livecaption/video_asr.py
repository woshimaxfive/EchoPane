"""Get word timestamps for one local audio block via the Bailian profile."""

import base64
import io
import json
import wave
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener

from cloud import service_host
from text_translation import NoRedirect
from video_audio import RATE
from video_captions import TimedText


ASR_MODEL = "fun-asr-flash-2026-06-15"


class RecognitionError(RuntimeError):
    """A transcription failure suitable for display without response content."""


def recognize(pcm, key, workspace):
    if not any(pcm):
        return ()
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as audio:
        audio.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        audio.writeframes(pcm)
    encoded = base64.b64encode(buffer.getvalue()).decode("ascii")
    request = Request(
        f"https://{service_host(workspace)}/api/v1/services/aigc/multimodal-generation/generation",
        data=json.dumps({
            "model": ASR_MODEL,
            "input": {"messages": [{"role": "user", "content": [
                {"type": "input_audio", "input_audio": {"data": "data:audio/wav;base64," + encoded}},
            ]}]},
            "parameters": {"format": "wav", "sample_rate": str(RATE)},
        }).encode("utf-8"),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json", "X-DashScope-SSE": "disable"},
    )
    try:
        with build_opener(NoRedirect()).open(request, timeout=45) as response:
            result = json.loads(response.read(2 * 1024 * 1024))["output"]
        if isinstance(result.get("text"), str) and not result["text"].strip():
            return ()
        sentence = result["sentence"]
        words = tuple(TimedText(word["begin_time"], word["end_time"], word["text"] + word.get("punctuation", ""))
                      for word in sentence["words"])
        if words and all(type(word.start) is int and type(word.end) is int and word.end >= word.start for word in words):
            return words
    except HTTPError as exc:
        exc.close()
        message = {
            400: "百炼未接受此音频片段，请检查文件或稍后重试。",
            401: "百炼未接受当前 Key，请检查翻译服务设置。",
            403: "当前 Key 无权调用视频转写，请检查百炼业务空间或模型权限。",
            429: "百炼暂时限制视频转写请求，请稍后续跑。",
        }.get(exc.code, f"百炼视频转写失败（HTTP {exc.code}）。")
        raise RecognitionError(message) from None
    except (URLError, OSError):
        raise RecognitionError("视频转写连接中断或超时，请检查网络后重试。") from None
    except (KeyError, TypeError, ValueError, AttributeError):
        pass
    raise RecognitionError("百炼未返回可用的逐词时间码，请重试当前片段。")

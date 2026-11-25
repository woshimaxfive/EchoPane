"""Translate text using the existing Beijing Bailian profile."""

import json
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener

from cloud import service_host
from glossary import matching_terms


TEXT_MODEL = "qwen-mt-flash"
MAX_TEXT_LENGTH = 6000


class TranslationError(RuntimeError):
    """A message suitable for display without logging the request or response."""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def translate(text, key, workspace, *, terms=()):
    if not text.strip() or len(text) > MAX_TEXT_LENGTH:
        raise TranslationError(f"请输入 1 至 {MAX_TEXT_LENGTH} 个字符。")
    options = {"source_lang": "auto", "target_lang": "Chinese"}
    matches = matching_terms(text, terms)
    if matches:
        options["terms"] = matches
    request = Request(
        f"https://{service_host(workspace)}/compatible-mode/v1/chat/completions",
        data=json.dumps({
            "model": TEXT_MODEL,
            "messages": [{"role": "user", "content": text}],
            "translation_options": options,
        }, ensure_ascii=False).encode("utf-8"),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        with build_opener(NoRedirect()).open(request, timeout=20) as response:
            data = json.loads(response.read(512 * 1024))
        result = data["choices"][0]["message"]["content"].strip()
        if result:
            return result
    except HTTPError as exc:
        exc.close()
        message = {
            400: "百炼未接受这段文字，请检查原文长度或内容。",
            401: "百炼未接受当前 Key，请检查翻译服务设置。",
            403: "当前 Key 无权调用百炼文本翻译，请检查业务空间和模型权限。",
            429: "百炼暂时限制请求，请稍后重试。",
        }.get(exc.code, f"百炼文本翻译请求失败（HTTP {exc.code}）。")
        raise TranslationError(message) from None
    except (URLError, OSError):
        raise TranslationError("无法连接百炼，或翻译响应超时。请检查网络后重试。") from None
    except (ValueError, KeyError, IndexError, TypeError, AttributeError):
        pass
    raise TranslationError("百炼未返回可显示的译文，请重试。")

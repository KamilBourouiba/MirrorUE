"""LM Studio local LLM — OpenAI-compatible chat API."""

from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.request

from .base import LLMResult, LLMUsage

DEFAULT_HOST = (
    os.environ.get("LMSTUDIO_HOST")
    or os.environ.get("MIRRORUE_LLM_HOST")
    or "http://127.0.0.1:1234"
).rstrip("/")
DEFAULT_MODEL = os.environ.get("MIRRORUE_LLM_MODEL", os.environ.get("LMSTUDIO_MODEL", ""))
DEFAULT_MAX_TOKENS = int(os.environ.get("MIRRORUE_LLM_MAX_TOKENS", "384"))


def _estimate_tokens(text: str) -> int:
    return max(1, len(text) // 4) if text else 0


def _api_base(host: str) -> str:
    base = host.rstrip("/")
    return base if base.endswith("/v1") else f"{base}/v1"


def _assistant_text(message: dict) -> str:
    content = (message.get("content") or "").strip()
    if content:
        return content
    reasoning = (message.get("reasoning_content") or "").strip()
    if not reasoning:
        return ""
    for pat in (
        r'\{[^{}]*"acts"\s*:\s*\[[^\]]*\][^{}]*\}',
        r'\{[^{}]*"see"\s*:[^{}]*\}',
        r'`(\{.*?\})`',
        r'(\{[^{}]*\})',
    ):
        if pat.startswith("`"):
            m = re.search(pat, reasoning, re.S)
            if m:
                return m.group(1).strip()
        else:
            matches = re.findall(pat, reasoning, re.S)
            if matches:
                return matches[-1].strip()
    lines = [ln.strip() for ln in reasoning.splitlines() if ln.strip()]
    return lines[-1] if lines else reasoning


class LMStudioProvider:
    name = "lmstudio"

    def __init__(self, host: str = DEFAULT_HOST, model: str = DEFAULT_MODEL) -> None:
        self.host = host.rstrip("/")
        self.model = model.strip()
        self.api_base = _api_base(self.host)

    def _list_models(self) -> list[str]:
        req = urllib.request.Request(f"{self.api_base}/models", method="GET")
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read().decode())
        rows = data.get("data") or []
        return [str(row.get("id", "")).strip() for row in rows if row.get("id")]

    def _resolve_model(self) -> str:
        if self.model:
            return self.model
        models = self._list_models()
        if not models:
            raise RuntimeError("LM Studio has no loaded models (load one in the app)")
        return models[0]

    def available(self) -> tuple[bool, str]:
        try:
            models = self._list_models()
            if not models:
                return False, "lmstudio reachable but no models loaded"
            resolved = self._resolve_model()
            if self.model and resolved not in models and not any(resolved in m for m in models):
                return True, f"lmstudio ok (model {self.model!r} not in list; loaded: {models[0]!r})"
            return True, f"ok ({resolved})"
        except Exception as e:  # noqa: BLE001
            return False, f"lmstudio unreachable at {self.host} ({e})"

    def chat(
        self,
        messages: list[dict[str, str]],
        *,
        max_tokens: int = DEFAULT_MAX_TOKENS,
        temperature: float = 0.0,
    ) -> LLMResult:
        model = self._resolve_model()
        body = {
            "model": model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "stream": False,
        }
        prompt_est = _estimate_tokens("\n".join(m.get("content", "") for m in messages))
        t0 = __import__("time").time()
        req = urllib.request.Request(
            f"{self.api_base}/chat/completions",
            data=json.dumps(body).encode(),
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                raw = json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            raise RuntimeError(f"LM Studio HTTP {e.code}: {detail}") from e
        except urllib.error.URLError as e:
            raise RuntimeError(f"LM Studio unreachable at {self.host}: {e.reason}") from e

        latency_ms = int((__import__("time").time() - t0) * 1000)
        choices = raw.get("choices") or []
        text = ""
        if choices:
            text = _assistant_text(choices[0].get("message") or {})
        usage_raw = raw.get("usage") or {}
        completion = usage_raw.get("completion_tokens")
        if not isinstance(completion, int):
            completion = _estimate_tokens(text)
        prompt_tokens = usage_raw.get("prompt_tokens")
        if isinstance(prompt_tokens, int):
            prompt_est = prompt_tokens
        return LLMResult(
            text=text,
            provider=self.name,
            model=model,
            usage=LLMUsage(prompt_est=prompt_est, completion=completion, latency_ms=latency_ms),
            raw=raw,
        )

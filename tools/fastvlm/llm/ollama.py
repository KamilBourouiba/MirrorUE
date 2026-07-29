"""Ollama local LLM — default text brain for MirrorUE agent."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

from .base import LLMResult, LLMUsage

DEFAULT_HOST = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434").rstrip("/")
DEFAULT_MODEL = os.environ.get("MIRRORUE_LLM_MODEL", os.environ.get("OLLAMA_MODEL", "llama3.2"))


def _estimate_tokens(text: str) -> int:
    return max(1, len(text) // 4) if text else 0


class OllamaProvider:
    name = "ollama"

    def __init__(self, host: str = DEFAULT_HOST, model: str = DEFAULT_MODEL) -> None:
        self.host = host.rstrip("/")
        self.model = model

    def available(self) -> tuple[bool, str]:
        try:
            req = urllib.request.Request(f"{self.host}/api/tags", method="GET")
            with urllib.request.urlopen(req, timeout=2) as resp:
                data = json.loads(resp.read().decode())
            models = [m.get("name", "") for m in data.get("models", [])]
            if not models:
                return False, "ollama running but no models pulled"
            if self.model.split(":")[0] not in " ".join(models):
                return True, f"ollama ok (model {self.model!r} may need: ollama pull {self.model})"
            return True, "ok"
        except Exception as e:  # noqa: BLE001
            return False, f"ollama unreachable at {self.host} ({e})"

    def chat(
        self,
        messages: list[dict[str, str]],
        *,
        max_tokens: int = 256,
        temperature: float = 0.0,
    ) -> LLMResult:
        body = {
            "model": self.model,
            "messages": messages,
            "stream": False,
            "options": {"num_predict": max_tokens, "temperature": temperature},
        }
        prompt_est = _estimate_tokens("\n".join(m.get("content", "") for m in messages))
        t0 = __import__("time").time()
        req = urllib.request.Request(
            f"{self.host}/api/chat",
            data=json.dumps(body).encode(),
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                raw = json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            raise RuntimeError(f"Ollama HTTP {e.code}: {detail}") from e
        except urllib.error.URLError as e:
            raise RuntimeError(f"Ollama unreachable at {self.host}: {e.reason}") from e

        latency_ms = int((__import__("time").time() - t0) * 1000)
        text = (raw.get("message") or {}).get("content") or ""
        completion = _estimate_tokens(text)
        usage_raw = raw.get("eval_count")
        if isinstance(usage_raw, int):
            completion = usage_raw
        return LLMResult(
            text=text.strip(),
            provider=self.name,
            model=self.model,
            usage=LLMUsage(prompt_est=prompt_est, completion=completion, latency_ms=latency_ms),
            raw=raw,
        )

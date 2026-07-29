"""Route text LLM requests to configured provider."""

from __future__ import annotations

import os
from typing import Any

from .base import LLMResult
from .lmstudio import DEFAULT_HOST as LMSTUDIO_HOST
from .lmstudio import DEFAULT_MODEL as LMSTUDIO_MODEL
from .lmstudio import LMStudioProvider
from .ollama import DEFAULT_HOST, DEFAULT_MODEL, OllamaProvider

_PROVIDERS: dict[str, type] = {
    "lmstudio": LMStudioProvider,
    "lm-studio": LMStudioProvider,
    "lm_studio": LMStudioProvider,
    "ollama": OllamaProvider,
}

_cached: Any = None


def get_provider(name: str | None = None) -> Any:
    global _cached
    key = (name or os.environ.get("MIRRORUE_LLM_PROVIDER", "lmstudio")).strip().lower()
    if key in ("none", "off", "disabled"):
        return None
    cls = _PROVIDERS.get(key)
    if cls is None:
        raise ValueError(f"unknown LLM provider {key!r} (available: {list(_PROVIDERS)})")
    if _cached is None or getattr(_cached, "name", "") != key:
        _cached = cls()
    return _cached


def llm_status(provider: str | None = None) -> dict[str, Any]:
    try:
        p = get_provider(provider)
    except ValueError as e:
        return {"ok": False, "provider": provider or "lmstudio", "error": str(e)}
    if p is None:
        return {"ok": True, "provider": "none", "enabled": False}
    ok, reason = p.available()
    return {
        "ok": ok,
        "provider": p.name,
        "model": getattr(p, "model", None) or (LMSTUDIO_MODEL if p.name == "lmstudio" else DEFAULT_MODEL),
        "host": getattr(p, "host", LMSTUDIO_HOST if p.name == "lmstudio" else DEFAULT_HOST),
        "enabled": True,
        "detail": reason,
    }


def chat(
    messages: list[dict[str, str]],
    *,
    provider: str | None = None,
    max_tokens: int = 256,
    temperature: float = 0.0,
) -> LLMResult:
    p = get_provider(provider)
    if p is None:
        raise RuntimeError("LLM provider disabled (MIRRORUE_LLM_PROVIDER=none)")
    return p.chat(messages, max_tokens=max_tokens, temperature=temperature)

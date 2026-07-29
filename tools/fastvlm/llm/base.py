"""LLM provider interface — extensible for Ollama, OpenAI, Anthropic, etc."""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Protocol


@dataclass
class LLMUsage:
    prompt_est: int = 0
    completion: int = 0
    latency_ms: int = 0

    def as_dict(self) -> dict[str, int]:
        return {
            "prompt_est": self.prompt_est,
            "completion": self.completion,
            "latency_ms": self.latency_ms,
        }


@dataclass
class LLMResult:
    text: str
    provider: str = "none"
    model: str = ""
    usage: LLMUsage = field(default_factory=LLMUsage)
    raw: dict[str, Any] = field(default_factory=dict)


class LLMProvider(Protocol):
    name: str

    def available(self) -> tuple[bool, str]: ...

    def chat(
        self,
        messages: list[dict[str, str]],
        *,
        max_tokens: int = 256,
        temperature: float = 0.0,
    ) -> LLMResult: ...

"""FastVLM load + inference with usage metrics."""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

_model = None
_processor = None
_config = None


@dataclass
class VlmUsage:
    prompt_est: int = 0
    completion: int = 0
    latency_ms: int = 0
    vision_units: int = 0

    def as_dict(self) -> dict[str, int]:
        return {
            "prompt_est": self.prompt_est,
            "completion": self.completion,
            "latency_ms": self.latency_ms,
            "vision_units": self.vision_units,
        }


@dataclass
class VlmResult:
    text: str
    usage: VlmUsage = field(default_factory=VlmUsage)
    raw: str = ""


def model_loaded() -> bool:
    return _model is not None


def load_vlm(model_path: str) -> None:
    global _model, _processor, _config
    if _model is not None:
        return
    from mlx_vlm import load
    from mlx_vlm.utils import load_config

    print(f"loading FastVLM from {model_path}…", flush=True)
    t0 = time.time()
    _model, _processor = load(model_path, trust_remote_code=True)
    _config = load_config(model_path)
    print(f"FastVLM ready in {time.time() - t0:.1f}s", flush=True)


def _estimate_tokens(text: str) -> int:
    if not text:
        return 0
    # Fast heuristic: ~4 chars/token for English; good enough for local metering.
    return max(1, len(text) // 4)


def vlm_ask(
    image: Path | None,
    question: str,
    max_tokens: int = 96,
    *,
    return_usage: bool = False,
) -> str | VlmResult:
    from mlx_vlm import generate
    from mlx_vlm.prompt_utils import apply_chat_template

    assert _model is not None and _processor is not None and _config is not None
    num_images = 1 if image and image.exists() else 0
    prompt = apply_chat_template(_processor, _config, question, num_images=num_images)
    prompt_est = _estimate_tokens(prompt)
    vision_units = 576 if num_images else 0  # ~720p patch budget equivalent

    t0 = time.time()
    result = generate(
        _model,
        _processor,
        prompt,
        image=str(image) if num_images else None,
        max_tokens=max_tokens,
        temperature=0.0,
        verbose=False,
    )
    latency_ms = int((time.time() - t0) * 1000)
    text = (getattr(result, "text", None) or str(result)).strip()
    completion = _estimate_tokens(text)

    if not return_usage:
        return text

    usage = VlmUsage(
        prompt_est=prompt_est,
        completion=completion,
        latency_ms=latency_ms,
        vision_units=vision_units,
    )
    return VlmResult(text=text, usage=usage, raw=text)


def vlm_status(model_path: str) -> dict[str, Any]:
    return {
        "loaded": model_loaded(),
        "model": model_path,
        "warm": model_loaded(),
    }

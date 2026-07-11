"""JSON helpers — numpy/scalar types from audio/ML code are not JSON-native."""

from __future__ import annotations

import datetime as _dt
import json
import uuid as _uuid
from typing import Any


def json_safe(value: Any) -> Any:
    """Recursively convert values to JSON-serializable Python builtins."""
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        return value

    if isinstance(value, _uuid.UUID):
        return str(value)
    if isinstance(value, (_dt.datetime, _dt.date)):
        return value.isoformat()

    mod = type(value).__module__
    name = type(value).__name__
    if mod == "numpy":
        import numpy as np

        if isinstance(value, np.ndarray):
            return json_safe(value.tolist())
        if isinstance(value, np.generic):
            return value.item()

    if isinstance(value, dict):
        return {str(k): json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(v) for v in value]

    return value


def dumps_json(value: Any, **kwargs: Any) -> str:
    return json.dumps(json_safe(value), **kwargs)

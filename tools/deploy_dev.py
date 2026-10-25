#!/usr/bin/env python3
"""Compatibility entrypoint for the soulPilot development deploy helper.

The implementation lives in dev_mode.py. Use dev_mode.py for new workflows.
"""
from __future__ import annotations

try:
    from dev_mode import main
except ImportError:  # pragma: no cover - package-style invocation
    from .dev_mode import main  # type: ignore


if __name__ == "__main__":
    raise SystemExit(main())

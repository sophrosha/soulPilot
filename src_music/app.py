#!/usr/bin/env python3
"""Compatibility entrypoint for the soulPilot music bridge.

The implementation lives in main.py; existing commands that call app.py keep
working. New code should import main.py directly.
"""
from __future__ import annotations

try:
    from main import build_parser, main, run
except ImportError:
    from .main import build_parser, main, run  # type: ignore


if __name__ == "__main__":
    raise SystemExit(main())

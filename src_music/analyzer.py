"""Analyzer access for the soulPilot music bridge.

The FFT/bass analyzer currently lives in capture.py next to the device code.
This module is the stable import surface for new callers.
"""
from __future__ import annotations

try:
    from capture import BassAnalyzer, format_state
except ImportError:
    from .capture import BassAnalyzer, format_state  # type: ignore

__all__ = ["BassAnalyzer", "format_state"]

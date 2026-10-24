#!/usr/bin/env python3
"""Compatibility wrapper for the soulPilot music GUI.

The PySide6 implementation lives in gui.py. Existing imports of ui.py keep
working; new code should import gui.py directly.
"""
from __future__ import annotations

try:
    from gui import CaptureWorker, MusicWindow, load_settings, run_ui, save_settings
except ImportError:
    from .gui import CaptureWorker, MusicWindow, load_settings, run_ui, save_settings  # type: ignore

__all__ = [
    "CaptureWorker",
    "MusicWindow",
    "load_settings",
    "save_settings",
    "run_ui",
]

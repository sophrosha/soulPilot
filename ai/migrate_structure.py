#!/usr/bin/env python3
"""One-time migration from AutopilotLive to the soulPilot repository layout.

The script is intentionally written for humans: each step is explicit and the
output explains what was moved or skipped. Run it from the repository root:

    python migrate_structure.py
    python migrate_structure.py --dry-run
    python migrate_structure.py --skip-tests

It performs only the structural migration. It does not change wheel tuning,
parking logic, UI behavior or game settings.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SRC = ROOT / "src"
SRC_CONFIG = SRC / "config"
SRC_MUSIC = ROOT / "src_music"
DOCS = ROOT / "docs"
DOCS_AI = DOCS / "ai"
DOCS_LANG = DOCS / "lang"
ASSETS = ROOT / "assets"

TEXT_SUFFIXES = {
    ".lua",
    ".json",
    ".vue",
    ".js",
    ".css",
    ".scss",
    ".html",
    ".md",
    ".txt",
    ".ini",
}

# The order matters: explicit old paths first, generic names last.
TOKEN_REPLACEMENTS = (
    ("settings/autopilotLive/", "settings/mod_settings/soulPilot/"),
    ("settings/autopilotLive", "settings/mod_settings/soulPilot"),
    ("mods/unpacked/AutopilotLive/ai/config/", "mods/unpacked/soulPilot/src/config/"),
    ("mods/unpacked/AutopilotLive/ai/music/", "mods/unpacked/soulPilot/src_music/"),
    ("mods/unpacked/AutopilotLive/", "mods/unpacked/soulPilot/"),
    ("AutopilotLive", "soulPilot"),
    ("autopilotLive", "soulPilot"),
    ("autopilotlive", "soulPilot"),
    ("ai/config/", "src/config/"),
    ("ai/music/", "src_music/"),
)


def log(message: str) -> None:
    print(f"[migrate] {message}")


def ensure_directories() -> None:
    for path in (
        SRC,
        SRC_CONFIG,
        SRC_MUSIC,
        DOCS_AI,
        DOCS_LANG / "gelua",
        DOCS_LANG / "vlua",
        DOCS / "ru",
        DOCS / "en",
        ASSETS,
    ):
        path.mkdir(parents=True, exist_ok=True)
        log(f"directory: {path.relative_to(ROOT)}")


def move_path(source: Path, target: Path) -> bool:
    """Move a file or directory if it exists; never overwrite a non-empty target."""
    if not source.exists():
        log(f"skip (missing): {source.relative_to(ROOT)}")
        return False
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        source.rename(target)
        log(f"move: {source.relative_to(ROOT)} -> {target.relative_to(ROOT)}")
        return True

    if source.is_file() or target.is_file():
        log(f"skip (target exists): {target.relative_to(ROOT)}")
        return False

    moved_any = False
    for child in sorted(source.iterdir()):
        child_target = target / child.name
        if child_target.exists():
            log(f"skip (target exists): {child_target.relative_to(ROOT)}")
            continue
        child.rename(child_target)
        moved_any = True
        log(f"move: {child.relative_to(ROOT)} -> {child_target.relative_to(ROOT)}")
    try:
        source.rmdir()
    except OSError:
        pass
    return moved_any


def move_selected_children(
    source: Path,
    target: Path,
    skip_names: set[str] | None = None,
    skip_suffixes: tuple[str, ...] = (),
) -> None:
    """Move selected children, for example Python runtime files."""
    if not source.exists():
        log(f"skip (missing): {source.relative_to(ROOT)}")
        return
    target.mkdir(parents=True, exist_ok=True)
    skip_names = skip_names or set()
    skipped: list[str] = []

    for child in sorted(source.iterdir()):
        if child.name in skip_names or child.name.endswith(skip_suffixes):
            skipped.append(child.name)
            continue
        child_target = target / child.name
        if child_target.exists():
            log(f"skip (target exists): {child_target.relative_to(ROOT)}")
            continue
        child.rename(child_target)
        log(f"move: {child.relative_to(ROOT)} -> {child_target.relative_to(ROOT)}")

    if skipped:
        log("kept in dev workspace: " + ", ".join(skipped))


def replace_name(value: str) -> str:
    for old, new in TOKEN_REPLACEMENTS:
        value = value.replace(old, new)
    return value


def rename_paths(base: Path) -> None:
    """Rename files and directories containing the old brand, bottom-up."""
    if not base.exists():
        return
    for root, dirnames, filenames in os.walk(base, topdown=False):
        root_path = Path(root)
        for name in filenames + dirnames:
            new_name = replace_name(name)
            if new_name == name:
                continue
            source = root_path / name
            target = root_path / new_name
            if target.exists():
                log(f"skip (rename target exists): {target.relative_to(ROOT)}")
                continue
            source.rename(target)
            log(f"rename: {source.relative_to(ROOT)} -> {target.relative_to(ROOT)}")


def replace_text_in_file(path: Path) -> bool:
    try:
        old_text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        log(f"skip (not UTF-8): {path.relative_to(ROOT)}")
        return False
    new_text = replace_name(old_text)
    if new_text == old_text:
        return False
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(new_text)
    log(f"rewrite: {path.relative_to(ROOT)}")
    return True


def replace_text_under(base: Path) -> None:
    if not base.exists():
        return
    for path in sorted(base.rglob("*")):
        if path.is_file() and path.suffix.lower() in TEXT_SUFFIXES:
            replace_text_in_file(path)


def strip_json_comments(value):
    if isinstance(value, dict):
        value.pop("_comment", None)
        for child in value.values():
            strip_json_comments(child)
    elif isinstance(value, list):
        for child in value:
            strip_json_comments(child)
    return value


def clean_config_json() -> None:
    if not SRC_CONFIG.exists():
        return
    for path in sorted(SRC_CONFIG.rglob("*.json")):
        with path.open(encoding="utf-8") as handle:
            data = json.load(handle)
        strip_json_comments(data)
        with path.open("w", encoding="utf-8", newline="\n") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        log(f"json (_comment removed): {path.relative_to(ROOT)}")


def update_gitignore() -> None:
    path = ROOT / ".gitignore"
    required = ("ai/", "venv/", "__pycache__/", "dist/", "*.zip")
    existing = path.read_text(encoding="utf-8") if path.exists() else ""
    missing = [line for line in required if line not in existing.splitlines()]
    if not missing:
        return
    with path.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write("\n# soulPilot dev/release artifacts\n")
        for line in missing:
            handle.write(f"{line}\n")
    log(".gitignore: added " + ", ".join(missing))


def update_runtime_paths() -> None:
    """Normalize source paths after the rename."""
    lua_root = SRC / "lua"
    if not lua_root.exists():
        return
    for path in sorted(lua_root.rglob("*.lua")):
        text = path.read_text(encoding="utf-8")
        text = text.replace(
            "mods/unpacked/soulPilot/ai/config/",
            "mods/unpacked/soulPilot/src/config/",
        )
        text = text.replace(
            "mods/unpacked/soulPilot/ai/music/",
            "mods/unpacked/soulPilot/src_music/",
        )
        text = text.replace("ai/config/", "src/config/")
        text = text.replace("ai/music/", "src_music/")
        path.write_text(text, encoding="utf-8", newline="\n")


def move_project_files() -> None:
    ensure_directories()

    for name in ("lua", "ui", "art", "mod_info"):
        move_path(ROOT / name, SRC / name)

    move_selected_children(
        ROOT / "ai" / "music",
        SRC_MUSIC,
        skip_names={"config.json", "current.json", "__pycache__"},
        skip_suffixes=(".pyc", ".tmp"),
    )
    move_selected_children(
        ROOT / "ai" / "notes",
        DOCS_AI,
        skip_names={"__pycache__", ".gitkeep"},
        skip_suffixes=(".pyc",),
    )
    move_path(ROOT / "ai" / "PROJECT_STATE.md", DOCS_AI / "PROJECT_STATE.md")
    move_path(ROOT / "ai" / "config", SRC_CONFIG)

    # Rename the old name in the mod source and UI.
    for base in (SRC / "lua", SRC / "ui"):
        rename_paths(base)
        replace_text_under(base)

    # The mod loader lives outside src/ but references the extension path.
    loader = ROOT / "scripts" / "modScript.lua"
    if loader.exists():
        replace_text_in_file(loader)

    update_runtime_paths()
    clean_config_json()
    update_gitignore()


def check_layout() -> list[str]:
    errors: list[str] = []
    required = (
        SRC / "lua" / "ge" / "extensions" / "soulPilot" / "main.lua",
        SRC / "lua" / "vehicle" / "extensions" / "auto" / "soulPilotWheel.lua",
        SRC / "ui" / "modules" / "apps" / "soulPilot" / "app.vue",
        SRC / "config" / "wheel.json",
        SRC_MUSIC / "app.py",
        DOCS_AI,
        DOCS_LANG / "gelua",
        DOCS_LANG / "vlua",
    )
    for path in required:
        if not path.exists():
            errors.append(f"missing: {path.relative_to(ROOT)}")

    old_tokens = ("AutopilotLive", "autopilotLive", "settings/autopilotLive")
    for base in (SRC / "lua", SRC / "ui"):
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            for token in old_tokens:
                if token in text:
                    errors.append(f"old token {token!r}: {path.relative_to(ROOT)}")
                    break
    return errors


def run_tests() -> int:
    command = [
        sys.executable,
        "-m",
        "unittest",
        "discover",
        "-s",
        "src/tests",
        "-v",
    ]
    log("running tests: " + " ".join(command))
    return subprocess.run(command, cwd=ROOT, check=False).returncode


def print_root_warning() -> None:
    if ROOT.name.lower() != "soulpilot":
        log(
            "WARNING: repository folder is not named soulPilot. "
            "Runtime paths use mods/unpacked/soulPilot/src/config, so rename "
            "the working copy/repository folder to soulPilot before game testing."
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Migrate AutopilotLive repository layout to soulPilot"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="show the planned migration without changing files",
    )
    parser.add_argument(
        "--skip-tests",
        action="store_true",
        help="do not run src/tests/test_behavior.py after migration",
    )
    args = parser.parse_args(argv)

    print_root_warning()

    if args.dry_run:
        log("DRY RUN: no files will be changed")
        log("planned source: lua/, ui/, art/, mod_info/ -> src/")
        log("planned source: ai/music/ -> src_music/")
        log("planned source: ai/notes/, ai/PROJECT_STATE.md -> docs/ai/")
        log("planned source: ai/config/ -> src/config/")
        log("planned rename: autopilotLive -> soulPilot in src/lua and src/ui")
        return 0

    move_project_files()
    errors = check_layout()
    if errors:
        for error in errors:
            log("ERROR: " + error)
        return 1

    if args.skip_tests:
        log("tests skipped by request")
        return 0

    return run_tests()


if __name__ == "__main__":
    raise SystemExit(main())

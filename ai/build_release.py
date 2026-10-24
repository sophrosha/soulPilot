#!/usr/bin/env python3
"""Build the soulPilot release zip with runtime files at the archive root.

The editable sources live in src/. BeamNG requires lua/, ui/, mod_info/,
art/ and config/ at the top level of a mod archive, so this script maps:

    src/lua/...    -> lua/...
    src/ui/...     -> ui/...
    src/mod_info/  -> mod_info/
    src/art/...    -> art/...
    src/config/... -> config/...

The root scripts/modScript.lua, src_music/ and locales/ are included too.
Development-only files (tests, venv, logs, CSV, caches, old sounds) are
excluded.

Usage:
    python ai/build_release.py
    python ai/build_release.py --dry-run
    python ai/build_release.py --output-dir C:\\Temp\\soulPilot-release
    python ai/build_release.py --version 0.1.0

By default the archive is written to a sibling folder outside the mod's
runtime tree (../soulPilot-dist relative to the mod folder). This keeps
BeamNG from discovering collected zips inside the unpacked mod.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import zipfile
from pathlib import Path, PurePosixPath

# This script lives in ai/; the project root is one level above it.
ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
MOD_INFO = SRC / "mod_info" / "soulPilot" / "mod_info.ini"
# Keep release output outside mods/unpacked; otherwise BeamNG may scan the
# collected zips as additional mods.
DEFAULT_OUTPUT_DIR = Path(
    os.environ.get("SOULPILOT_DIST_DIR", str(ROOT.parent.parent / "soulPilot-dist"))
)
DEFAULT_VERSION = "dev"

SOURCE_ROOTS = (
    ("lua", SRC / "lua"),
    ("ui", SRC / "ui"),
    ("mod_info", SRC / "mod_info"),
    ("art", SRC / "art"),
    ("config", SRC / "config"),
)

EXTRA_ROOTS = (
    ("scripts", ROOT / "scripts"),
    ("src_music", ROOT / "src_music"),
    ("locales", ROOT / "locales"),
    ("assets", ROOT / "assets"),
)

EXCLUDED_DIR_NAMES = {
    ".git",
    ".github",
    ".venv",
    "venv",
    "dist",
    "__pycache__",
    ".pytest_cache",
}

EXCLUDED_RELATIVE_FILES = {
    "art/sound/apl_pet_old.wav",
    "ui/modules/apps/soulPilot/apl_preview_ui.png",
    "src_music/config.json",
    "src_music/current.json",
    "src_music/requirements.txt",
}

REQUIRED_FILES = (
    "lua/ge/extensions/soulPilot/main.lua",
    "lua/vehicle/extensions/auto/soulPilotWheel.lua",
    "ui/modules/apps/soulPilot/app.vue",
    "ui/modules/apps/soulPilot/app.json",
    "mod_info/soulPilot/mod_info.ini",
    "config/wheel.json",
    "scripts/modScript.lua",
)


def read_version() -> str:
    if not MOD_INFO.is_file():
        return DEFAULT_VERSION
    text = MOD_INFO.read_text(encoding="utf-8", errors="replace")
    match = re.search(r"^\s*version\s*=\s*(\S+)", text, re.MULTILINE)
    return match.group(1).strip() if match else DEFAULT_VERSION


def is_excluded(rel: str) -> bool:
    parts = PurePosixPath(rel).parts
    if any(part in EXCLUDED_DIR_NAMES for part in parts):
        return True
    if rel in EXCLUDED_RELATIVE_FILES:
        return True
    if rel.endswith((".pyc", ".pyo", ".tmp")):
        return True
    if rel.endswith("/.gitkeep") or rel == ".gitkeep":
        return True
    if rel.startswith("src_music/") and ".tmp." in PurePosixPath(rel).name:
        return True
    return False


def collect_files() -> list[tuple[Path, str]]:
    files: list[tuple[Path, str]] = []
    for archive_root, source_root in (*SOURCE_ROOTS, *EXTRA_ROOTS):
        if not source_root.is_dir():
            continue
        for path in sorted(source_root.rglob("*")):
            if not path.is_file():
                continue
            relative = path.relative_to(source_root).as_posix()
            archive_name = f"{archive_root}/{relative}"
            if is_excluded(archive_name):
                continue
            files.append((path, archive_name))
    return files


def build_zip(output_dir: Path, version: str, dry_run: bool) -> int:
    files = collect_files()
    if not files:
        print("ERROR: no files found for the archive", file=sys.stderr)
        return 1

    archive = output_dir / f"soulPilot-{version}.zip"
    print(f"soulPilot release: {archive}")
    print(f"Files: {len(files)}")

    if dry_run:
        for _, archive_name in files:
            print(f"  {archive_name}")
        return 0

    output_dir.mkdir(parents=True, exist_ok=True)
    names: set[str] = set()
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for path, archive_name in files:
            zf.write(path, arcname=archive_name)
            names.add(archive_name)

    missing = [name for name in REQUIRED_FILES if name not in names]
    if missing:
        print("ERROR: required files are missing from the archive:", file=sys.stderr)
        for name in missing:
            print(f"  {name}", file=sys.stderr)
        return 2

    size_mb = archive.stat().st_size / (1024 * 1024)
    print(f"Done: {size_mb:.2f} MiB")
    print("Required files: OK")
    return 0


def configure_stdout() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


def main(argv: list[str] | None = None) -> int:
    configure_stdout()
    parser = argparse.ArgumentParser(description="Build a soulPilot release zip")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help=f"output directory (default: {DEFAULT_OUTPUT_DIR})",
    )
    parser.add_argument(
        "--version",
        default=None,
        help="version in the archive name (default: from mod_info.ini)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the archive contents without creating a zip",
    )
    args = parser.parse_args(argv)

    version = args.version or read_version()
    output_dir = args.output_dir.expanduser().resolve()
    try:
        output_dir.relative_to(ROOT.resolve())
    except ValueError:
        pass
    else:
        print(
            "ERROR: output directory must be outside the mod folder; "
            f"choose a path outside {ROOT}",
            file=sys.stderr,
        )
        return 2
    return build_zip(output_dir, version, args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())

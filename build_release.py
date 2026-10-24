#!/usr/bin/env python3
"""Сборка чистого релизного zip-архива AutopilotLive.

Скрипт не требует сторонних зависимостей. Запуск из корня мода:

    python build_release.py
    python build_release.py --output-dir C:\\Temp\\apl-release
    python build_release.py --version 0.1.0
    python build_release.py --dry-run

В архив не попадают dev-данные: venv, notes, csv, logs, road-диагностика,
кэши Python, старые звуки, тестовые отчёты и исходники, которые не нужны игре.
"""

from __future__ import annotations

import argparse
import re
import sys
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent
MOD_INFO = ROOT / "mod_info" / "AutopilotLive" / "mod_info.ini"
DEFAULT_OUTPUT_DIR = ROOT / "dist"
DEFAULT_VERSION = "dev"

# Каталоги, которые не являются частью релиза.
EXCLUDED_DIR_NAMES = {
    ".git",
    ".github",
    ".venv",
    "venv",
    "dist",
    "__pycache__",
    ".pytest_cache",
}

EXCLUDED_DIR_PREFIXES = (
    "ai/venv/",
    "ai/notes/",
    "ai/csv/",
    "ai/logs/",
    "ai/road/",
)

# Файлы в корне мода, которые не нужны в zip.
EXCLUDED_ROOT_FILES = {
    ".gitignore",
    "build_release.py",
    "bio.svg",    # рабочие копии лежат в ui/modules/apps/AutopilotLive/
    "github.svg",
    "report_gavril_neew.md",
    "report_gavril_new.md",
}

# Служебные/тестовые файлы в остальных каталогах.
EXCLUDED_RELATIVE_FILES = {
    "ai/PROJECT_STATE.md",
    "ai/requirements.txt",
    "ai/music/config.json",
    "ai/music/current.json",
    "art/sound/apl_pet_old.wav",
    "ui/modules/apps/AutopilotLive/apl_preview_ui.png",
}

REQUIRED_FILES = (
    "lua/ge/extensions/autopilotLive/main.lua",
    "lua/vehicle/extensions/auto/autopilotLiveWheel.lua",
    "ui/modules/apps/AutopilotLive/app.vue",
    "ui/modules/apps/AutopilotLive/app.json",
    "mod_info/AutopilotLive/mod_info.ini",
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
    if any(rel == prefix or rel.startswith(prefix) for prefix in EXCLUDED_DIR_PREFIXES):
        return True
    if rel in EXCLUDED_ROOT_FILES or rel in EXCLUDED_RELATIVE_FILES:
        return True
    if rel.endswith((".pyc", ".pyo", ".tmp")):
        return True
    if rel.endswith("/.gitkeep") or rel == ".gitkeep":
        return True
    if rel.startswith("ai/music/") and ".tmp." in PurePosixPath(rel).name:
        return True
    return False


def collect_files() -> list[tuple[Path, str]]:
    files: list[tuple[Path, str]] = []
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(ROOT).as_posix()
        if is_excluded(rel):
            continue
        files.append((path, rel))
    return files


def build_zip(output_dir: Path, version: str, dry_run: bool) -> int:
    files = collect_files()
    if not files:
        print("ERROR: не найдено ни одного файла для архива", file=sys.stderr)
        return 1

    archive = output_dir / f"AutopilotLive-{version}.zip"
    print(f"AutopilotLive release: {archive}")
    print(f"Файлов: {len(files)}")

    if dry_run:
        for _, rel in files:
            print(f"  {rel}")
        return 0

    output_dir.mkdir(parents=True, exist_ok=True)
    names: set[str] = set()
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for path, rel in files:
            zf.write(path, arcname=rel)
            names.add(rel)

    missing = [name for name in REQUIRED_FILES if name not in names]
    if missing:
        print("ERROR: в архив не попали обязательные файлы:", file=sys.stderr)
        for name in missing:
            print(f"  {name}", file=sys.stderr)
        return 2

    size_mb = archive.stat().st_size / (1024 * 1024)
    print(f"Готово: {size_mb:.2f} MiB")
    print("Проверка обязательных файлов: OK")
    return 0


def configure_stdout() -> None:
    """Не падать на Windows cp1252 при русских сообщениях."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


def main(argv: list[str] | None = None) -> int:
    configure_stdout()
    parser = argparse.ArgumentParser(description="Собрать чистый релизный zip AutopilotLive")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help=f"куда сохранить zip (по умолчанию: {DEFAULT_OUTPUT_DIR})",
    )
    parser.add_argument(
        "--version",
        default=None,
        help="версия в имени архива (по умолчанию из mod_info.ini)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="показать список файлов, не создавая архив",
    )
    args = parser.parse_args(argv)

    version = args.version or read_version()
    output_dir = args.output_dir.expanduser().resolve()
    return build_zip(output_dir, version, args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())

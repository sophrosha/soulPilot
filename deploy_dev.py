#!/usr/bin/env python3
"""Deploy soulPilot runtime files from src/ into the unpacked mod root.

BeamNG only loads lua/, ui/, mod_info/, art/ and config/ from the mod root.
The repository keeps editable sources in src/; this script mirrors the runtime
folders to the root before an in-game test.

Usage:
    python deploy_dev.py
    python deploy_dev.py --dry-run

The script copies by default (portable on Windows). It removes stale files
inside the deployed folders, but never removes the source tree or other root
folders. Run it after changing anything under src/.
"""

from __future__ import annotations

import argparse
import filecmp
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"

# Runtime folders that BeamNG expects at the mod root. src/tests is source-only
# and is deliberately not deployed.
RUNTIME_DIRS = ("lua", "ui", "mod_info", "art", "config")

# These stay at the root already and are not mirrored from src/.
ROOT_RUNTIME = ("scripts", "src_music", "locales")


def log(message: str) -> None:
    print(f"[deploy] {message}")


def same_file(left: Path, right: Path) -> bool:
    try:
        return filecmp.cmp(left, right, shallow=False)
    except OSError:
        return False


def copy_tree(source: Path, target: Path, dry_run: bool) -> tuple[int, int, int]:
    """Mirror source into target. Returns (copied, unchanged, removed)."""
    if not source.is_dir():
        raise FileNotFoundError(f"missing source directory: {source}")

    copied = 0
    unchanged = 0
    removed = 0
    source_files: set[Path] = set()

    for source_file in sorted(source.rglob("*")):
        if not source_file.is_file():
            continue
        relative = source_file.relative_to(source)
        source_files.add(relative)
        target_file = target / relative

        if target_file.is_file() and same_file(source_file, target_file):
            unchanged += 1
            continue

        copied += 1
        if dry_run:
            log(f"copy: {source_file.relative_to(ROOT)} -> {target_file.relative_to(ROOT)}")
            continue

        target_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_file, target_file)

    if target.is_dir():
        # Remove files that no longer exist in src/. Do it deepest-first so
        # empty directories can be removed afterwards.
        for target_file in sorted(target.rglob("*"), reverse=True):
            if not target_file.is_file():
                continue
            if target_file.relative_to(target) in source_files:
                continue
            removed += 1
            if dry_run:
                log(f"remove stale: {target_file.relative_to(ROOT)}")
            else:
                target_file.unlink()

        for target_dir in sorted(
            (path for path in target.rglob("*") if path.is_dir()),
            key=lambda path: len(path.parts),
            reverse=True,
        ):
            if target_dir.relative_to(target) in {p.parent for p in source_files}:
                continue
            try:
                if not any(target_dir.iterdir()):
                    if dry_run:
                        log(f"remove empty: {target_dir.relative_to(ROOT)}")
                    else:
                        target_dir.rmdir()
            except OSError:
                pass

    return copied, unchanged, removed


def verify_root() -> list[str]:
    errors: list[str] = []
    for name in RUNTIME_DIRS:
        if not (SRC / name).is_dir():
            errors.append(f"missing: src/{name}/")
    if not (ROOT / "scripts" / "modScript.lua").is_file():
        errors.append("missing: scripts/modScript.lua")
    if not (ROOT / "src_music").is_dir():
        errors.append("missing: src_music/")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Deploy src/ runtime folders to the soulPilot mod root")
    parser.add_argument("--dry-run", action="store_true", help="show changes without writing")
    args = parser.parse_args(argv)

    errors = verify_root()
    if errors:
        for error in errors:
            print(f"[deploy] ERROR: {error}", file=sys.stderr)
        return 1

    total_copied = 0
    total_unchanged = 0
    total_removed = 0
    for name in RUNTIME_DIRS:
        copied, unchanged, removed = copy_tree(SRC / name, ROOT / name, args.dry_run)
        total_copied += copied
        total_unchanged += unchanged
        total_removed += removed
        log(
            f"{name}: copied={copied}, unchanged={unchanged}, removed={removed}"
            + (" (dry-run)" if args.dry_run else "")
        )

    log("root files not deployed: " + ", ".join(ROOT_RUNTIME))
    log("done" if not args.dry_run else "dry-run complete; no files changed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Prepare a normal unpacked BeamNG mod from the editable src/ tree.

BeamNG only loads lua/, ui/, mod_info/, art/ and config/ from the mod root.
The project keeps sources in src/; this script mirrors the runtime folders to
the root before an in-game test.

Usage:
    python dev_mode.py
    python dev_mode.py --dry-run

The script copies by default (portable on Windows). It removes stale files
inside the deployed folders, but never removes the source tree or other root
folders. dist/ is never created or touched here; release archives are built
outside the mod folder by build_release.py.
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

# Runtime folders that are not part of src/lua, src/ui, etc. The source may be
# in src/<name> or already at the mod root (the current repository layout).
ROOT_RUNTIME_DIRS = ("scripts", "src_music", "locales")


def log(message: str) -> None:
    print(f"[dev] {message}")


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

    for name in ROOT_RUNTIME_DIRS:
        if not (SRC / name).is_dir() and not (ROOT / name).is_dir():
            errors.append(f"missing: {name}/ (or src/{name}/)")

    if not (SRC / "scripts" / "modScript.lua").is_file() and not (
        ROOT / "scripts" / "modScript.lua"
    ).is_file():
        errors.append("missing: scripts/modScript.lua (or src/scripts/modScript.lua)")
    return errors


def deploy_root_runtime(name: str, dry_run: bool) -> tuple[int, int, int, str]:
    """Copy src/<name> to <root>/<name>, or verify an existing root folder."""
    source = SRC / name
    target = ROOT / name
    if source.is_dir() and source.resolve() != target.resolve():
        copied, unchanged, removed = copy_tree(source, target, dry_run)
        return copied, unchanged, removed, f"src/{name} -> {name}"
    if target.is_dir():
        return 0, 0, 0, "already at root"
    return 0, 0, 0, "missing"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Deploy src/ runtime folders to the soulPilot mod root")
    parser.add_argument("--dry-run", action="store_true", help="show changes without writing")
    args = parser.parse_args(argv)

    errors = verify_root()
    if errors:
        for error in errors:
            print(f"[dev] ERROR: {error}", file=sys.stderr)
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

    for name in ROOT_RUNTIME_DIRS:
        copied, unchanged, removed, status = deploy_root_runtime(name, args.dry_run)
        total_copied += copied
        total_unchanged += unchanged
        total_removed += removed
        log(
            f"{name}: copied={copied}, unchanged={unchanged}, removed={removed} "
            f"({status})" + (" (dry-run)" if args.dry_run else "")
        )

    log(
        f"total: copied={total_copied}, unchanged={total_unchanged}, "
        f"removed={total_removed}"
    )
    log("done" if not args.dry_run else "dry-run complete; no files changed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

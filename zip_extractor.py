#!/usr/bin/env python3
"""Extract ZIP archives recursively into sibling folders named after each archive."""

from __future__ import annotations

import argparse
import logging
import zipfile
from pathlib import Path
from typing import Any

from logging_utils import setup_colored_logging

logger = logging.getLogger("zip_extractor")


def _safe_members(zf: zipfile.ZipFile, destination: Path):
    """Yield zip members that stay inside destination (zip-slip protection)."""
    dest_root = destination.resolve()
    for member in zf.infolist():
        target = (destination / member.filename).resolve()
        try:
            target.relative_to(dest_root)
        except ValueError:
            raise ValueError(f"Unsafe path in archive: {member.filename}")
        yield member


def extract_zip(zip_path: Path, overwrite: bool = False) -> dict[str, Any]:
    zip_path = zip_path.resolve()
    extract_dir = zip_path.parent / zip_path.stem

    result: dict[str, Any] = {
        "zip_path": str(zip_path),
        "extract_dir": str(extract_dir.resolve()),
        "success": False,
        "skipped": False,
        "error": None,
        "extracted_files": 0,
    }

    try:
        if extract_dir.exists() and not overwrite:
            result["success"] = True
            result["skipped"] = True
            logger.info("Skipped (already extracted): %s", zip_path)
            return result

        extract_dir.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(zip_path, "r") as zf:
            members = list(_safe_members(zf, extract_dir))
            for member in members:
                zf.extract(member, path=extract_dir)
            result["extracted_files"] = len(members)

        result["success"] = True
        logger.info("Extracted: %s -> %s (%s item(s))", zip_path, extract_dir, result["extracted_files"])
    except Exception as exc:  # pragma: no cover - defensive
        result["error"] = str(exc)
        logger.error("Failed to extract '%s': %s", zip_path, exc)

    return result


def extract_all_zips(source_dir: str | Path, overwrite: bool = False) -> list[dict[str, Any]]:
    root = Path(source_dir).resolve()
    if not root.exists():
        raise FileNotFoundError(f"Source directory not found: {root}")
    if not root.is_dir():
        raise NotADirectoryError(f"Source path is not a directory: {root}")

    archives = sorted(p for p in root.rglob("*") if p.is_file() and p.suffix.lower() == ".zip")
    logger.info("Found %s ZIP file(s) in '%s'.", len(archives), root)

    results: list[dict[str, Any]] = []
    for zip_file in archives:
        results.append(extract_zip(zip_file, overwrite=overwrite))

    succeeded = sum(1 for item in results if item["success"])
    failed = len(results) - succeeded
    skipped = sum(1 for item in results if item["skipped"])
    logger.info(
        "ZIP extraction summary: total=%s succeeded=%s failed=%s skipped=%s",
        len(results),
        succeeded,
        failed,
        skipped,
    )
    return results


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Recursively find ZIP files under source directory and extract each one "
            "into a sibling folder with the same name as archive."
        )
    )
    parser.add_argument(
        "--source-dir",
        default="source",
        help="Root directory to scan recursively for ZIP files (default: source).",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite extraction folder contents when folder already exists.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    setup_colored_logging(level=logging.INFO)
    try:
        results = extract_all_zips(args.source_dir, overwrite=args.overwrite)
        failed = sum(1 for item in results if not item["success"])
        return 1 if failed else 0
    except Exception as exc:
        logger.exception("ZIP extraction failed: %s", exc)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

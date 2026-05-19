#!/usr/bin/env python3
"""Config-driven CSV extractor with low-memory streaming and optional deduplication."""

from __future__ import annotations

import argparse
import csv
import json
import logging
import os
import re
import sqlite3
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from logging_utils import setup_colored_logging

logger = logging.getLogger("csv_extractor")


@dataclass
class ExtractionResult:
    success: bool
    output_file: str
    total_files_scanned: int = 0
    total_files_processed: int = 0
    total_records_scanned: int = 0
    total_records_extracted: int = 0
    errors: list[tuple[str, str]] = field(default_factory=list)


class CSVExtractor:
    def __init__(self, config_path: str | Path):
        self.config_path = Path(config_path).resolve()
        self.config_dir = self.config_path.parent
        self.config = self._load_config()

    def _load_config(self) -> dict[str, Any]:
        if not self.config_path.exists():
            raise FileNotFoundError(f"Config file not found: {self.config_path}")
        with self.config_path.open("r", encoding="utf-8") as f:
            return json.load(f)

    def _resolve_path(self, raw_path: str) -> Path:
        p = Path(raw_path)
        if p.is_absolute():
            return p
        return (self.config_dir / p).resolve()

    @staticmethod
    def _parse_bool(value: Any, default: bool = False) -> bool:
        if isinstance(value, bool):
            return value
        if value is None:
            return default
        if isinstance(value, str):
            return value.strip().lower() in {"1", "true", "yes", "y", "on"}
        return bool(value)

    @staticmethod
    def _parse_col_ref(value: Any) -> int | str:
        if isinstance(value, int):
            return value
        if isinstance(value, str):
            stripped = value.strip()
            if stripped.isdigit():
                return int(stripped)
            return stripped
        return str(value)

    @staticmethod
    def _read_options(base: dict[str, Any], override: dict[str, Any] | None = None) -> dict[str, Any]:
        opts = dict(base or {})
        if override:
            opts.update(override)
        return {
            "encoding": opts.get("encoding", "utf-8"),
            "delimiter": opts.get("delimiter", ","),
            "header": CSVExtractor._parse_bool(opts.get("header", True), default=True),
        }

    @staticmethod
    def _value_from_row(
        row: list[str],
        headers: list[str] | None,
        header_map: dict[str, int] | None,
        col_ref: int | str,
    ) -> str:
        if isinstance(col_ref, int):
            return row[col_ref] if 0 <= col_ref < len(row) else ""

        if col_ref.isdigit():
            idx = int(col_ref)
            return row[idx] if 0 <= idx < len(row) else ""

        if headers and header_map and col_ref in header_map:
            idx = header_map[col_ref]
            return row[idx] if 0 <= idx < len(row) else ""

        return ""

    @staticmethod
    def _match_condition(actual: str, operator: str, expected: Any) -> bool:
        op = (operator or "equals").strip().lower()
        actual_s = "" if actual is None else str(actual)

        if op == "equals":
            return actual_s == str(expected)
        if op == "not_equals":
            return actual_s != str(expected)
        if op == "contains":
            return str(expected) in actual_s
        if op == "not_contains":
            return str(expected) not in actual_s
        if op == "startswith":
            return actual_s.startswith(str(expected))
        if op == "endswith":
            return actual_s.endswith(str(expected))
        if op == "regex":
            return re.search(str(expected), actual_s) is not None
        if op == "in":
            values = expected if isinstance(expected, list) else [p.strip() for p in str(expected).split(",")]
            return actual_s in {str(v) for v in values}
        if op == "not_in":
            values = expected if isinstance(expected, list) else [p.strip() for p in str(expected).split(",")]
            return actual_s not in {str(v) for v in values}
        if op == "is_empty":
            return actual_s.strip() == ""
        if op == "is_not_empty":
            return actual_s.strip() != ""

        if op in {"gt", "gte", "lt", "lte"}:
            try:
                left = float(actual_s)
                right = float(expected)
            except (TypeError, ValueError):
                left = actual_s
                right = str(expected)

            if op == "gt":
                return left > right
            if op == "gte":
                return left >= right
            if op == "lt":
                return left < right
            return left <= right

        raise ValueError(f"Unsupported operator: {operator}")

    def _row_matches_filter(
        self,
        row: list[str],
        headers: list[str] | None,
        header_map: dict[str, int] | None,
        filter_spec: dict[str, Any] | None,
    ) -> bool:
        if not filter_spec:
            return True

        logic = str(filter_spec.get("logic", "AND")).strip().upper()
        conditions = filter_spec.get("conditions", [])
        if not conditions:
            return True

        checks = []
        for cond in conditions:
            col_ref = self._parse_col_ref(cond.get("column"))
            operator = cond.get("operator", "equals")
            expected = cond.get("value", "")
            actual = self._value_from_row(row, headers, header_map, col_ref)
            checks.append(self._match_condition(actual, operator, expected))

        if logic == "OR":
            return any(checks)
        return all(checks)

    @staticmethod
    def _compile_file_rules(file_rules: list[dict[str, Any]]) -> list[dict[str, Any]]:
        compiled: list[dict[str, Any]] = []
        for rule in file_rules:
            pattern = rule.get("filename_pattern")
            if not pattern:
                continue
            compiled.append({**rule, "_compiled_pattern": re.compile(pattern, re.IGNORECASE)})
        return compiled

    @staticmethod
    def _select_rule(file_path: Path, compiled_rules: list[dict[str, Any]]) -> dict[str, Any] | None:
        name = file_path.name
        rel_path = str(file_path).replace("\\", "/")
        # Prefer full filename/path matches first to avoid broad patterns
        # (e.g. "IP2PROXY.*\\.csv") shadowing more specific ones.
        for rule in compiled_rules:
            p = rule["_compiled_pattern"]
            if p.fullmatch(name) or p.fullmatch(rel_path):
                return rule
        for rule in compiled_rules:
            p = rule["_compiled_pattern"]
            if p.search(name) or p.search(rel_path):
                return rule
        return None

    @staticmethod
    def _resolve_extract_indices(columns_to_extract: list[Any], headers: list[str] | None) -> tuple[list[int], list[str]]:
        indices: list[int] = []
        out_headers: list[str] = []

        if not columns_to_extract:
            raise ValueError("columns_to_extract must not be empty")

        header_map = {h: i for i, h in enumerate(headers or [])}

        for raw in columns_to_extract:
            if isinstance(raw, int):
                indices.append(raw)
                out_headers.append(headers[raw] if headers and 0 <= raw < len(headers) else str(raw))
                continue

            val = str(raw).strip()
            if val.isdigit():
                idx = int(val)
                indices.append(idx)
                out_headers.append(headers[idx] if headers and 0 <= idx < len(headers) else val)
                continue

            if headers and val in header_map:
                idx = header_map[val]
                indices.append(idx)
                out_headers.append(val)
                continue

            raise ValueError(f"Unknown column reference '{raw}'")

        return indices, out_headers

    @staticmethod
    def _iter_candidate_csv_files(root: Path):
        # Deterministic traversal keeps output row order stable across runs,
        # which is important for resume fingerprint consistency.
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames.sort(key=str.lower)
            filenames.sort(key=str.lower)
            base = Path(dirpath)
            for name in filenames:
                if name.lower().endswith(".csv"):
                    yield base / name

    def _deduplicate_output(
        self,
        input_csv: Path,
        output_csv: Path,
        dedup_cfg: dict[str, Any],
        delimiter: str,
        encoding: str,
    ) -> int:
        enabled = self._parse_bool(dedup_cfg.get("enabled", False), default=False)
        if not enabled:
            input_csv.replace(output_csv)
            return 0

        keep = str(dedup_cfg.get("keep", "first")).strip().lower()
        if keep not in {"first", "last"}:
            raise ValueError("output_deduplicate.keep must be 'first' or 'last'")

        with input_csv.open("r", encoding=encoding, newline="") as src:
            reader = csv.reader(src, delimiter=delimiter)
            try:
                header = next(reader)
            except StopIteration:
                with output_csv.open("w", encoding=encoding, newline="") as dst:
                    pass
                input_csv.unlink(missing_ok=True)
                return 0

            dedup_columns = dedup_cfg.get("columns", [])
            if dedup_columns:
                key_indices, _ = self._resolve_extract_indices(dedup_columns, header)
            else:
                key_indices = list(range(len(header)))

            sqlite_fd, sqlite_path = tempfile.mkstemp(prefix="csv_dedup_", suffix=".sqlite3")

        os.close(sqlite_fd)
        duplicates = 0

        conn = sqlite3.connect(sqlite_path)
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("PRAGMA synchronous=NORMAL;")

        try:
            with input_csv.open("r", encoding=encoding, newline="") as src, output_csv.open(
                "w", encoding=encoding, newline=""
            ) as dst:
                reader = csv.reader(src, delimiter=delimiter)
                writer = csv.writer(dst, delimiter=delimiter)
                _ = next(reader, None)
                writer.writerow(header)

                if keep == "first":
                    conn.execute("CREATE TABLE seen (k TEXT PRIMARY KEY)")
                    for row in reader:
                        key = "\x1f".join(row[idx] if 0 <= idx < len(row) else "" for idx in key_indices)
                        try:
                            conn.execute("INSERT INTO seen(k) VALUES (?)", (key,))
                            writer.writerow(row)
                        except sqlite3.IntegrityError:
                            duplicates += 1
                    conn.commit()
                else:
                    conn.execute("CREATE TABLE latest (k TEXT PRIMARY KEY, row_json TEXT NOT NULL, seq INTEGER NOT NULL)")
                    seq = 0
                    for row in reader:
                        seq += 1
                        key = "\x1f".join(row[idx] if 0 <= idx < len(row) else "" for idx in key_indices)
                        conn.execute(
                            "INSERT INTO latest(k, row_json, seq) VALUES (?, ?, ?) "
                            "ON CONFLICT(k) DO UPDATE SET row_json=excluded.row_json, seq=excluded.seq",
                            (key, json.dumps(row, ensure_ascii=False), seq),
                        )
                    conn.commit()
                    for row_json, in conn.execute("SELECT row_json FROM latest ORDER BY seq ASC"):
                        writer.writerow(json.loads(row_json))
                    total_rows = seq
                    kept_rows = conn.execute("SELECT COUNT(*) FROM latest").fetchone()[0]
                    duplicates = int(total_rows - kept_rows)
        finally:
            conn.close()
            Path(sqlite_path).unlink(missing_ok=True)
            input_csv.unlink(missing_ok=True)

        return duplicates

    def run(self) -> ExtractionResult:
        target_dir = self._resolve_path(str(self.config.get("target_directory", "source")))
        output_file = self._resolve_path(str(self.config.get("output_file", "filtered_CIDR_database.csv")))

        if not target_dir.exists() or not target_dir.is_dir():
            return ExtractionResult(
                success=False,
                output_file=str(output_file),
                errors=[(str(target_dir), "target_directory does not exist or is not a directory")],
            )

        default_rule = self.config.get("default_rule", {})
        compiled_rules = self._compile_file_rules(self.config.get("file_rules", []))
        global_read_opts = self._read_options(self.config.get("csv_read_options", {}))

        output_format = self.config.get("output_format", {})
        out_encoding = output_format.get("encoding", "utf-8")
        out_delimiter = output_format.get("delimiter", ",")
        dedup_cfg = self.config.get("output_deduplicate", {"enabled": False})

        output_file.parent.mkdir(parents=True, exist_ok=True)
        temp_raw = output_file.with_suffix(output_file.suffix + ".tmp_raw")

        result = ExtractionResult(success=True, output_file=str(output_file))
        output_headers: list[str] | None = None

        logger.info("Scanning candidate CSV files in '%s' ...", target_dir)

        with temp_raw.open("w", encoding=out_encoding, newline="") as raw_out:
            writer = csv.writer(raw_out, delimiter=out_delimiter)

            for file_path in self._iter_candidate_csv_files(target_dir):
                result.total_files_scanned += 1
                matched_rule = self._select_rule(file_path, compiled_rules)
                rule = matched_rule or default_rule
                if not rule:
                    logger.debug("Skipping '%s': no matching rule and no default_rule.", file_path)
                    continue

                read_opts = self._read_options(global_read_opts, rule.get("csv_read_options"))
                encoding = read_opts["encoding"]
                delimiter = read_opts["delimiter"]
                has_header = read_opts["header"]

                filter_spec = rule.get("filter")
                columns_to_extract = rule.get("columns_to_extract", [])

                try:
                    with file_path.open("r", encoding=encoding, errors="replace", newline="") as f:
                        reader = csv.reader(f, delimiter=delimiter)
                        headers: list[str] | None = None
                        header_map: dict[str, int] | None = None

                        if has_header:
                            headers = next(reader, None)
                            if headers is None:
                                logger.warning("Skipping empty file: %s", file_path)
                                continue
                            header_map = {h: i for i, h in enumerate(headers)}

                        extract_indices, rule_output_headers = self._resolve_extract_indices(columns_to_extract, headers)

                        if output_headers is None:
                            output_headers = rule_output_headers
                            writer.writerow(output_headers)
                        elif output_headers != rule_output_headers:
                            raise ValueError(
                                f"Output schema mismatch. Expected {output_headers}, got {rule_output_headers}"
                            )

                        file_scanned = 0
                        file_extracted = 0
                        for row in reader:
                            file_scanned += 1
                            if not self._row_matches_filter(row, headers, header_map, filter_spec):
                                continue

                            out_row = [row[idx] if 0 <= idx < len(row) else "" for idx in extract_indices]
                            writer.writerow(out_row)
                            file_extracted += 1

                        result.total_files_processed += 1
                        result.total_records_scanned += file_scanned
                        result.total_records_extracted += file_extracted
                        logger.info(
                            "Processed %s | scanned=%s extracted=%s",
                            file_path,
                            file_scanned,
                            file_extracted,
                        )

                except Exception as exc:  # pragma: no cover - defensive for malformed files
                    result.success = False
                    result.errors.append((str(file_path), str(exc)))
                    logger.error("Failed to process '%s': %s", file_path, exc)

        logger.info("Found %s candidate CSV file(s).", result.total_files_scanned)

        if output_headers is None:
            logger.warning("No output rows generated. Creating an empty output file.")
            output_file.write_text("", encoding=out_encoding)
            temp_raw.unlink(missing_ok=True)
            if result.errors:
                result.success = False
            return result

        try:
            duplicates = self._deduplicate_output(
                temp_raw,
                output_file,
                dedup_cfg,
                delimiter=out_delimiter,
                encoding=out_encoding,
            )
            if duplicates:
                logger.info("Deduplication removed %s duplicate row(s).", duplicates)
        except Exception as exc:
            result.success = False
            result.errors.append((str(output_file), f"Deduplication failed: {exc}"))
            logger.error("Deduplication failed: %s", exc)
            temp_raw.unlink(missing_ok=True)

        return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Extract filtered columns from CSV files using a JSON config.")
    parser.add_argument(
        "--config",
        default="csv_extractor_config.json",
        help="Path to extractor config JSON (default: csv_extractor_config.json).",
    )
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        help="Logging level (default: INFO).",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    setup_colored_logging(level=getattr(logging, args.log_level.upper(), logging.INFO))

    try:
        extractor = CSVExtractor(args.config)
        result = extractor.run()

        logger.info(
            "Extraction summary: files_scanned=%s files_processed=%s records_scanned=%s records_extracted=%s output=%s",
            result.total_files_scanned,
            result.total_files_processed,
            result.total_records_scanned,
            result.total_records_extracted,
            result.output_file,
        )

        if result.errors:
            for file_path, error in result.errors:
                logger.error("Error in %s: %s", file_path, error)

        return 0 if result.success else 1
    except Exception as exc:
        logger.exception("CSV extraction failed: %s", exc)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

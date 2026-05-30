#!/usr/bin/env python3
import argparse
import csv
import ipaddress
import json
import math
import os
import shutil
import socket
import struct
import threading
import time
import traceback
import uuid
from collections import deque
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from pathlib import Path
from typing import Any, Optional

import scanner as scanner_module
from csv_extractor import CSVExtractor
from flask import Flask, Response, jsonify, redirect, render_template, request, session, url_for
from main import load_scanner_config_resolved, resolve_cidr_column
from scanner import count_total_ips, scan_ip, stream_ips_from_csv
from werkzeug.security import check_password_hash
from zip_extractor import extract_all_zips

APP_NAME = "DNS Scout"
APP_VERSION = "2.0.0-beta"
APP_REPOSITORY = "https://github.com/sampa-asa/dns-scout"


def build_dns_query(domain: str, qtype: int = 1) -> bytes:
    txid = 0x1234
    flags = 0x0100
    header = struct.pack("!HHHHHH", txid, flags, 1, 0, 0, 0)
    qname = b""
    for part in domain.encode("idna").split(b"."):
        qname += bytes([len(part)]) + part
    qname += b"\x00"
    return header + qname + struct.pack("!HH", qtype, 1)


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: Path, payload: dict) -> None:
    with path.open("w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)


def normalize_ipv4_cidr(raw_value: str) -> Optional[str]:
    value = (raw_value or "").strip()
    if not value:
        return None
    try:
        network = ipaddress.ip_network(value, strict=False)
    except ValueError:
        return None
    if network.version != 4:
        return None
    return f"{network.network_address}/{network.prefixlen}"


def parse_scan_timeout(raw_value) -> tuple[bool, Optional[float], str]:
    if raw_value in (None, ""):
        return True, None, ""
    try:
        timeout = float(raw_value)
    except (TypeError, ValueError):
        return False, None, "فرمت Timeout نامعتبر است."
    if timeout <= 0:
        return False, None, "Timeout باید بزرگ‌تر از صفر باشد."
    return True, timeout, ""


def normalize_domain(raw_value: str) -> tuple[bool, str, str]:
    domain = (raw_value or "").strip().rstrip(".")
    if not domain:
        return False, "", "دامنه الزامی است."
    try:
        encoded = domain.encode("idna").decode("ascii")
    except UnicodeError:
        return False, "", "فرمت دامنه نامعتبر است."
    labels = encoded.split(".")
    if any((not label) or len(label) > 63 for label in labels):
        return False, "", "فرمت دامنه نامعتبر است."
    return True, encoded, ""


def normalize_query_type(raw_value: str) -> tuple[bool, str, str]:
    query_type = (raw_value or "").strip().upper()
    if query_type in {"A", "AAAA"}:
        return True, query_type, ""
    return False, "", "معیار اسکن نامعتبر است. مقادیر مجاز: A و AAAA."


def parse_cidrs_from_text(raw_text: str) -> tuple[list[str], list[str]]:
    valid_items: list[str] = []
    invalid_items: list[str] = []
    seen: set[str] = set()
    for line in (raw_text or "").replace(",", "\n").splitlines():
        raw_item = line.strip()
        if not raw_item:
            continue
        normalized = normalize_ipv4_cidr(raw_item)
        if normalized is None:
            invalid_items.append(raw_item)
            continue
        if normalized not in seen:
            seen.add(normalized)
            valid_items.append(normalized)
    return valid_items, invalid_items


class ResourceManager:
    def __init__(self, base_dir: Path, csv_config_path: Path):
        self.base_dir = base_dir.resolve()
        self.csv_config_path = csv_config_path.resolve()
        self.source_dir = (self.base_dir / "source").resolve()
        self.resources_dir = (self.base_dir / "panel_resources").resolve()
        self.uploads_dir = (self.source_dir / "uploads").resolve()
        self.temp_uploads_dir = (self.source_dir / "tmp_uploads").resolve()
        self.manual_file = (self.resources_dir / "manual_cidrs.txt").resolve()
        self.merged_csv_file = (self.resources_dir / "merged_resources.csv").resolve()
        self.disabled_files_store = (self.resources_dir / "disabled_csv_files.json").resolve()
        self.upload_logs_dir = (self.resources_dir / "logs").resolve()
        self.upload_log_file = (self.upload_logs_dir / "csv_upload.log").resolve()
        self.resources_dir.mkdir(parents=True, exist_ok=True)
        self.uploads_dir.mkdir(parents=True, exist_ok=True)
        self.temp_uploads_dir.mkdir(parents=True, exist_ok=True)
        self.upload_logs_dir.mkdir(parents=True, exist_ok=True)
        self._upload_lock = threading.RLock()
        self._upload_sessions: dict[str, dict[str, Any]] = {}
        self._csv_count_cache: dict[str, tuple[int, int, int]] = {}
        self._upload_session_ttl_sec = 15 * 60
        self._stale_upload_artifact_ttl_sec = 30 * 60
        self._last_stale_upload_cleanup_at = 0.0
        if not self.manual_file.exists():
            self.manual_file.write_text("", encoding="utf-8")
        if not self.disabled_files_store.exists():
            self.disabled_files_store.write_text("[]", encoding="utf-8")
        if not self.upload_log_file.exists():
            self.upload_log_file.write_text("", encoding="utf-8")
        self._maybe_cleanup_stale_upload_artifacts(force=True)

    def _upload_log(self, upload_id: str, message: str, level: str = "INFO") -> None:
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        line = f"[{ts}] [{level}] [upload_id={upload_id}] {message}\n"
        try:
            with self.upload_log_file.open("a", encoding="utf-8") as f:
                f.write(line)
        except OSError:
            pass

    def _upload_log_exception(self, upload_id: str, context: str, exc: Exception) -> None:
        self._upload_log(upload_id, f"{context}: {type(exc).__name__}: {exc}", level="ERROR")
        trace = traceback.format_exc().strip()
        if trace:
            self._upload_log(upload_id, f"traceback={trace}", level="DEBUG")

    def _load_disabled_files(self) -> set[str]:
        try:
            rows = json.loads(self.disabled_files_store.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return set()
        if not isinstance(rows, list):
            return set()
        output: set[str] = set()
        for item in rows:
            raw_name = str(item or "").strip().replace("\\", "/")
            if not raw_name:
                continue
            if raw_name.startswith("source/"):
                output.add(raw_name)
                continue
            safe_name = Path(raw_name).name
            if safe_name:
                output.add(safe_name)
        return output

    def _save_disabled_files(self, disabled_files: set[str]) -> None:
        payload = sorted(disabled_files)
        self.disabled_files_store.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    @staticmethod
    def _normalize_bool(value: Any, default: bool = False) -> bool:
        if isinstance(value, bool):
            return value
        if value is None:
            return default
        if isinstance(value, str):
            return value.strip().lower() in {"1", "true", "yes", "y", "on"}
        return bool(value)

    @staticmethod
    def _normalize_column_ref(value: Any) -> int | str:
        if isinstance(value, int):
            return value
        if isinstance(value, str):
            stripped = value.strip()
            if stripped.isdigit():
                return int(stripped)
            return stripped
        raise ValueError("ارجاع ستون نامعتبر است.")

    @staticmethod
    def _normalize_columns_to_extract(value: Any) -> list[int | str]:
        if isinstance(value, str):
            raw_items = [part.strip() for part in value.split(",") if part.strip()]
        elif isinstance(value, list):
            raw_items = value
        else:
            raise ValueError("columns_to_extract باید لیست یا رشته جداشده با کاما باشد.")

        if not raw_items:
            raise ValueError("columns_to_extract نباید خالی باشد.")

        normalized: list[int | str] = []
        for item in raw_items:
            normalized.append(ResourceManager._normalize_column_ref(item))
        return normalized

    @staticmethod
    def _normalize_read_options(value: Any) -> dict[str, Any]:
        raw = value if isinstance(value, dict) else {}
        encoding = str(raw.get("encoding", "utf-8")).strip() or "utf-8"
        delimiter = str(raw.get("delimiter", ","))
        header = ResourceManager._normalize_bool(raw.get("header", False), default=False)
        if not delimiter:
            raise ValueError("delimiter نمی‌تواند خالی باشد.")
        return {
            "encoding": encoding,
            "delimiter": delimiter,
            "header": header,
        }

    @staticmethod
    def _normalize_filter_spec(value: Any) -> dict[str, Any]:
        if not isinstance(value, dict):
            return {"logic": "AND", "conditions": []}

        logic = str(value.get("logic", "AND")).strip().upper()
        if logic not in {"AND", "OR"}:
            raise ValueError("filter.logic باید AND یا OR باشد.")

        raw_conditions = value.get("conditions", [])
        if not isinstance(raw_conditions, list):
            raise ValueError("filter.conditions باید لیست باشد.")

        conditions: list[dict[str, Any]] = []
        for item in raw_conditions:
            if not isinstance(item, dict):
                raise ValueError("هر شرط فیلتر باید یک آبجکت باشد.")
            if "column" not in item:
                raise ValueError("هر شرط فیلتر باید column داشته باشد.")
            operator = str(item.get("operator", "equals")).strip()
            if not operator:
                raise ValueError("operator فیلتر الزامی است.")
            conditions.append(
                {
                    "column": ResourceManager._normalize_column_ref(item.get("column")),
                    "operator": operator,
                    "value": item.get("value", ""),
                }
            )

        return {
            "logic": logic,
            "conditions": conditions,
        }

    @staticmethod
    def _normalize_rule(value: Any, require_pattern: bool) -> dict[str, Any]:
        if not isinstance(value, dict):
            raise ValueError("rule باید یک آبجکت باشد.")

        output: dict[str, Any] = {}
        if require_pattern:
            pattern = str(value.get("filename_pattern", "")).strip()
            if not pattern:
                raise ValueError("برای file_rules مقدار filename_pattern الزامی است.")
            output["filename_pattern"] = pattern

        output["csv_read_options"] = ResourceManager._normalize_read_options(value.get("csv_read_options", {}))
        output["filter"] = ResourceManager._normalize_filter_spec(value.get("filter", {}))
        output["columns_to_extract"] = ResourceManager._normalize_columns_to_extract(
            value.get("columns_to_extract", [])
        )
        return output

    def extractor_settings(self) -> dict[str, Any]:
        if not self.csv_config_path.exists():
            raise FileNotFoundError(f"فایل تنظیمات CSV پیدا نشد: {self.csv_config_path}")

        config = load_json(self.csv_config_path)
        file_rules = config.get("file_rules", [])
        if not isinstance(file_rules, list):
            file_rules = []
        try:
            default_rule = self._normalize_rule(config.get("default_rule", {}), require_pattern=False)
        except ValueError:
            default_rule = {
                "csv_read_options": self._normalize_read_options({}),
                "filter": {"logic": "AND", "conditions": []},
                "columns_to_extract": [0],
            }

        normalized_file_rules: list[dict[str, Any]] = []
        for rule in file_rules:
            try:
                normalized_file_rules.append(self._normalize_rule(rule, require_pattern=True))
            except ValueError:
                continue

        return {
            "target_directory": config.get("target_directory", "./source"),
            "output_file": config.get("output_file", "filtered_CIDR_database.csv"),
            "settings": {
                "csv_read_options": self._normalize_read_options(config.get("csv_read_options", {})),
                "default_rule": default_rule,
                "file_rules": normalized_file_rules,
            },
        }

    def save_extractor_settings(self, raw_settings: Any) -> tuple[bool, str]:
        if not isinstance(raw_settings, dict):
            return False, "payload تنظیمات نامعتبر است."
        file_rules_raw = raw_settings.get("file_rules", [])
        if not isinstance(file_rules_raw, list):
            return False, "file_rules باید لیست باشد."

        try:
            sanitized = {
                "csv_read_options": self._normalize_read_options(raw_settings.get("csv_read_options", {})),
                "default_rule": self._normalize_rule(raw_settings.get("default_rule", {}), require_pattern=False),
                "file_rules": [
                    self._normalize_rule(rule, require_pattern=True)
                    for rule in file_rules_raw
                ],
            }
        except ValueError as exc:
            return False, str(exc)

        if not self.csv_config_path.exists():
            return False, f"فایل تنظیمات CSV پیدا نشد: {self.csv_config_path}"

        full_cfg = load_json(self.csv_config_path)
        full_cfg["csv_read_options"] = sanitized["csv_read_options"]
        full_cfg["default_rule"] = sanitized["default_rule"]
        full_cfg["file_rules"] = sanitized["file_rules"]
        save_json(self.csv_config_path, full_cfg)
        return True, "تنظیمات استخراج ذخیره شد."

    def _extract_cidrs_from_csv(self, file_path: Path) -> tuple[list[str], list[str]]:
        valid_items: list[str] = []
        invalid_items: list[str] = []
        seen: set[str] = set()

        header_candidates = {"cidr", "subnet", "network", "range"}
        target_col: Optional[int] = None
        has_rows = False
        first_data_row = True

        def _process_csv_stream(reader: csv.reader) -> None:
            nonlocal target_col, has_rows, first_data_row
            for row in reader:
                has_rows = True
                stripped_row = [str(cell or "").strip() for cell in row]
                if first_data_row:
                    first_data_row = False
                    lowered = [cell.lower() for cell in stripped_row]
                    for idx, cell in enumerate(lowered):
                        if cell in header_candidates:
                            target_col = idx
                            break
                    if target_col is not None:
                        # Header row detected, do not treat it as data.
                        continue

                cells = [cell for cell in stripped_row if cell]
                if not cells:
                    continue

                candidates = []
                if target_col is not None and target_col < len(stripped_row):
                    candidates.append(stripped_row[target_col])
                else:
                    candidates.extend(cells)

                for raw_item in candidates:
                    normalized = normalize_ipv4_cidr(raw_item)
                    if normalized is None or normalized in seen:
                        continue
                    seen.add(normalized)
                    valid_items.append(normalized)

        try:
            with file_path.open("r", encoding="utf-8-sig", newline="") as f:
                _process_csv_stream(csv.reader(f))
        except UnicodeDecodeError:
            target_col = None
            has_rows = False
            first_data_row = True
            with file_path.open("r", encoding="latin1", newline="") as f:
                _process_csv_stream(csv.reader(f))

        if not has_rows:
            return [], []

        if not valid_items:
            invalid_items.append("CSV file does not contain a valid IPv4 CIDR value.")
        return valid_items, invalid_items
    def _manual_cidrs(self) -> list[str]:
        rows = [
            line.strip()
            for line in self.manual_file.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        seen: set[str] = set()
        deduped: list[str] = []
        for row in rows:
            if row not in seen:
                seen.add(row)
                deduped.append(row)
        return deduped

    def _resolve_source_csv_from_name(self, name: str) -> Optional[Path]:
        raw_name = (name or "").strip().replace("\\", "/")
        if not raw_name.startswith("source/"):
            return None
        rel_part = raw_name[len("source/") :].strip("/")
        if not rel_part:
            return None
        target_path = (self.source_dir / rel_part).resolve()
        try:
            target_path.relative_to(self.source_dir)
        except ValueError:
            return None
        if self._is_uploaded_source_file(target_path):
            return None
        if not target_path.is_file() or target_path.suffix.lower() != ".csv":
            return None
        return target_path

    def _source_display_name(self, source_path: Path) -> str:
        return f"source/{source_path.relative_to(self.source_dir).as_posix()}"

    def _is_uploaded_source_file(self, source_path: Path) -> bool:
        try:
            source_path.resolve().relative_to(self.uploads_dir)
            return True
        except ValueError:
            return False

    @staticmethod
    def _is_csv_file(path: Path) -> bool:
        return path.is_file() and path.suffix.lower() == ".csv"

    def _iter_uploaded_csv_files(self) -> list[Path]:
        if not self.uploads_dir.exists():
            return []
        output: list[Path] = []
        seen_dirs: set[Path] = set()
        for root, dirs, files in os.walk(self.uploads_dir, followlinks=True):
            root_path = Path(root).resolve()
            if root_path in seen_dirs:
                dirs[:] = []
                continue
            seen_dirs.add(root_path)
            for name in files:
                path = (root_path / name).resolve()
                if self._is_csv_file(path):
                    output.append(path)
        return sorted(output)

    def _iter_source_csv_files(self) -> list[Path]:
        if not self.source_dir.exists():
            return []
        output: list[Path] = []
        blocked_dirs = {self.uploads_dir.resolve(), self.temp_uploads_dir.resolve()}
        seen_dirs: set[Path] = set()
        for root, dirs, files in os.walk(self.source_dir, followlinks=True):
            root_path = Path(root).resolve()
            if root_path in seen_dirs:
                dirs[:] = []
                continue
            seen_dirs.add(root_path)
            dirs[:] = [
                d
                for d in dirs
                if (root_path / d).resolve() not in blocked_dirs
            ]
            for name in files:
                path = (root_path / name).resolve()
                if not self._is_csv_file(path):
                    continue
                output.append(path)
        return sorted(output)

    def _cidr_count_cached(self, file_path: Path, parse_if_missing: bool = True) -> int:
        try:
            stat = file_path.stat()
        except OSError:
            return 0
        cache_key = str(file_path.resolve())
        marker = (int(stat.st_size), int(stat.st_mtime_ns))
        cached = self._csv_count_cache.get(cache_key)
        if cached and cached[0] == marker[0] and cached[1] == marker[1]:
            return int(cached[2])
        if not parse_if_missing:
            return 0
        cidrs, _ = self._extract_cidrs_from_csv(file_path)
        count = len(cidrs)
        self._csv_count_cache[cache_key] = (marker[0], marker[1], count)
        return count

    def list_csv_files(self) -> list[dict]:
        output: list[dict] = []
        disabled_files = self._load_disabled_files()
        for file_path in self._iter_uploaded_csv_files():
            try:
                file_size = file_path.stat().st_size
            except OSError:
                continue
            cidr_count = self._cidr_count_cached(file_path, parse_if_missing=False)
            output.append(
                {
                    "name": file_path.name,
                    "size": file_size,
                    "cidr_count": cidr_count,
                    "enabled": file_path.name not in disabled_files,
                    "can_toggle": True,
                    "can_delete": True,
                }
            )
        for file_path in self._iter_source_csv_files():
            try:
                file_size = file_path.stat().st_size
            except OSError:
                continue
            cidr_count = self._cidr_count_cached(file_path, parse_if_missing=False)
            display_name = self._source_display_name(file_path)
            output.append(
                {
                    "name": display_name,
                    "size": file_size,
                    "cidr_count": cidr_count,
                    "enabled": display_name not in disabled_files,
                    "can_toggle": True,
                    "can_delete": False,
                }
            )
        return output

    @staticmethod
    def _validate_upload_filename(filename: str) -> tuple[bool, str]:
        safe_name = Path(filename or "").name
        if not safe_name or not safe_name.lower().endswith(".csv"):
            return False, "فقط فایل CSV قابل آپلود است."
        return True, safe_name

    def _cleanup_upload_session(self, upload_id: str) -> None:
        session = self._upload_sessions.pop(upload_id, None)
        if not session:
            return
        parts_dir = session.get("parts_dir")
        if isinstance(parts_dir, Path):
            shutil.rmtree(parts_dir, ignore_errors=True)

    @staticmethod
    def _touch_upload_session_locked(session: dict[str, Any]) -> None:
        session["updated_at"] = time.time()

    def _cleanup_expired_upload_sessions_locked(self) -> None:
        now = time.time()
        expired_ids: list[str] = []
        for upload_id, session in self._upload_sessions.items():
            last_touch = float(session.get("updated_at", session.get("started_at", now)))
            if (now - last_touch) > self._upload_session_ttl_sec:
                expired_ids.append(upload_id)
        for upload_id in expired_ids:
            self._cleanup_upload_session(upload_id)
            self._upload_log(upload_id, "session expired and cleaned up", level="WARN")

    def _maybe_cleanup_stale_upload_artifacts(self, force: bool = False) -> None:
        now = time.time()
        if not force and (now - self._last_stale_upload_cleanup_at) < 60:
            return

        with self._upload_lock:
            active_dirs: set[Path] = set()
            for session in self._upload_sessions.values():
                parts_dir = session.get("parts_dir")
                if isinstance(parts_dir, Path):
                    active_dirs.add(parts_dir.resolve())

        try:
            entries = list(self.temp_uploads_dir.iterdir())
        except OSError:
            self._last_stale_upload_cleanup_at = now
            return

        for entry in entries:
            if not entry.is_dir():
                continue
            entry_path = entry.resolve()
            if entry_path in active_dirs:
                continue
            try:
                age_sec = now - entry_path.stat().st_mtime
            except OSError:
                continue
            if (not force) and age_sec < self._stale_upload_artifact_ttl_sec:
                continue
            shutil.rmtree(entry_path, ignore_errors=True)
            self._upload_log(entry_path.name, "stale temporary upload artifacts removed", level="WARN")

        self._last_stale_upload_cleanup_at = now

    def _merge_contiguous_parts_locked(self, upload_id: str, session: dict[str, Any]) -> int:
        parts_dir: Path = session["parts_dir"]
        merged_path: Path = session["merged_path"]
        next_merge_index = int(session.get("next_merge_index", 0))
        total_chunks = int(session["total_chunks"])
        merged_now = 0

        with merged_path.open("ab") as merged_f:
            while next_merge_index < total_chunks:
                part_path = (parts_dir / f"{next_merge_index:08d}.part").resolve()
                if not part_path.exists():
                    break
                part_size = part_path.stat().st_size
                with part_path.open("rb") as part_f:
                    shutil.copyfileobj(part_f, merged_f)
                part_path.unlink(missing_ok=True)
                session["merged_bytes"] = int(session.get("merged_bytes", 0)) + part_size
                next_merge_index += 1
                merged_now += 1

        session["next_merge_index"] = next_merge_index
        if merged_now >= 2:
            self._upload_log(
                upload_id,
                f"incremental merge merged_now={merged_now} next_index={next_merge_index}/{total_chunks}",
            )
        return merged_now

    def start_upload_session(self, filename: str, total_size: int, chunk_size: int) -> tuple[bool, str, dict]:
        self._maybe_cleanup_stale_upload_artifacts()
        ok, safe_name = self._validate_upload_filename(filename)
        if not ok:
            return False, safe_name, {}
        if total_size <= 0:
            return False, "حجم فایل معتبر نیست.", {}
        if chunk_size <= 0:
            return False, "اندازه chunk معتبر نیست.", {}
        total_chunks = int(math.ceil(total_size / chunk_size))
        if total_chunks <= 0:
            return False, "تعداد chunkها معتبر نیست.", {}

        upload_id = uuid.uuid4().hex
        parts_dir = (self.temp_uploads_dir / upload_id).resolve()
        parts_dir.mkdir(parents=True, exist_ok=True)
        merged_path = (parts_dir / "merged.partial").resolve()
        merged_path.write_bytes(b"")

        with self._upload_lock:
            self._cleanup_expired_upload_sessions_locked()
            self._upload_sessions[upload_id] = {
                "filename": safe_name,
                "total_size": int(total_size),
                "chunk_size": int(chunk_size),
                "total_chunks": total_chunks,
                "uploaded_bytes": 0,
                "received_chunks": set(),
                "parts_dir": parts_dir,
                "merged_path": merged_path,
                "next_merge_index": 0,
                "merged_bytes": 0,
                "started_at": time.time(),
                "updated_at": time.time(),
            }
        self._upload_log(
            upload_id,
            f"session started filename={safe_name} total_size={int(total_size)} total_chunks={total_chunks}",
        )
        return True, "نشست آپلود ایجاد شد.", {
            "upload_id": upload_id,
            "filename": safe_name,
            "total_size": int(total_size),
            "chunk_size": int(chunk_size),
            "total_chunks": total_chunks,
        }
    def upload_chunk(self, upload_id: str, chunk_index: int, raw_bytes: bytes) -> tuple[bool, str, dict]:
        with self._upload_lock:
            self._cleanup_expired_upload_sessions_locked()
            session = self._upload_sessions.get(upload_id)
            if session is None:
                self._upload_log(upload_id, "chunk rejected: invalid/expired session", level="WARN")
                return False, "نشست آپلود معتبر نیست یا منقضی شده است.", {}
            total_chunks = int(session["total_chunks"])
            if chunk_index < 0 or chunk_index >= total_chunks:
                self._upload_log(upload_id, f"chunk rejected: invalid chunk_index={chunk_index}", level="WARN")
                return False, "شماره chunk نامعتبر است.", {}

            received_chunks: set[int] = session["received_chunks"]
            if chunk_index in received_chunks:
                uploaded_bytes = int(session["uploaded_bytes"])
                progress_percent = round((uploaded_bytes / max(1, int(session["total_size"]))) * 100, 2)
                return True, "chunk تکراری نادیده گرفته شد.", {
                    "uploaded_chunks": len(received_chunks),
                    "total_chunks": total_chunks,
                    "uploaded_bytes": uploaded_bytes,
                    "total_size": int(session["total_size"]),
                    "progress_percent": progress_percent,
                }

            parts_dir: Path = session["parts_dir"]
            part_path = (parts_dir / f"{chunk_index:08d}.part").resolve()
            part_path.write_bytes(raw_bytes)
            received_chunks.add(chunk_index)
            session["uploaded_bytes"] = int(session["uploaded_bytes"]) + len(raw_bytes)
            self._touch_upload_session_locked(session)
            try:
                self._merge_contiguous_parts_locked(upload_id, session)
            except Exception as exc:
                self._upload_log_exception(upload_id, "chunk merge failed", exc)
                return False, "????? chunk?? ?????? ???.", {}
            uploaded_bytes = int(session["uploaded_bytes"])
            progress_percent = round((uploaded_bytes / max(1, int(session["total_size"]))) * 100, 2)
            if len(received_chunks) == 1 or len(received_chunks) == total_chunks or len(received_chunks) % 25 == 0:
                self._upload_log(
                    upload_id,
                    f"chunk accepted index={chunk_index} received={len(received_chunks)}/{total_chunks} "
                    f"bytes={uploaded_bytes}/{int(session['total_size'])} progress={min(100.0, progress_percent)}%",
                )
            return True, "chunk دریافت شد.", {
                "uploaded_chunks": len(received_chunks),
                "total_chunks": total_chunks,
                "uploaded_bytes": uploaded_bytes,
                "total_size": int(session["total_size"]),
                "progress_percent": min(100.0, progress_percent),
            }
    def complete_upload_session(self, upload_id: str) -> tuple[bool, str]:
        with self._upload_lock:
            self._cleanup_expired_upload_sessions_locked()
            session = self._upload_sessions.get(upload_id)
            if session is None:
                self._upload_log(upload_id, "complete rejected: invalid/expired session", level="WARN")
                return False, "???? ????? ????? ???? ?? ????? ??? ???."
            total_chunks = int(session["total_chunks"])
            received_chunks: set[int] = set(session["received_chunks"])
            if len(received_chunks) != total_chunks:
                self._upload_log(
                    upload_id,
                    f"complete rejected: chunks missing received={len(received_chunks)}/{total_chunks}",
                    level="WARN",
                )
                return False, "????? ???? ???? ???? ???."
            safe_name = str(session["filename"])
            merged_path: Path = session["merged_path"]
            expected_size = int(session["total_size"])
            started_at = float(session.get("started_at", time.time()))
            try:
                self._merge_contiguous_parts_locked(upload_id, session)
            except Exception as exc:
                self._upload_log_exception(upload_id, "complete failed: incremental merge flush failed", exc)
                self._cleanup_upload_session(upload_id)
                return False, "????? chunk?? ?????? ???."
            if int(session.get("next_merge_index", 0)) != total_chunks:
                self._upload_log(upload_id, "complete failed: merged stream is incomplete", level="ERROR")
                self._cleanup_upload_session(upload_id)
                return False, "????? chunk?? ?????? ???."

        self._upload_log(
            upload_id,
            f"complete started filename={safe_name} expected_size={expected_size} total_chunks={total_chunks}",
        )

        target_path = (self.uploads_dir / safe_name).resolve()
        if target_path.parent != self.uploads_dir:
            self._cleanup_upload_session(upload_id)
            self._upload_log(upload_id, "complete failed: invalid target path", level="ERROR")
            return False, "??? ???? ??????? ???."

        try:
            os.replace(merged_path, target_path)
        except Exception as exc:
            target_path.unlink(missing_ok=True)
            self._cleanup_upload_session(upload_id)
            self._upload_log_exception(upload_id, "complete failed: unable to finalize merged chunks", exc)
            return False, "????? chunk?? ?????? ???."

        merged_size = target_path.stat().st_size
        if merged_size != expected_size:
            target_path.unlink(missing_ok=True)
            self._cleanup_upload_session(upload_id)
            self._upload_log(
                upload_id,
                f"complete failed: unexpected merged size actual={merged_size} expected={expected_size}",
                level="ERROR",
            )
            return False, "?????? ???? ????? ????? ????."

        disabled_files = self._load_disabled_files()
        if safe_name in disabled_files:
            disabled_files.remove(safe_name)
            self._save_disabled_files(disabled_files)

        self._csv_count_cache.pop(str(target_path.resolve()), None)
        self._cleanup_upload_session(upload_id)
        elapsed_sec = round(time.time() - started_at, 3)
        self._upload_log(
            upload_id,
            f"complete success filename={safe_name} size={merged_size} elapsed_sec={elapsed_sec}",
        )
        return True, "فایل CSV با موفقیت آپلود شد."

    def cancel_upload_session(self, upload_id: str) -> tuple[bool, str]:
        with self._upload_lock:
            self._cleanup_expired_upload_sessions_locked()
            if upload_id not in self._upload_sessions:
                self._upload_log(upload_id, "cancel rejected: invalid/expired session", level="WARN")
                return False, "نشست آپلود معتبر نیست یا قبلا تمام شده است."
        self._cleanup_upload_session(upload_id)
        self._upload_log(upload_id, "session canceled by user", level="WARN")
        return True, "آپلود توسط کاربر لغو شد."

    def upload_csv(self, filename: str, raw_bytes: bytes) -> tuple[bool, str]:
        upload_id = f"direct-{uuid.uuid4().hex[:12]}"
        ok, safe_name = self._validate_upload_filename(filename)
        if not ok:
            self._upload_log(upload_id, f"direct upload rejected: {safe_name}", level="WARN")
            return False, safe_name

        target_path = (self.uploads_dir / safe_name).resolve()
        if target_path.parent != self.uploads_dir:
            self._upload_log(upload_id, "direct upload rejected: invalid target path", level="WARN")
            return False, "نام فایل نامعتبر است."

        self._upload_log(upload_id, f"direct upload started filename={safe_name} payload_size={len(raw_bytes)}")
        try:
            target_path.write_bytes(raw_bytes)
        except OSError as exc:
            self._upload_log_exception(upload_id, "direct upload failed: unable to write file", exc)
            return False, "????? ??? ????? ????."
        try:
            cidrs, errors = self._extract_cidrs_from_csv(target_path)
        except Exception as exc:
            target_path.unlink(missing_ok=True)
            self._upload_log_exception(upload_id, "direct upload failed: csv parse/validation error", exc)
            return False, "خواندن فایل CSV ممکن نشد."

        if not cidrs:
            target_path.unlink(missing_ok=True)
            self._upload_log(upload_id, "direct upload failed: no valid CIDR found in CSV", level="ERROR")
            return False, errors[0] if errors else "فایل CSV هیچ CIDR معتبری ندارد."

        disabled_files = self._load_disabled_files()
        if safe_name in disabled_files:
            disabled_files.remove(safe_name)
            self._save_disabled_files(disabled_files)

        self._csv_count_cache.pop(str(target_path.resolve()), None)
        self._upload_log(upload_id, f"direct upload success filename={safe_name} cidr_count={len(cidrs)}")
        return True, f"فایل CSV با موفقیت آپلود شد ({len(cidrs)} CIDR)."
    def delete_csv(self, filename: str) -> tuple[bool, str]:
        source_file = self._resolve_source_csv_from_name(filename)
        if source_file is not None:
            return False, "فایل‌های CSV پوشه source از پنل قابل حذف نیستند."
        safe_name = Path(filename or "").name
        if not safe_name:
            return False, "نام فایل الزامی است."
        target_path = (self.uploads_dir / safe_name).resolve()
        if target_path.parent != self.uploads_dir or not target_path.exists():
            return False, "فایل درخواستی پیدا نشد."
        target_path.unlink(missing_ok=True)
        self._csv_count_cache.pop(str(target_path.resolve()), None)
        disabled_files = self._load_disabled_files()
        if safe_name in disabled_files:
            disabled_files.remove(safe_name)
            self._save_disabled_files(disabled_files)
        return True, "فایل CSV حذف شد."

    def set_csv_enabled(self, filename: str, enabled: bool) -> tuple[bool, str]:
        source_file = self._resolve_source_csv_from_name(filename)
        if source_file is not None:
            file_key = self._source_display_name(source_file)
        else:
            safe_name = Path(filename or "").name
            if not safe_name:
                return False, "نام فایل الزامی است."
            target_path = (self.uploads_dir / safe_name).resolve()
            if target_path.parent != self.uploads_dir or not target_path.exists():
                return False, "فایل درخواستی پیدا نشد."
            file_key = safe_name

        disabled_files = self._load_disabled_files()
        if enabled:
            disabled_files.discard(file_key)
            message = "فایل CSV فعال شد."
        else:
            disabled_files.add(file_key)
            message = "فایل CSV غیرفعال شد."
        self._save_disabled_files(disabled_files)
        return True, message

    def set_manual_cidrs(self, raw_text: str) -> tuple[bool, str]:
        valid_items, invalid_items = parse_cidrs_from_text(raw_text)
        if invalid_items:
            return (
                False,
                f"CIDR نامعتبر: {', '.join(invalid_items[:8])}"
                + (" ..." if len(invalid_items) > 8 else ""),
            )
        self.manual_file.write_text("\n".join(valid_items) + ("\n" if valid_items else ""), encoding="utf-8")
        return True, f"{len(valid_items)} CIDR ذخیره شد."

    def status(self) -> dict:
        with self._upload_lock:
            self._cleanup_expired_upload_sessions_locked()
        self._maybe_cleanup_stale_upload_artifacts()
        files = self.list_csv_files()
        manual = self._manual_cidrs()
        total = len(manual)
        for item in files:
            if item.get("enabled", True):
                total += item["cidr_count"]
        enabled_csv_count = sum(1 for item in files if item.get("enabled", True))
        return {
            "files": files,
            "manual_cidrs": manual,
            "total_cidrs": total,
            "enabled_csv_count": enabled_csv_count,
            "disabled_csv_count": max(0, len(files) - enabled_csv_count),
        }

    def build_merged_csv(self) -> tuple[Optional[Path], int]:
        all_cidrs: list[str] = []
        seen: set[str] = set()
        disabled_files = self._load_disabled_files()

        for file_path in self._iter_uploaded_csv_files():
            if file_path.name in disabled_files:
                continue
            cidrs, _ = self._extract_cidrs_from_csv(file_path)
            for cidr in cidrs:
                if cidr not in seen:
                    seen.add(cidr)
                    all_cidrs.append(cidr)

        for file_path in self._iter_source_csv_files():
            file_key = self._source_display_name(file_path)
            if file_key in disabled_files:
                continue
            cidrs, _ = self._extract_cidrs_from_csv(file_path)
            for cidr in cidrs:
                if cidr not in seen:
                    seen.add(cidr)
                    all_cidrs.append(cidr)

        for cidr in self._manual_cidrs():
            if cidr not in seen:
                seen.add(cidr)
                all_cidrs.append(cidr)

        if not all_cidrs:
            return None, 0

        with self.merged_csv_file.open("w", encoding="utf-8", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["cidr"])
            for cidr in all_cidrs:
                writer.writerow([cidr])
        return self.merged_csv_file, len(all_cidrs)


class ScanManager:
    def __init__(self, source_dir: Path, csv_config_path: Path, scanner_config_path: Path):
        self.source_dir = source_dir.resolve()
        self.csv_config_path = csv_config_path.resolve()
        self.scanner_config_path = scanner_config_path.resolve()

        self.lock = threading.RLock()
        self.thread: Optional[threading.Thread] = None
        self.stop_event = threading.Event()

        self.state = "idle"  # idle | preparing | running | paused | completed | error
        self.total = 0
        self.scanned = 0
        self.confirmed = 0
        self.rejected = 0
        self.stop_requested = False
        self.last_error = ""
        self.updated_at = time.time()
        self.has_started_once = False
        self.logs = deque(maxlen=1500)
        self._pending_source_csv: Optional[Path] = None
        self._pending_source_label = "pipeline"

        scanner_cfg = load_scanner_config_resolved(str(self.scanner_config_path))
        self.output_file = Path(scanner_cfg["output_file"]).resolve()
        self.active_csv_file = Path(scanner_cfg["csv_file"]).resolve()
        self.active_cidr_column = scanner_cfg.get("cidr_column", "cidr")
        self._sync_scan_params_from(scanner_cfg)
        self._hydrate_resume_state_if_possible()

    def _sync_scan_params_from(self, scanner_cfg: dict) -> None:
        self.timeout = float(scanner_cfg.get("timeout", 2))
        self.max_workers = int(scanner_cfg.get("max_workers", 100))
        self.max_in_flight = max(1, int(scanner_cfg.get("max_in_flight", self.max_workers * 4)))
        self.query_domain = scanner_cfg.get("query_domain", "google.com")
        self.query_type = scanner_cfg.get("query_type", "A").upper()
        self.resume_enabled = bool(scanner_cfg.get("resume_enabled", True))
        self.resume_meta_file = Path(
            scanner_cfg.get("resume_meta_file", ".scanner_resume_meta.json")
        ).resolve()
        self.resume_db_file = Path(scanner_cfg.get("resume_db_file", ".scanner_progress.sqlite3")).resolve()

    def _log(self, message: str) -> None:
        ts = time.strftime("%H:%M:%S")
        with self.lock:
            self.logs.append(f"[{ts}] {message}")
            self.updated_at = time.time()

    def _clear_resume_artifacts(self) -> None:
        self.resume_db_file.unlink(missing_ok=True)
        self.resume_meta_file.unlink(missing_ok=True)
        self.output_file.unlink(missing_ok=True)

    def _hydrate_resume_state_if_possible(self) -> None:
        try:
            if not self.resume_enabled:
                return
            if not self.resume_db_file.exists() or not self.active_csv_file.exists():
                return

            source_abs_path = str(self.active_csv_file.resolve())
            source_fingerprint = scanner_module.file_sha256(source_abs_path)
            meta = scanner_module.load_resume_meta(str(self.resume_meta_file))

            conn = scanner_module.init_resume_db(str(self.resume_db_file))
            try:
                db_source, db_fingerprint = scanner_module.get_scan_state(conn)
                previous_source = meta.get("source_file") or db_source
                previous_fingerprint = meta.get("source_sha256") or db_fingerprint
                if previous_source != source_abs_path or previous_fingerprint != source_fingerprint:
                    return

                total = count_total_ips(str(self.active_csv_file), self.active_cidr_column)
                confirmed, rejected, scanned = scanner_module.get_resume_counts(conn)
            finally:
                conn.close()

            if total == 0:
                return

            with self.lock:
                self.total = total
                self.scanned = scanned
                self.confirmed = confirmed
                self.rejected = rejected
                self.has_started_once = scanned > 0
                if 0 < scanned < total:
                    self.state = "paused"
                    self._log("اسکن نیمه‌کاره قبلی پیدا شد. می‌توانید ادامه دهید.")
                elif scanned >= total:
                    self.state = "completed"
        except Exception:
            # Keep panel usable even if old resume state is malformed.
            pass

    def _start_thread(self, target) -> None:
        self.stop_event.clear()
        self.thread = threading.Thread(target=target, daemon=True)
        self.thread.start()

    def start_fresh(self, source_csv: Optional[Path] = None, source_label: str = "pipeline") -> tuple[bool, str]:
        with self.lock:
            if self.state in {"preparing", "running"}:
                return False, "اسکن در حال اجرا است."
            self.state = "preparing"
            self.has_started_once = True
            self.stop_requested = False
            self.last_error = ""
            self.total = 0
            self.scanned = 0
            self.confirmed = 0
            self.rejected = 0
            self._pending_source_csv = source_csv.resolve() if source_csv else None
            self._pending_source_label = source_label
            self._log("در حال شروع اسکن از ابتدا...")
            self._start_thread(self._run_fresh_pipeline_and_scan)
            return True, "اسکن از ابتدا شروع شد."

    def resume(self) -> tuple[bool, str]:
        with self.lock:
            if self.state in {"preparing", "running"}:
                return False, "اسکن در حال اجرا است."
            if not (0 < self.scanned < self.total):
                return False, "اسکن نیمه‌کاره‌ای برای ادامه وجود ندارد."
            self.state = "running"
            self.stop_requested = False
            self.last_error = ""
            self._log("ادامه اسکن از وضعیت قبلی...")
            self._start_thread(self._run_resume_scan)
            return True, "ادامه اسکن شروع شد."

    def stop(self) -> tuple[bool, str]:
        with self.lock:
            if self.state not in {"preparing", "running"}:
                return False, "اسکن در حال اجرا نیست."
            if self.stop_requested:
                return False, "درخواست توقف قبلاً ثبت شده است."
            self.stop_requested = True
            self.stop_event.set()
            self._log("درخواست توقف ثبت شد.")
            return True, "درخواست توقف ثبت شد."

    def clear_logs(self) -> None:
        with self.lock:
            self.logs.clear()
            self.updated_at = time.time()

    def _run_fresh_pipeline_and_scan(self) -> None:
        try:
            scanner_cfg = load_scanner_config_resolved(str(self.scanner_config_path))
            self._sync_scan_params_from(scanner_cfg)
            self.output_file = Path(scanner_cfg["output_file"]).resolve()
            pending_source = self._pending_source_csv
            if pending_source is not None:
                if not pending_source.exists():
                    raise FileNotFoundError(f"فایل CSV منبع پیدا نشد: {pending_source}")
                scanner_cfg["csv_file"] = str(pending_source)
                scanner_cfg["cidr_column"] = resolve_cidr_column(pending_source, "cidr")
                self.active_csv_file = pending_source
                self.active_cidr_column = scanner_cfg["cidr_column"]
                self._sync_scan_params_from(scanner_cfg)
                self._clear_resume_artifacts()
                self._log(f"Using panel source: {self._pending_source_label}")
                self._scan_loop(continue_mode=False)
                return

            self._log("مرحله 1/3: استخراج ZIPها از ابتدا.")
            extract_results = extract_all_zips(self.source_dir, overwrite=True)
            failed_zip_count = sum(1 for item in extract_results if not item["success"])
            self._log(f"تعداد ZIP پردازش‌شده: {len(extract_results)} | خطا: {failed_zip_count}")
            if self.stop_event.is_set():
                self._mark_paused()
                return

            self._log("مرحله 2/3: پردازش فایل‌های CSV از ابتدا.")
            extractor = CSVExtractor(self.csv_config_path)
            extraction_result = extractor.run()
            if not extraction_result.success:
                raise RuntimeError("استخراج CSV ناموفق بود.")
            extracted_csv = Path(extraction_result.output_file).resolve()
            self._log(
                f"CSV آماده شد | رکورد استخراج‌شده: {extraction_result.total_records_extracted}"
            )
            if self.stop_event.is_set():
                self._mark_paused()
                return

            scanner_cfg["csv_file"] = str(extracted_csv)
            scanner_cfg["cidr_column"] = resolve_cidr_column(
                extracted_csv, scanner_cfg.get("cidr_column", "cidr")
            )
            self.active_csv_file = extracted_csv
            self.active_cidr_column = scanner_cfg["cidr_column"]
            self._sync_scan_params_from(scanner_cfg)
            self._clear_resume_artifacts()

            self._log("مرحله 3/3: شروع اسکن IPها.")
            self._scan_loop(continue_mode=False)
        except Exception as exc:
            with self.lock:
                self.state = "error"
                self.stop_requested = False
                self.last_error = str(exc)
                self._log(f"خطا: {exc}")

        finally:
            with self.lock:
                self._pending_source_csv = None
                self._pending_source_label = "pipeline"

    def _run_resume_scan(self) -> None:
        try:
            scanner_cfg = load_scanner_config_resolved(str(self.scanner_config_path))
            self._sync_scan_params_from(scanner_cfg)
            self.output_file = Path(scanner_cfg["output_file"]).resolve()
            if not self.active_csv_file.exists():
                raise FileNotFoundError(f"فایل CSV پیدا نشد: {self.active_csv_file}")
            self._scan_loop(continue_mode=True)
        except Exception as exc:
            with self.lock:
                self.state = "error"
                self.stop_requested = False
                self.last_error = str(exc)
                self._log(f"خطا: {exc}")

    def _mark_paused(self) -> None:
        with self.lock:
            self.state = "paused"
            self.stop_requested = False
            self._log("اسکن متوقف شد.")

    def _scan_loop(self, continue_mode: bool) -> None:
        qtype_code = 1 if self.query_type == "A" else 28
        dns_query = build_dns_query(self.query_domain, qtype_code)

        total = count_total_ips(str(self.active_csv_file), self.active_cidr_column)
        if total <= 0:
            raise RuntimeError("هیچ IP قابل اسکن پیدا نشد.")

        resume_conn = None
        try:
            if self.resume_enabled:
                resume_conn = scanner_module.init_resume_db(str(self.resume_db_file))
                source_abs_path = str(self.active_csv_file.resolve())
                source_fingerprint = scanner_module.file_sha256(source_abs_path)
                scanner_module.set_scan_state(resume_conn, source_abs_path, source_fingerprint)
                scanner_module.save_resume_meta(
                    str(self.resume_meta_file),
                    {
                        "source_file": source_abs_path,
                        "source_sha256": source_fingerprint,
                        "updated_at": time.time(),
                    },
                )

            with self.lock:
                self.state = "running"
                self.total = total
                if continue_mode and resume_conn is not None:
                    confirmed, rejected, scanned = scanner_module.get_resume_counts(resume_conn)
                    self.confirmed = confirmed
                    self.rejected = rejected
                    self.scanned = scanned
                else:
                    self.confirmed = 0
                    self.rejected = 0
                    self.scanned = 0
                self.updated_at = time.time()

            if continue_mode and resume_conn is not None and not self.output_file.exists():
                with self.output_file.open("w", encoding="utf-8") as rebuild_out:
                    for row in resume_conn.execute(
                        "SELECT ip FROM scanned_ips WHERE status = 'confirmed' ORDER BY ip"
                    ):
                        rebuild_out.write(f"{row[0]}\n")

            output_mode = "a" if continue_mode else "w"
            with self.output_file.open(output_mode, encoding="utf-8") as out_f:
                ip_stream = stream_ips_from_csv(str(self.active_csv_file), self.active_cidr_column)

                def submit_one(executor: ThreadPoolExecutor, in_flight: dict) -> bool:
                    while True:
                        if self.stop_event.is_set():
                            return False
                        try:
                            ip = next(ip_stream)
                        except StopIteration:
                            return False

                        if continue_mode and resume_conn is not None:
                            existing = resume_conn.execute(
                                "SELECT 1 FROM scanned_ips WHERE ip = ?",
                                (ip,),
                            ).fetchone()
                            if existing is not None:
                                continue

                        future = executor.submit(scan_ip, ip, self.timeout, dns_query)
                        in_flight[future] = ip
                        return True

                with ThreadPoolExecutor(max_workers=self.max_workers) as executor:
                    in_flight = {}
                    for _ in range(self.max_in_flight):
                        if not submit_one(executor, in_flight):
                            break

                    while in_flight:
                        done, _ = wait(in_flight.keys(), return_when=FIRST_COMPLETED)
                        for future in done:
                            ip = in_flight.pop(future)
                            status_db = "rejected"
                            status_label = "REJECTED"
                            try:
                                result = future.result()
                                if result:
                                    status_db = "confirmed"
                                    status_label = "CONFIRMED"
                                    out_f.write(result + "\n")
                                    out_f.flush()
                            except Exception:
                                status_db = "error"
                                status_label = "ERROR"

                            if resume_conn is not None:
                                resume_conn.execute(
                                    "INSERT OR REPLACE INTO scanned_ips (ip, status, scanned_at) VALUES (?, ?, ?)",
                                    (ip, status_db, time.time()),
                                )
                                resume_conn.commit()

                            with self.lock:
                                self.scanned += 1
                                if status_db == "confirmed":
                                    self.confirmed += 1
                                else:
                                    self.rejected += 1
                                self.logs.append(
                                    f"[{time.strftime('%H:%M:%S')}] IP={ip} RESULT={status_label} "
                                    f"PROGRESS={self.scanned}/{self.total}"
                                )
                                self.updated_at = time.time()

                            while len(in_flight) < self.max_in_flight and not self.stop_event.is_set():
                                if not submit_one(executor, in_flight):
                                    break

                        if self.stop_event.is_set() and not in_flight:
                            break

            with self.lock:
                if self.stop_event.is_set():
                    self.state = "paused"
                    self.stop_requested = False
                    self._log("اسکن متوقف شد.")
                elif self.scanned >= self.total:
                    self.state = "completed"
                    self.stop_requested = False
                    self._log("اسکن کامل شد.")
                else:
                    self.state = "paused"
                    self.stop_requested = False
                    self._log("اسکن نیمه‌کاره متوقف شد.")
        finally:
            if resume_conn is not None:
                resume_conn.close()

    def snapshot(self) -> dict:
        with self.lock:
            progress = (self.scanned / self.total * 100) if self.total else 0.0
            is_resumable = self.state in {"paused", "error"} and (0 < self.scanned < self.total)
            has_history = self.scanned > 0 or self.state == "completed"
            if self.state in {"preparing", "running"}:
                action_mode = "running"
            elif is_resumable:
                action_mode = "resumable"
            elif has_history:
                action_mode = "restart_only"
            else:
                action_mode = "never_started"

            return {
                "state": self.state,
                "total": self.total,
                "scanned": self.scanned,
                "confirmed": self.confirmed,
                "rejected": self.rejected,
                "progress_percent": round(progress, 2),
                "last_error": self.last_error,
                "stop_requested": self.stop_requested,
                "updated_at": self.updated_at,
                "logs": list(self.logs),
                "action_mode": action_mode,
                "query_domain": self.query_domain,
                "timeout": self.timeout,
                "query_type": self.query_type,
            }


class DnsTestManager:
    def __init__(self, output_file: str, query_domain: str, timeout: float):
        self.output_file = Path(output_file).resolve()
        self.default_domain = query_domain
        self.default_timeout = timeout

        self.lock = threading.RLock()
        self.thread: Optional[threading.Thread] = None
        self.stop_event = threading.Event()

        self.state = "idle"
        self.stop_requested = False
        self.logs = deque(maxlen=1000)
        self.results: list[dict] = []
        self.current_domain = query_domain
        self.current_timeout = timeout
        self.updated_at = time.time()

    def _log(self, message: str) -> None:
        ts = time.strftime("%H:%M:%S")
        with self.lock:
            self.logs.append(f"[{ts}] {message}")
            self.updated_at = time.time()

    def clear_logs(self) -> None:
        with self.lock:
            self.logs.clear()
            self.updated_at = time.time()

    def _load_dns_list(self) -> list[str]:
        if not self.output_file.exists():
            return []
        rows = [line.strip() for line in self.output_file.read_text(encoding="utf-8").splitlines()]
        return sorted({r for r in rows if r})

    def start(self, domain: Optional[str], timeout: Optional[float]) -> tuple[bool, str]:
        with self.lock:
            if self.state == "running":
                return False, "تست در حال اجرا است."

            selected_domain = (domain or self.current_domain or self.default_domain).strip()
            if not selected_domain:
                return False, "دامنه تست نمی‌تواند خالی باشد."

            selected_timeout = self.current_timeout if timeout is None else timeout
            if selected_timeout <= 0:
                return False, "Timeout باید بزرگ‌تر از صفر باشد."

            self.current_domain = selected_domain
            self.current_timeout = float(selected_timeout)
            self.results = []
            self.state = "running"
            self.stop_requested = False
            self.stop_event.clear()
            self.thread = threading.Thread(target=self._run_tests, daemon=True)
            self.thread.start()
            self._log(
                f"تست DNS شروع شد. domain={self.current_domain} timeout={self.current_timeout}s"
            )
            return True, "تست DNS شروع شد."

    def stop(self) -> tuple[bool, str]:
        with self.lock:
            if self.state != "running":
                return False, "تست در حال اجرا نیست."
            if self.stop_requested:
                return False, "درخواست توقف قبلاً ثبت شده است."
            self.stop_requested = True
            self.stop_event.set()
            self._log("درخواست توقف تست ثبت شد.")
            return True, "درخواست توقف تست ثبت شد."

    def _probe(self, dns_ip: str) -> tuple[bool, float]:
        query = build_dns_query(self.current_domain, 1)
        start = time.perf_counter()
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(self.current_timeout)
                sock.sendto(query, (dns_ip, 53))
                data, _ = sock.recvfrom(512)
                elapsed_ms = (time.perf_counter() - start) * 1000
                if len(data) >= 12:
                    return True, elapsed_ms
                return False, elapsed_ms
        except OSError:
            return False, -1.0

    def _run_tests(self) -> None:
        try:
            dns_list = self._load_dns_list()
            if not dns_list:
                with self.lock:
                    self.state = "completed"
                    self.stop_requested = False
                    self.logs.append(f"[{time.strftime('%H:%M:%S')}] DNS تاییدشده‌ای برای تست وجود ندارد.")
                    self.updated_at = time.time()
                return

            temp_results: list[dict] = []
            for ip in dns_list:
                if self.stop_event.is_set():
                    break
                ok, latency = self._probe(ip)
                item = {
                    "ip": ip,
                    "ok": ok,
                    "latency_ms": round(latency, 2) if latency >= 0 else None,
                    "rank_score": latency if ok else 9999999.0,
                }
                temp_results.append(item)
                temp_results.sort(key=lambda x: x["rank_score"])
                with self.lock:
                    self.results = [
                        {
                            "ip": row["ip"],
                            "ok": row["ok"],
                            "latency_ms": row["latency_ms"],
                        }
                        for row in temp_results
                    ]
                    status = "OK" if ok else "FAILED"
                    latency_text = f"{item['latency_ms']}ms" if item["latency_ms"] is not None else "timeout/error"
                    self.logs.append(f"[{time.strftime('%H:%M:%S')}] DNS={ip} نتیجه={status} زمان={latency_text}")
                    self.updated_at = time.time()

            with self.lock:
                self.stop_requested = False
                if self.stop_event.is_set():
                    self.state = "paused"
                    self.logs.append(f"[{time.strftime('%H:%M:%S')}] تست DNS متوقف شد.")
                else:
                    self.state = "completed"
                    self.logs.append(f"[{time.strftime('%H:%M:%S')}] تست DNS کامل شد.")
                self.updated_at = time.time()
        except Exception as exc:
            with self.lock:
                self.state = "error"
                self.stop_requested = False
                self.logs.append(f"[{time.strftime('%H:%M:%S')}] خطا: {exc}")
                self.updated_at = time.time()

    def _display_rows(self) -> list[dict]:
        if self.results:
            known = {row["ip"] for row in self.results}
            rows = list(self.results)
            for ip in self._load_dns_list():
                if ip not in known:
                    rows.append({"ip": ip, "ok": None, "latency_ms": None})
            return rows
        return [{"ip": ip, "ok": None, "latency_ms": None} for ip in self._load_dns_list()]

    def ranked_text(self) -> str:
        rows = self._display_rows()
        lines = [row["ip"] for row in rows if row.get("ip")]
        return "\n".join(lines) + ("\n" if lines else "")

    def snapshot(self) -> dict:
        with self.lock:
            rows = self._display_rows()
            return {
                "state": self.state,
                "stop_requested": self.stop_requested,
                "query_domain": self.current_domain,
                "timeout": self.current_timeout,
                "results": rows,
                "logs": list(self.logs),
                "updated_at": self.updated_at,
            }


def create_app(config_path: Path) -> Flask:
    panel_cfg = load_json(config_path)
    scanner_config_path = Path(panel_cfg["scanner_config_path"]).resolve()
    base_dir = scanner_config_path.parent
    source_dir = Path(panel_cfg.get("source_dir", str((base_dir / "source").resolve())))
    csv_config_path = Path(
        panel_cfg.get("csv_config_path", str((base_dir / "csv_extractor_config.json").resolve()))
    )

    scanner_cfg = load_scanner_config_resolved(str(scanner_config_path))
    resource_manager = ResourceManager(base_dir, csv_config_path)
    scan_manager = ScanManager(
        source_dir=source_dir,
        csv_config_path=csv_config_path,
        scanner_config_path=scanner_config_path,
    )
    dns_tester = DnsTestManager(
        output_file=scanner_cfg["output_file"],
        query_domain=scanner_cfg.get("query_domain", "google.com"),
        timeout=float(scanner_cfg.get("timeout", 2)),
    )

    app = Flask(__name__)
    app.secret_key = panel_cfg["secret_key"]

    def persist_scan_settings(query_domain: str, timeout: float, query_type: str) -> None:
        raw_cfg = load_json(scanner_config_path)
        raw_cfg["query_domain"] = query_domain
        raw_cfg["timeout"] = timeout
        raw_cfg["query_type"] = query_type
        save_json(scanner_config_path, raw_cfg)

    def is_logged_in() -> bool:
        return bool(session.get("logged_in"))

    @app.before_request
    def auth_guard():
        public_endpoints = {"login", "static"}
        if request.endpoint in public_endpoints:
            return None
        if not is_logged_in():
            return redirect(url_for("login"))
        return None

    @app.route("/login", methods=["GET", "POST"])
    def login():
        error = ""
        if request.method == "POST":
            username = request.form.get("username", "").strip()
            password = request.form.get("password", "")
            if username == panel_cfg["username"] and check_password_hash(
                panel_cfg["password_hash"], password
            ):
                session["logged_in"] = True
                return redirect(url_for("dashboard"))
            error = "نام کاربری یا رمز عبور اشتباه است."
        return render_template("login.html", error=error)

    @app.route("/logout")
    def logout():
        session.clear()
        return redirect(url_for("login"))

    @app.route("/")
    def dashboard():
        return render_template("panel.html")

    @app.route("/api/app/info")
    def api_app_info():
        return jsonify(
            {
                "ok": True,
                "name": APP_NAME,
                "version": APP_VERSION,
                "repository": APP_REPOSITORY,
            }
        )

    @app.route("/api/scan/start", methods=["POST"])
    def api_scan_start():
        payload = request.get_json(silent=True) or {}
        domain_ok, normalized_domain, domain_error = normalize_domain(payload.get("query_domain", ""))
        if not domain_ok:
            return jsonify({"ok": False, "message": domain_error})

        timeout_ok, timeout_value, timeout_error = parse_scan_timeout(payload.get("timeout"))
        if not timeout_ok:
            return jsonify({"ok": False, "message": timeout_error})

        criterion_ok, query_type, criterion_error = normalize_query_type(payload.get("query_type", ""))
        if not criterion_ok:
            return jsonify({"ok": False, "message": criterion_error})

        effective_timeout = timeout_value if timeout_value is not None else scan_manager.timeout
        persist_scan_settings(normalized_domain, effective_timeout, query_type)

        source_csv = None
        source_label = "pipeline"
        resources_snapshot = resource_manager.status()
        has_resource_inputs = bool(resources_snapshot.get("files")) or bool(
            resources_snapshot.get("manual_cidrs")
        )

        merged_csv, merged_count = resource_manager.build_merged_csv()
        if has_resource_inputs:
            if merged_csv is None or merged_count <= 0:
                return jsonify(
                    {
                        "ok": False,
                        "message": "در منابع، CIDR فعالی برای اسکن وجود ندارد. "
                        "حداقل یک منبع را فعال کنید یا CIDR دستی اضافه کنید.",
                    }
                )
            source_csv = merged_csv
            source_label = f"panel resources ({merged_count} CIDRs)"

        ok, message = scan_manager.start_fresh(source_csv=source_csv, source_label=source_label)
        return jsonify({"ok": ok, "message": message})

    @app.route("/api/scan/stop", methods=["POST"])
    def api_scan_stop():
        ok, message = scan_manager.stop()
        return jsonify({"ok": ok, "message": message})

    @app.route("/api/scan/resume", methods=["POST"])
    def api_scan_resume():
        ok, message = scan_manager.resume()
        return jsonify({"ok": ok, "message": message})

    @app.route("/api/scan/status")
    def api_scan_status():
        return jsonify(scan_manager.snapshot())

    @app.route("/api/scan/logs/clear", methods=["POST"])
    def api_scan_logs_clear():
        scan_manager.clear_logs()
        return jsonify({"ok": True})

    @app.route("/api/resources/status")
    def api_resources_status():
        return jsonify(resource_manager.status())

    @app.route("/api/resources/extractor-config")
    def api_resources_extractor_config():
        try:
            payload = resource_manager.extractor_settings()
        except Exception as exc:
            return jsonify({"ok": False, "message": str(exc)}), 400
        return jsonify({"ok": True, **payload})

    @app.route("/api/resources/extractor-config", methods=["POST"])
    def api_resources_extractor_config_save():
        payload = request.get_json(silent=True) or {}
        ok, message = resource_manager.save_extractor_settings(payload.get("settings"))
        if not ok:
            return jsonify({"ok": False, "message": message}), 400
        return jsonify({"ok": True, "message": message, "config": resource_manager.extractor_settings()})

    @app.route("/api/resources/upload-csv", methods=["POST"])
    def api_resources_upload_csv():
        uploaded_file = request.files.get("file")
        if uploaded_file is None:
            return jsonify({"ok": False, "message": "فایل CSV الزامی است."})
        raw_bytes = uploaded_file.read()
        ok, message = resource_manager.upload_csv(uploaded_file.filename, raw_bytes)
        return jsonify({"ok": ok, "message": message, "status": resource_manager.status()})

    @app.route("/api/resources/upload-csv/init", methods=["POST"])
    def api_resources_upload_csv_init():
        payload = request.get_json(silent=True) or {}
        filename = str(payload.get("name", "")).strip()
        try:
            total_size = int(payload.get("size", 0))
            chunk_size = int(payload.get("chunk_size", 0))
        except (TypeError, ValueError):
            return jsonify({"ok": False, "message": "پارامترهای آپلود معتبر نیست."}), 400

        ok, message, upload_info = resource_manager.start_upload_session(
            filename=filename,
            total_size=total_size,
            chunk_size=chunk_size,
        )
        if not ok:
            return jsonify({"ok": False, "message": message}), 400
        return jsonify({"ok": True, "message": message, **upload_info})

    @app.route("/api/resources/upload-csv/chunk", methods=["POST"])
    def api_resources_upload_csv_chunk():
        upload_id = str(request.form.get("upload_id", "")).strip()
        chunk_index_raw = request.form.get("chunk_index")
        chunk_file = request.files.get("chunk")
        if not upload_id:
            return jsonify({"ok": False, "message": "upload_id ارسال نشده است."}), 400
        if chunk_file is None:
            return jsonify({"ok": False, "message": "chunk ارسال نشده است."}), 400
        try:
            chunk_index = int(chunk_index_raw)
        except (TypeError, ValueError):
            return jsonify({"ok": False, "message": "شماره chunk نامعتبر است."}), 400

        ok, message, chunk_status = resource_manager.upload_chunk(
            upload_id=upload_id,
            chunk_index=chunk_index,
            raw_bytes=chunk_file.read(),
        )
        if not ok:
            return jsonify({"ok": False, "message": message}), 400
        return jsonify({"ok": True, "message": message, **chunk_status})

    @app.route("/api/resources/upload-csv/complete", methods=["POST"])
    def api_resources_upload_csv_complete():
        payload = request.get_json(silent=True) or {}
        upload_id = str(payload.get("upload_id", "")).strip()
        if not upload_id:
            upload_id = str(request.form.get("upload_id", "")).strip()
        if not upload_id:
            return jsonify({"ok": False, "message": "upload_id ارسال نشده است."}), 400
        ok, message = resource_manager.complete_upload_session(upload_id)
        if not ok:
            return jsonify({"ok": False, "message": message}), 400
        return jsonify({"ok": True, "message": message})

    @app.route("/api/resources/upload-csv/cancel", methods=["POST"])
    def api_resources_upload_csv_cancel():
        payload = request.get_json(silent=True) or {}
        upload_id = str(payload.get("upload_id", "")).strip()
        if not upload_id:
            upload_id = str(request.form.get("upload_id", "")).strip()
        if not upload_id:
            return jsonify({"ok": False, "message": "upload_id ارسال نشده است."}), 400
        ok, message = resource_manager.cancel_upload_session(upload_id)
        if not ok:
            return jsonify({"ok": False, "message": message}), 400
        return jsonify({"ok": True, "message": message})

    @app.route("/api/resources/manual-cidrs", methods=["POST"])
    def api_resources_manual_cidrs():
        payload = request.get_json(silent=True) or {}
        cidrs_text = payload.get("cidrs_text", "")
        ok, message = resource_manager.set_manual_cidrs(cidrs_text)
        return jsonify({"ok": ok, "message": message, "status": resource_manager.status()})

    @app.route("/api/resources/delete-csv", methods=["POST"])
    def api_resources_delete_csv():
        payload = request.get_json(silent=True) or {}
        filename = payload.get("name", "")
        ok, message = resource_manager.delete_csv(filename)
        return jsonify({"ok": ok, "message": message, "status": resource_manager.status()})

    @app.route("/api/resources/set-csv-enabled", methods=["POST"])
    def api_resources_set_csv_enabled():
        payload = request.get_json(silent=True) or {}
        filename = payload.get("name", "")
        enabled = bool(payload.get("enabled", True))
        ok, message = resource_manager.set_csv_enabled(filename, enabled)
        return jsonify({"ok": ok, "message": message, "status": resource_manager.status()})

    @app.route("/api/dns-test/start", methods=["POST"])
    def api_dns_test_start():
        payload = request.get_json(silent=True) or {}
        domain = payload.get("domain")
        timeout_value = payload.get("timeout")
        timeout_float = None
        if timeout_value not in (None, ""):
            try:
                timeout_float = float(timeout_value)
            except (TypeError, ValueError):
                return jsonify({"ok": False, "message": "Timeout نامعتبر است."})

        ok, message = dns_tester.start(domain=domain, timeout=timeout_float)
        return jsonify({"ok": ok, "message": message})

    @app.route("/api/dns-test/stop", methods=["POST"])
    def api_dns_test_stop():
        ok, message = dns_tester.stop()
        return jsonify({"ok": ok, "message": message})

    @app.route("/api/dns-test/status")
    def api_dns_test_status():
        return jsonify(dns_tester.snapshot())

    @app.route("/api/dns-test/logs/clear", methods=["POST"])
    def api_dns_logs_clear():
        dns_tester.clear_logs()
        return jsonify({"ok": True})

    @app.route("/api/dns-test/download")
    def api_dns_download():
        content = dns_tester.ranked_text()
        return Response(
            content,
            mimetype="text/plain; charset=utf-8",
            headers={"Content-Disposition": "attachment; filename=dns_ranked.txt"},
        )

    return app


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="DNS Scout Persian Web Panel")
    parser.add_argument(
        "--config",
        default="panel_config.json",
        help="Path to panel config JSON file.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    config_path = Path(args.config).resolve()
    panel_cfg = load_json(config_path)
    app = create_app(config_path)
    app.run(host="0.0.0.0", port=int(panel_cfg["port"]), threaded=True)


if __name__ == "__main__":
    main()







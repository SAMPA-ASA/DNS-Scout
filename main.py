#!/usr/bin/env python3
import argparse
import csv
import json
import logging
import shutil
import sys
import tempfile
import time
import uuid
import zipfile
from pathlib import Path
from typing import Optional

import scanner as scanner_module
from csv_extractor import CSVExtractor
from logging_utils import setup_colored_logging
from scanner import main as scanner_main
from zip_extractor import extract_all_zips


def resolve_cidr_column(csv_path: Path, preferred_column: str) -> str:
    with csv_path.open("r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        headers = reader.fieldnames or []
    if preferred_column in headers:
        return preferred_column
    if not headers:
        raise ValueError(f"No header found in '{csv_path}'.")
    return headers[0]


def resolve_extractor_output_file(csv_config_path: str) -> Path:
    cfg_path = Path(csv_config_path).resolve()
    with cfg_path.open("r", encoding="utf-8") as f:
        cfg = json.load(f)
    output_file = cfg.get("output_file", "filtered_CIDR_database.csv")
    output_path = Path(output_file)
    if not output_path.is_absolute():
        output_path = (cfg_path.parent / output_path).resolve()
    return output_path


def load_scanner_config_resolved(
    scanner_config_path: str, output_file: Optional[str] = None
) -> dict:
    scanner_config_abs = Path(scanner_config_path).resolve()
    scanner_config_dir = scanner_config_abs.parent
    with scanner_config_abs.open("r", encoding="utf-8") as f:
        scanner_cfg = json.load(f)

    if output_file:
        scanner_cfg["output_file"] = str(Path(output_file).resolve())
    elif "output_file" in scanner_cfg:
        scanner_cfg["output_file"] = str((scanner_config_dir / scanner_cfg["output_file"]).resolve())

    if "resume_meta_file" in scanner_cfg:
        scanner_cfg["resume_meta_file"] = str(
            (scanner_config_dir / scanner_cfg["resume_meta_file"]).resolve()
        )
    if "resume_db_file" in scanner_cfg:
        scanner_cfg["resume_db_file"] = str(
            (scanner_config_dir / scanner_cfg["resume_db_file"]).resolve()
        )
    return scanner_cfg


def can_resume_without_rebuild(scanner_cfg: dict, csv_file: Path) -> bool:
    if not bool(scanner_cfg.get("resume_enabled", True)):
        return False
    resume_db_file = scanner_cfg.get("resume_db_file", ".scanner_progress.sqlite3")
    resume_meta_file = scanner_cfg.get("resume_meta_file", ".scanner_resume_meta.json")
    if not Path(resume_db_file).exists():
        return False
    if not csv_file.exists():
        return False

    source_abs_path = str(csv_file.resolve())
    source_fingerprint = scanner_module.file_sha256(source_abs_path)
    meta = scanner_module.load_resume_meta(resume_meta_file)

    db_source = None
    db_fingerprint = None
    probe_conn = scanner_module.init_resume_db(resume_db_file)
    try:
        db_source, db_fingerprint = scanner_module.get_scan_state(probe_conn)
    finally:
        probe_conn.close()

    previous_source = meta.get("source_file") or db_source
    previous_fingerprint = meta.get("source_sha256") or db_fingerprint
    return previous_source == source_abs_path and previous_fingerprint == source_fingerprint


def run_pipeline(
    source_dir: str,
    csv_config_path: str,
    scanner_config_path: str,
    output_file: Optional[str] = None,
) -> int:
    logger = logging.getLogger("pipeline")
    scanner_cfg = load_scanner_config_resolved(scanner_config_path, output_file)
    extracted_csv_file = resolve_extractor_output_file(csv_config_path)

    if can_resume_without_rebuild(scanner_cfg, extracted_csv_file):
        logger.info(
            "Resume data detected for unchanged source CSV. Skipping ZIP/CSV extraction and continuing scan."
        )
    else:
        logger.info("Step 1/3: extracting ZIP files from '%s' ...", source_dir)
        zip_results = extract_all_zips(source_dir)
        failed_zip_count = sum(1 for item in zip_results if not item["success"])
        if failed_zip_count:
            logger.warning("%s ZIP file(s) failed to extract.", failed_zip_count)
        else:
            logger.info("ZIP extraction completed successfully.")

        logger.info("Step 2/3: extracting and filtering CSV data ...")
        extractor = CSVExtractor(csv_config_path)
        extraction_result = extractor.run()
        if not extraction_result.success:
            logger.error("CSV extraction failed.")
            for file_path, err in extraction_result.errors:
                logger.error("  %s: %s", file_path, err)
            return 1
        extracted_csv_file = Path(extraction_result.output_file).resolve()
        logger.info(
            "CSV extraction completed. records=%s output=%s",
            extraction_result.total_records_extracted,
            extraction_result.output_file,
        )

    logger.info("Step 3/3: scanning DNS IPs ...")
    scanner_cfg["csv_file"] = str(extracted_csv_file)
    scanner_cfg["cidr_column"] = resolve_cidr_column(
        extracted_csv_file, scanner_cfg.get("cidr_column", "cidr")
    )

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False, encoding="utf-8"
    ) as tmp_cfg:
        json.dump(scanner_cfg, tmp_cfg, ensure_ascii=False, indent=2)
        tmp_cfg_path = tmp_cfg.name

    try:
        scanner_main(tmp_cfg_path)
    finally:
        Path(tmp_cfg_path).unlink(missing_ok=True)
    logger.info("DNS scan completed. live IP list saved to '%s'.", scanner_cfg["output_file"])
    return 0


def run_self_test() -> int:
    logger = logging.getLogger("pipeline.test")
    logger.info("Running pipeline self-test ...")

    base = Path.cwd() / f".pipeline_selftest_{int(time.time())}_{uuid.uuid4().hex[:8]}"
    try:
        base.mkdir(parents=True, exist_ok=True)
        source_dir = base / "source"
        source_dir.mkdir(parents=True, exist_ok=True)

        input_csv_name = "IP2LOCATION-LITE-DB1.CSV"
        input_csv_content = (
            "subnet,country_code,country_name\n"
            "1.1.1.0/30,IR,Iran (Islamic Republic of)\n"
            "8.8.8.0/30,US,United States\n"
            "9.9.9.0/30,IR,Iran (Islamic Republic of)\n"
        )

        zip_path = source_dir / "sample_data.zip"
        with zipfile.ZipFile(zip_path, "w") as zf:
            zf.writestr(input_csv_name, input_csv_content)

        extracted_output_csv = base / "filtered.csv"
        live_output_file = base / "live_dns.txt"

        csv_config_path = base / "csv_extractor_config.json"
        csv_config = {
            "target_directory": str(source_dir),
            "output_file": str(extracted_output_csv),
            "csv_read_options": {"encoding": "utf-8", "delimiter": ",", "header": True},
            "default_rule": {
                "filter": {
                    "logic": "AND",
                    "conditions": [
                        {"column": "country_code", "operator": "equals", "value": "IR"}
                    ],
                },
                "columns_to_extract": ["subnet"],
            },
            "file_rules": [],
            "output_deduplicate": {"enabled": True, "columns": ["subnet"], "keep": "first"},
            "output_format": {"encoding": "utf-8", "delimiter": ",", "index": False},
        }
        csv_config_path.write_text(
            json.dumps(csv_config, ensure_ascii=False, indent=2), encoding="utf-8"
        )

        scanner_config_path = base / "scanner_config.json"
        scanner_config = {
            "csv_file": str(extracted_output_csv),
            "output_file": str(live_output_file),
            "cidr_column": "subnet",
            "timeout": 0.1,
            "max_workers": 4,
            "query_domain": "example.com",
            "query_type": "A",
        }
        scanner_config_path.write_text(
            json.dumps(scanner_config, ensure_ascii=False, indent=2), encoding="utf-8"
        )

        original_scan_ip = scanner_module.scan_ip

        def fake_scan_ip(ip: str, timeout: float, query: bytes) -> Optional[str]:
            del timeout, query
            if ip in {"1.1.1.1", "9.9.9.1"}:
                return ip
            return None

        scanner_module.scan_ip = fake_scan_ip
        try:
            exit_code = run_pipeline(
                source_dir=str(source_dir),
                csv_config_path=str(csv_config_path),
                scanner_config_path=str(scanner_config_path),
                output_file=str(live_output_file),
            )
        finally:
            scanner_module.scan_ip = original_scan_ip

        if exit_code != 0:
            logger.error("Self-test failed: pipeline returned non-zero exit code.")
            return 1

        if not live_output_file.exists():
            logger.error("Self-test failed: output file was not created.")
            return 1

        found_ips = {
            line.strip()
            for line in live_output_file.read_text(encoding="utf-8").splitlines()
            if line.strip()
        }
        expected_ips = {"1.1.1.1", "9.9.9.1"}

        if found_ips != expected_ips:
            logger.error("Self-test failed: expected %s, got %s", expected_ips, found_ips)
            return 1

        logger.info("Self-test passed. Found expected live IPs: %s", sorted(found_ips))
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run ZIP extraction -> CSV extraction -> DNS scan pipeline."
    )
    parser.add_argument(
        "--source-dir",
        default="source",
        help="Root folder containing ZIP files (default: source).",
    )
    parser.add_argument(
        "--csv-config",
        default="csv_extractor_config.json",
        help="Path to CSV extractor config file (default: csv_extractor_config.json).",
    )
    parser.add_argument(
        "--scanner-config",
        default="scanner_config.json",
        help="Path to scanner config file (default: scanner_config.json).",
    )
    parser.add_argument(
        "--output-file",
        default=None,
        help="Optional override for scanner output file.",
    )
    parser.add_argument(
        "--test",
        action="store_true",
        help="Run self-test for the full pipeline with temporary test data.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    setup_colored_logging(level=logging.INFO)
    try:
        if args.test:
            return run_self_test()
        return run_pipeline(
            source_dir=args.source_dir,
            csv_config_path=args.csv_config,
            scanner_config_path=args.scanner_config,
            output_file=args.output_file,
        )
    except Exception as exc:
        logging.getLogger("pipeline").exception("Pipeline failed: %s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
DNS Scanner for CIDR ranges from a CSV file, controlled by a JSON config.

The JSON config may contain:
    - "csv_file"         : path to the CSV containing CIDRs
    - "output_file"      : path where live DNS IPs will be written
    - "cidr_column"      : column name in the CSV holding the CIDRs (default: "cidr")
    - "timeout"          : UDP timeout in seconds (default: 2)
    - "max_workers"      : number of concurrent threads (default: 100)
    - "query_domain"     : domain to resolve during the DNS probe (default: "google.com")
    - "query_type"       : DNS record type (default: "A" – only A records supported)
"""

import json
import csv
import ipaddress
import struct
import socket
import hashlib
import os
import sqlite3
import sys
import time
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait

from logging_utils import BOLD, CYAN, GREEN, MAGENTA, RED, YELLOW, colorize


# ---------- DNS packet crafting ----------
def build_dns_query(domain: str, qtype: int = 1) -> bytes:
    """
    Build a minimal DNS query packet for the given domain and record type.
    qtype: 1 = A, 28 = AAAA (only A is used by default).
    """
    # Transaction ID (random 16 bits)
    txid = 0x1234  # fixed for simplicity; could use random
    flags = 0x0100  # standard query, recursion desired
    questions = 1
    # Header: ID, Flags, QDCOUNT, ANCOUNT, NSCOUNT, ARCOUNT
    header = struct.pack("!HHHHHH", txid, flags, questions, 0, 0, 0)

    # Encode domain name into QNAME format
    qname = b""
    for part in domain.encode("idna").split(b"."):
        qname += bytes([len(part)]) + part
    qname += b"\x00"  # terminating zero length

    # QTYPE and QCLASS (IN = 1)
    question = qname + struct.pack("!HH", qtype, 1)

    return header + question

def is_valid_dns_response(data: bytes) -> bool:
    """Check if the received UDP payload looks like a DNS response."""
    if len(data) < 12:
        return False
    # DNS header: second 16-bit word contains flags; QR bit is the MSB of the word.
    # We extract the flags field (offset 2, length 2)
    flags = struct.unpack_from("!H", data, 2)[0]
    qr = (flags >> 15) & 0x1
    return qr == 1

# ---------- UDP scanner ----------
def scan_ip(ip: str, timeout: float, query: bytes) -> str:
    """
    Send a DNS query to the given IP on port 53/UDP.
    Returns the IP if a valid DNS response is received, otherwise None.
    """
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(timeout)
            sock.sendto(query, (ip, 53))
            data, _ = sock.recvfrom(512)  # standard DNS response fits in 512 bytes
            if is_valid_dns_response(data):
                return ip
    except (socket.timeout, OSError):
        pass
    return None


def usable_host_count(net: ipaddress._BaseNetwork) -> int:
    # Keep counting cheap and RAM-friendly; this is used for progress display.
    if net.version == 4:
        if net.prefixlen >= 31:
            return int(net.num_addresses)
        return int(net.num_addresses - 2)
    if net.prefixlen >= 127:
        return int(net.num_addresses)
    return int(net.num_addresses - 1)


def count_total_ips(csv_file: str, cidr_column: str) -> int:
    total = 0
    with open(csv_file, "r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if cidr_column not in reader.fieldnames:
            raise ValueError(f"Column '{cidr_column}' not found in CSV. Available: {reader.fieldnames}")
        for row in reader:
            cidr = row[cidr_column].strip()
            if not cidr:
                continue
            try:
                net = ipaddress.ip_network(cidr, strict=False)
                total += usable_host_count(net)
            except ValueError as e:
                print(f"Skipping invalid CIDR '{cidr}': {e}", file=sys.stderr)
    return total


def stream_ips_from_csv(csv_file: str, cidr_column: str):
    with open(csv_file, "r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if cidr_column not in reader.fieldnames:
            raise ValueError(f"Column '{cidr_column}' not found in CSV. Available: {reader.fieldnames}")
        for row in reader:
            cidr = row[cidr_column].strip()
            if not cidr:
                continue
            try:
                net = ipaddress.ip_network(cidr, strict=False)
                for ip in net.hosts():
                    yield str(ip)
            except ValueError as e:
                print(f"Skipping invalid CIDR '{cidr}': {e}", file=sys.stderr)


def file_sha256(path: str, chunk_size: int = 1024 * 1024) -> str:
    hasher = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            hasher.update(chunk)
    return hasher.hexdigest()


def load_resume_meta(meta_path: str) -> dict:
    try:
        with open(meta_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_resume_meta(meta_path: str, payload: dict) -> None:
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)


def init_resume_db(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA synchronous=NORMAL;")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS scanned_ips (
            ip TEXT PRIMARY KEY,
            status TEXT NOT NULL,
            scanned_at REAL NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS scan_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """
    )
    conn.commit()
    return conn


def get_resume_counts(conn: sqlite3.Connection) -> tuple[int, int, int]:
    row = conn.execute(
        """
        SELECT
            SUM(CASE WHEN status = 'confirmed' THEN 1 ELSE 0 END) AS confirmed_count,
            SUM(CASE WHEN status IN ('rejected', 'error') THEN 1 ELSE 0 END) AS rejected_count,
            COUNT(*) AS scanned_count
        FROM scanned_ips
        """
    ).fetchone()
    confirmed = int(row[0] or 0)
    rejected = int(row[1] or 0)
    scanned = int(row[2] or 0)
    return confirmed, rejected, scanned


def get_scan_state(conn: sqlite3.Connection) -> tuple[str | None, str | None]:
    rows = conn.execute(
        "SELECT key, value FROM scan_state WHERE key IN ('source_file', 'source_sha256')"
    ).fetchall()
    state = {k: v for k, v in rows}
    return state.get("source_file"), state.get("source_sha256")


def set_scan_state(conn: sqlite3.Connection, source_file: str, source_sha256: str) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO scan_state (key, value) VALUES (?, ?)",
        ("source_file", source_file),
    )
    conn.execute(
        "INSERT OR REPLACE INTO scan_state (key, value) VALUES (?, ?)",
        ("source_sha256", source_sha256),
    )
    conn.commit()

# ---------- Main ----------
def main(config_path: str):
    # 1. Load configuration
    with open(config_path, "r", encoding="utf-8") as f:
        config = json.load(f)

    csv_file      = config["csv_file"]
    output_file   = config["output_file"]
    cidr_column   = config.get("cidr_column", "cidr")
    timeout       = float(config.get("timeout", 2))
    max_workers   = int(config.get("max_workers", 100))
    max_in_flight = int(config.get("max_in_flight", max_workers * 4))
    query_domain  = config.get("query_domain", "google.com")
    query_type    = config.get("query_type", "A").upper()
    resume_enabled = bool(config.get("resume_enabled", True))
    resume_meta_file = config.get("resume_meta_file", ".scanner_resume_meta.json")
    resume_db_file = config.get("resume_db_file", ".scanner_progress.sqlite3")
    max_in_flight = max(1, max_in_flight)

    # Build the DNS probe packet once
    qtype_code = 1 if query_type == "A" else 28  # Only A/AAAA for now
    dns_query = build_dns_query(query_domain, qtype_code)

    # 2. Stream CIDRs from CSV (no large IP list in RAM)
    total = count_total_ips(csv_file, cidr_column)
    print(
        f"{colorize('Total IPs to scan (streamed):', BOLD + CYAN)} "
        f"{colorize(str(total), BOLD + MAGENTA)}"
    )
    if total == 0:
        print(colorize("No IPs to scan. Exiting.", YELLOW))
        sys.exit(0)

    source_fingerprint = file_sha256(csv_file)
    source_abs_path = os.path.abspath(csv_file)

    continue_mode = False
    if resume_enabled:
        meta = load_resume_meta(resume_meta_file)
        has_previous_db = os.path.exists(resume_db_file)
        db_source = None
        db_fingerprint = None
        if has_previous_db:
            probe_conn = init_resume_db(resume_db_file)
            try:
                db_source, db_fingerprint = get_scan_state(probe_conn)
            finally:
                probe_conn.close()

        previous_fingerprint = meta.get("source_sha256") or db_fingerprint
        previous_source = meta.get("source_file") or db_source

        same_source = previous_source == source_abs_path
        same_fingerprint = previous_fingerprint == source_fingerprint

        if same_source and same_fingerprint and has_previous_db:
            answer = input(
                "Previous scan state found for unchanged source file. Continue from last scan? (y/N): "
            ).strip().lower()
            continue_mode = answer in {"y", "yes"}

        if not continue_mode:
            if os.path.exists(resume_db_file):
                os.remove(resume_db_file)
            if os.path.exists(output_file):
                os.remove(output_file)

    # 3. Scan IPs using a thread pool
    print(
        f"{colorize('[START]', BOLD + CYAN)} "
        f"{colorize('Scanning has started...', BOLD + CYAN)} "
        f"{colorize('workers:', CYAN)} {colorize(str(max_workers), BOLD + MAGENTA)} "
        f"{colorize('in_flight:', CYAN)} {colorize(str(max_in_flight), BOLD + MAGENTA)} "
        f"{colorize('timeout:', CYAN)} {colorize(str(timeout), BOLD + MAGENTA)}s "
        f"{colorize('domain:', CYAN)} {colorize(query_domain, BOLD + MAGENTA)}",
        flush=True,
    )
    resume_conn = None
    live_count = 0
    rejected_count = 0
    completed = 0
    skipped_previously_scanned = 0
    first_new_scan_logged = False

    resumed_scanned_count = 0
    if resume_enabled:
        resume_conn = init_resume_db(resume_db_file)
        # Persist source identity immediately, so interrupted runs can still resume.
        set_scan_state(resume_conn, source_abs_path, source_fingerprint)
        save_resume_meta(
            resume_meta_file,
            {
                "source_file": source_abs_path,
                "source_sha256": source_fingerprint,
                "updated_at": time.time(),
            },
        )
        if continue_mode:
            live_count, rejected_count, resumed_scanned_count = get_resume_counts(resume_conn)
            if not os.path.exists(output_file):
                with open(output_file, "w", encoding="utf-8") as rebuild_out:
                    for row in resume_conn.execute(
                        "SELECT ip FROM scanned_ips WHERE status = 'confirmed' ORDER BY ip"
                    ):
                        rebuild_out.write(f"{row[0]}\n")
            print(
                f"{colorize('[RESUME]', BOLD + CYAN)} "
                f"{colorize('Loaded previous progress.', BOLD + CYAN)} "
                f"{colorize('ALREADY-SCANNED:', CYAN)} {colorize(str(resumed_scanned_count), BOLD + MAGENTA)} "
                f"{colorize('CONFIRMED:', GREEN)} {colorize(str(live_count), BOLD + GREEN)} "
                f"{colorize('REJECTED:', RED)} {colorize(str(rejected_count), BOLD + RED)}",
                flush=True,
            )

    start_time = time.time()
    ip_stream = stream_ips_from_csv(csv_file, cidr_column)
    submitted = 0

    def submit_one(executor: ThreadPoolExecutor, in_flight: dict) -> bool:
        nonlocal submitted, skipped_previously_scanned, completed
        while True:
            try:
                ip = next(ip_stream)
            except StopIteration:
                return False
            if resume_conn is not None:
                status_row = resume_conn.execute(
                    "SELECT 1 FROM scanned_ips WHERE ip = ?",
                    (ip,),
                ).fetchone()
                if status_row is not None:
                    skipped_previously_scanned += 1
                    completed += 1
                    continue
            future = executor.submit(scan_ip, ip, timeout, dns_query)
            in_flight[future] = ip
            submitted += 1
            return True

    output_mode = "a" if continue_mode else "w"
    with open(output_file, output_mode, encoding="utf-8") as out_f:
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            in_flight = {}
            for _ in range(max_in_flight):
                if not submit_one(executor, in_flight):
                    break

            while in_flight:
                done, _ = wait(in_flight.keys(), return_when=FIRST_COMPLETED)
                for future in done:
                    completed += 1
                    ip = in_flight.pop(future)
                    try:
                        result = future.result()
                        if result:
                            # Save confirmed IP immediately to avoid keeping results in RAM.
                            out_f.write(result + "\n")
                            out_f.flush()
                            live_count += 1
                            status = colorize("CONFIRMED", BOLD + GREEN)
                            if resume_conn is not None:
                                resume_conn.execute(
                                    "INSERT OR REPLACE INTO scanned_ips (ip, status, scanned_at) VALUES (?, ?, ?)",
                                    (ip, "confirmed", time.time()),
                                )
                                resume_conn.commit()
                        else:
                            rejected_count += 1
                            status = colorize("REJECTED", BOLD + RED)
                            if resume_conn is not None:
                                resume_conn.execute(
                                    "INSERT OR REPLACE INTO scanned_ips (ip, status, scanned_at) VALUES (?, ?, ?)",
                                    (ip, "rejected", time.time()),
                                )
                                resume_conn.commit()
                    except Exception as e:
                        rejected_count += 1
                        status = colorize("ERROR", BOLD + YELLOW)
                        if resume_conn is not None:
                            resume_conn.execute(
                                "INSERT OR REPLACE INTO scanned_ips (ip, status, scanned_at) VALUES (?, ?, ?)",
                                (ip, "error", time.time()),
                            )
                            resume_conn.commit()
                        print(
                            f"{colorize('[ERROR]', YELLOW)} {colorize(ip, MAGENTA)}: {e}",
                            file=sys.stderr,
                        )

                    if not first_new_scan_logged:
                        first_new_scan_logged = True
                        print(
                            f"{colorize('[FIRST-SCAN]', BOLD + CYAN)} "
                            f"{colorize('First IP scan completed.', BOLD + CYAN)} "
                            f"{colorize('IP:', CYAN)} {colorize(ip, MAGENTA)} "
                            f"{colorize('RESULT:', CYAN)} {status}",
                            flush=True,
                        )

                    print(
                        f"{colorize('[SCAN]', CYAN)} "
                        f"{colorize(f'{completed}/{total}', BOLD)} "
                        f"{colorize('IP:', CYAN)} {colorize(ip, MAGENTA)} "
                        f"{colorize('RESULT:', CYAN)} {status} | "
                        f"{colorize('CONFIRMED:', GREEN)} {colorize(str(live_count), BOLD + GREEN)} "
                        f"{colorize('REJECTED:', RED)} {colorize(str(rejected_count), BOLD + RED)} "
                        f"{colorize('SKIPPED:', CYAN)} {colorize(str(skipped_previously_scanned), BOLD + MAGENTA)} "
                        f"{colorize('IN-FLIGHT:', CYAN)} {colorize(str(len(in_flight)), BOLD + MAGENTA)} "
                        f"{colorize('SUBMITTED:', CYAN)} {colorize(str(submitted), BOLD + MAGENTA)}",
                        flush=True,
                    )

                    while len(in_flight) < max_in_flight:
                        if not submit_one(executor, in_flight):
                            break

    elapsed = time.time() - start_time
    if resume_conn is not None:
        resume_conn.close()
        save_resume_meta(
            resume_meta_file,
            {
                "source_file": source_abs_path,
                "source_sha256": source_fingerprint,
                "updated_at": time.time(),
            },
        )
    print(
        f"{colorize('Scan completed in', BOLD + CYAN)} {elapsed:.1f}s. "
        f"{colorize('Found', BOLD + CYAN)} {colorize(str(live_count), BOLD + GREEN)} "
        f"{colorize('live DNS servers.', BOLD + CYAN)}"
    )
    print(f"{colorize('Results written to', BOLD + CYAN)} {colorize(output_file, MAGENTA)}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <scanner_config.json>")
        sys.exit(1)
    main(sys.argv[1])

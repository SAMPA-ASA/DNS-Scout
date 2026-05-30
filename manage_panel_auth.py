#!/usr/bin/env python3
import argparse
import getpass
import json
import os
import tempfile
from pathlib import Path

from werkzeug.security import generate_password_hash


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Update DNS Scout panel username/password in panel_config.json"
    )
    parser.add_argument(
        "--config",
        default="panel_config.json",
        help="Path to panel config JSON file (default: panel_config.json).",
    )
    parser.add_argument(
        "--username",
        default=None,
        help="New username. If omitted, asks interactively.",
    )
    parser.add_argument(
        "--password",
        default=None,
        help="New password. If omitted, asks interactively.",
    )
    return parser.parse_args()


def ask_username(current_username: str) -> str:
    entered = input(
        f"New username (press Enter to keep current: '{current_username}'): "
    ).strip()
    if entered:
        return entered
    return current_username


def ask_password() -> str:
    while True:
        password = getpass.getpass("New password: ")
        confirm = getpass.getpass("Confirm new password: ")
        if not password:
            print("Password cannot be empty.")
            continue
        if password != confirm:
            print("Passwords do not match. Try again.")
            continue
        return password


def atomic_write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.replace(tmp_path, path)
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)


def main() -> int:
    args = parse_args()
    config_path = Path(args.config).resolve()

    if not config_path.exists():
        print(f"Config file not found: {config_path}")
        return 1

    with config_path.open("r", encoding="utf-8") as f:
        cfg = json.load(f)

    current_username = str(cfg.get("username", "admin"))
    username = args.username.strip() if args.username else ask_username(current_username)
    if not username:
        print("Username cannot be empty.")
        return 1

    password = args.password if args.password else ask_password()
    if not password:
        print("Password cannot be empty.")
        return 1

    cfg["username"] = username
    cfg["password_hash"] = generate_password_hash(password)

    atomic_write_json(config_path, cfg)
    print(f"Panel credentials updated successfully in: {config_path}")
    print("If your panel is running, restart the service:")
    print("  sudo systemctl restart dns-scout.service")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

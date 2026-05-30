import logging
import os
import sys

RESET = "\033[0m"
BOLD = "\033[1m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
MAGENTA = "\033[35m"


def _enable_windows_ansi() -> bool:
    if os.name != "nt":
        return True
    try:
        import ctypes

        kernel32 = ctypes.windll.kernel32
        handle = kernel32.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
        mode = ctypes.c_uint32()
        if kernel32.GetConsoleMode(handle, ctypes.byref(mode)) == 0:
            return False
        enabled = mode.value | 0x0004  # ENABLE_VIRTUAL_TERMINAL_PROCESSING
        return kernel32.SetConsoleMode(handle, enabled) != 0
    except Exception:
        return False


_COLOR_ENABLED = sys.stdout.isatty() and _enable_windows_ansi()


def colorize(text: str, color: str) -> str:
    if not _COLOR_ENABLED:
        return text
    return f"{color}{text}{RESET}"


class ColorFormatter(logging.Formatter):
    LEVEL_COLORS = {
        logging.DEBUG: CYAN,
        logging.INFO: GREEN,
        logging.WARNING: YELLOW,
        logging.ERROR: RED,
        logging.CRITICAL: BOLD + RED,
    }

    def format(self, record: logging.LogRecord) -> str:
        original_levelname = record.levelname
        level_color = self.LEVEL_COLORS.get(record.levelno, "")
        record.levelname = colorize(original_levelname, level_color) if level_color else original_levelname
        try:
            return super().format(record)
        finally:
            record.levelname = original_levelname


def setup_colored_logging(level: int = logging.INFO) -> None:
    fmt = "%(asctime)s - %(levelname)s - %(name)s - %(message)s"
    handler = logging.StreamHandler()
    handler.setFormatter(ColorFormatter(fmt=fmt))
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(level)
    root.addHandler(handler)

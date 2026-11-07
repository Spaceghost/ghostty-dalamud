#!/usr/bin/env python3
"""Synthetic helper replies; no desktop access."""
import os
import sys

mode = os.environ.get("GHOSTTY_TEST_CLIPBOARD_REPLY", "safe")
replies = {
    "safe": b"\x01fixture text",
    "empty": b"\x01",
    "sensitive": b"\x03",
    "sensitive-text": b"\x03must not escape",
    "unknown": b"\x00text",
    "invalid": b"\x01\xc0\xaf",
    "oversized": b"\x01" + b"x" * 65537,
    "failed": b"\x01partial text",
}
sys.stdout.buffer.write(replies[mode])
sys.stdout.buffer.flush()
sys.exit(1 if mode == "failed" else 0)

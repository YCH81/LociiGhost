"""Resolve standard file-system paths used by the daemon."""

from __future__ import annotations

import os
from pathlib import Path


def app_support_dir() -> Path:
    """~/Library/Application Support/LociiGhost/"""
    base = Path(os.path.expanduser("~/Library/Application Support/LociiGhost"))
    base.mkdir(parents=True, exist_ok=True)
    return base


def cache_dir() -> Path:
    """~/Library/Caches/LociiGhost/"""
    base = Path(os.path.expanduser("~/Library/Caches/LociiGhost"))
    base.mkdir(parents=True, exist_ok=True)
    return base


def logs_dir() -> Path:
    """~/Library/Logs/LociiGhost/"""
    base = Path(os.path.expanduser("~/Library/Logs/LociiGhost"))
    base.mkdir(parents=True, exist_ok=True)
    return base


def socket_path() -> str:
    return str(app_support_dir() / "lociighost.sock")

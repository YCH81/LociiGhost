"""Every user-facing string has to exist in both languages.

The app ships zh-Hant and en side by side and switches live, so an
English literal with no zh-Hant entry doesn't fail — it renders in
English to a Chinese user, in the middle of an otherwise translated
screen. That is exactly how the whole v1.17 UI shipped untranslated,
and nothing in the build said a word.

This lives in the Python suite because it is a text check over the
repo, and the Swift test target can't read the app target's sources.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "App" / "Sources" / "LociiGhost"
RESOURCES = SRC / "Resources"
BACKLOG = ROOT / "docs" / "i18n-backlog.txt"

# How a user-facing literal is written in this codebase.
PATTERNS = [
    r'String\(\s*localized:\s*"((?:[^"\\]|\\.)*)"',
    r'Text\(\s*"((?:[^"\\]|\\.)*)"',
    r'titleKey:\s*"((?:[^"\\]|\\.)*)"',
    r'LocalizedStringKey\("((?:[^"\\]|\\.)*)"\)',
    r'Toggle\(\s*"((?:[^"\\]|\\.)*)"',
    r'Label\(\s*"((?:[^"\\]|\\.)*)"',
]

ENTRY = r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";'


def _entries(locale: str) -> dict[str, str]:
    path = RESOURCES / f"{locale}.lproj" / "Localizable.strings"
    return dict(re.findall(ENTRY, path.read_text(encoding="utf-8"), re.M))


def _literals() -> set[str]:
    out: set[str] = set()
    for swift in SRC.rglob("*.swift"):
        body = swift.read_text(encoding="utf-8")
        for pattern in PATTERNS:
            for found in re.findall(pattern, body, re.S):
                # An interpolated string isn't a lookup key, and a
                # one- or two-character literal is a separator.
                if "\\(" not in found and len(found) > 2:
                    out.add(found)
    return out


@pytest.fixture(scope="module")
def backlog() -> set[str]:
    if not BACKLOG.exists():
        pytest.skip("app sources not checked out beside the daemon")
    return {
        line for line in BACKLOG.read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    }


def test_both_locales_hold_the_same_keys():
    """They are edited by hand and in lockstep; a key in one only is a
    string that falls back to its English text in the other."""
    en, zh = _entries("en"), _entries("zh-Hant")
    assert set(en) == set(zh), {
        "en only": sorted(set(en) - set(zh))[:10],
        "zh only": sorted(set(zh) - set(en))[:10],
    }


def test_no_new_untranslated_strings(backlog):
    if not SRC.exists():
        pytest.skip("app sources not checked out beside the daemon")
    zh = set(_entries("zh-Hant"))
    missing = sorted(s for s in _literals() if s not in zh and s not in backlog)
    assert not missing, (
        "these strings would render in English to a zh-Hant user — add them to "
        f"both .lproj/Localizable.strings files: {missing}"
    )


def test_the_backlog_has_no_stale_lines(backlog):
    """A line here that has since been translated means the list is
    drifting; delete it so the count means something."""
    zh = set(_entries("zh-Hant"))
    done = sorted(s for s in backlog if s in zh)
    assert not done, f"already translated — delete from docs/i18n-backlog.txt: {done}"

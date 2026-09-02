"""Static checks on the phone remote's single-file page.

There is no browser in this suite, so these are the failures a browser
would have found on the first tap: a control whose element id the
script misspells, and a string that only exists in one of the two
locales. Both are silent — the first throws inside an event handler
nobody is watching, the second renders the key name to whoever is
using the other language.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest


PAGE = Path(__file__).resolve().parents[1] / "lociighostd" / "static" / "phone.html"

# The floating-joystick experiment was reverted to the known-good
# overlay (see the comment above `floatingJoystick`); its CSS and its
# `getElementById` calls are still there, and the code guards for the
# missing elements with `if (!pad || !knob) return null`. Removing that
# is its own change, not something this test should force.
KNOWN_ABSENT_IDS = {
    "floating-joystick",
    "floating-joystick-knob",
    "floating-joystick-close",
}


@pytest.fixture(scope="module")
def page() -> str:
    return PAGE.read_text(encoding="utf-8")


def test_every_element_the_script_reaches_for_exists(page):
    used = set(re.findall(r"getElementById\('([A-Za-z0-9_-]+)'\)", page))
    defined = set(re.findall(r'id="([A-Za-z0-9_-]+)"', page))
    assert used - defined <= KNOWN_ABSENT_IDS


def test_every_string_exists_in_both_locales(page):
    # The dictionary holds two locales, so a key present twice is a key
    # present in both. `(?<![A-Za-z_$])` keeps `createElement('div')`
    # from looking like `t('div')`.
    keys = set(re.findall(r"(?<![A-Za-z_$])t\('([a-z0-9_-]+)'\)", page))
    keys |= set(re.findall(r'data-i18n="([a-z0-9_-]+)"', page))
    table = page[page.index("const I18N"):]
    missing = [k for k in sorted(keys)
               if len(re.findall(r"'%s':" % re.escape(k), table)) < 2]
    assert not missing, f"only defined in one locale: {missing}"


def test_the_flower_control_is_wired_end_to_end(page):
    """Menu entry, sheet, and the call it makes — the three pieces that
    have to agree for the button to do anything."""
    assert 'data-kind="flower"' in page
    assert "kind === 'flower'" in page
    assert 'id="flower-overlay"' in page
    assert "'/api/phone/flower'" in page


def test_a_cooldown_refusal_is_not_rendered_as_an_object(page):
    """The gate answers 429 with an object, so a handler that toasts
    `detail` directly prints "[object Object]" at the exact moment the
    user most needs to know what happened."""
    assert "function toastFromError" in page
    assert "cooldown_active" in page
    # Nobody should be back to toasting the raw detail.
    assert "showToast(detail || t('request_failed'))" not in page

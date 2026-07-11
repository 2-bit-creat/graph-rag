"""Deterministic time-window parsing for graph chat (no LLM), Korean + English."""

from __future__ import annotations

import re
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

# Relative expressions — checked in order (longer phrases first).
_RELATIVE_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"그저께|엊그제"), "day_before_yesterday"),
    (re.compile(r"그제"), "day_before_yesterday"),
    (re.compile(r"어제"), "yesterday"),
    (re.compile(r"오늘"), "today"),
    (re.compile(r"이번\s*주"), "this_week"),
    (re.compile(r"지난\s*주|저번\s*주|지난주|저번주"), "last_week"),
    (re.compile(r"이번\s*달|이번\s*월"), "this_month"),
    (re.compile(r"지난\s*달|지난\s*월|지난달|지난월"), "last_month"),
    (re.compile(r"올해"), "this_year"),
    (re.compile(r"작년|지난\s*해"), "last_year"),
    (re.compile(r"요즘|최근"), "recent"),
]

# English relative expressions — matched against the original (spaced) text.
_EN_RELATIVE_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"day\s+before\s+yesterday", re.I), "day_before_yesterday"),
    (re.compile(r"\byesterday\b", re.I), "yesterday"),
    (re.compile(r"\btoday\b", re.I), "today"),
    (re.compile(r"this\s+week", re.I), "this_week"),
    (re.compile(r"last\s+week", re.I), "last_week"),
    (re.compile(r"this\s+month", re.I), "this_month"),
    (re.compile(r"last\s+month", re.I), "last_month"),
    (re.compile(r"this\s+year", re.I), "this_year"),
    (re.compile(r"last\s+year", re.I), "last_year"),
    (re.compile(r"\brecently\b|\blately\b|these\s+days", re.I), "recent"),
]

_DAYS_AGO = re.compile(r"(\d+)\s*일\s*전")
_WEEKS_AGO = re.compile(r"(\d+)\s*주\s*전")
_EN_DAYS_AGO = re.compile(r"(\d+)\s*days?\s*ago", re.I)
_EN_WEEKS_AGO = re.compile(r"(\d+)\s*weeks?\s*ago", re.I)
_ISO_DATE = re.compile(r"(?<!\d)(20\d{2})-(\d{1,2})-(\d{1,2})(?!\d)")
_MONTH_DAY = re.compile(r"(?<!\d)(\d{1,2})\s*월\s*(\d{1,2})\s*일(?!\d)")
_MONTH_ONLY = re.compile(r"(?<!\d)(\d{1,2})\s*월(?!\s*\d)(?!\d)")

_EN_MONTHS = {
    "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
    "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
    "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9, "october": 10,
    "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
}
# "July 9", "on Jul 9th", "9 July"
_EN_MONTH_DAY = re.compile(
    r"\b([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b|\b(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]{3,9})\b",
    re.I,
)
# "7/9" (month/day), guarded against years
_EN_SLASH_DATE = re.compile(r"(?<!\d)(\d{1,2})/(\d{1,2})(?!\d)")


def _local_date(dt: datetime, tz: ZoneInfo) -> date:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=ZoneInfo("UTC"))
    return dt.astimezone(tz).date()


def _week_bounds(d: date) -> tuple[date, date]:
    """Monday–Sunday week containing *d*."""
    monday = d - timedelta(days=d.weekday())
    return monday, monday + timedelta(days=6)


def _closest_past_month_day(year: int, month: int, day: int, today: date) -> date:
    try:
        candidate = date(year, month, day)
    except ValueError:
        return date(year, month, min(day, 28))
    if candidate <= today:
        return candidate
    try:
        return date(year - 1, month, day)
    except ValueError:
        return date(year - 1, month, min(day, 28))


def _closest_past_month(year: int, month: int, today: date) -> tuple[date, date]:
    try:
        first = date(year, month, 1)
    except ValueError:
        return today, today
    if month == 12:
        next_first = date(year + 1, 1, 1)
    else:
        next_first = date(year, month + 1, 1)
    last = next_first - timedelta(days=1)
    if last <= today:
        return first, last
    # Month is in the future this year → use last year.
    try:
        first = date(year - 1, month, 1)
        if month == 12:
            next_first = date(year, 1, 1)
        else:
            next_first = date(year - 1, month + 1, 1)
        last = next_first - timedelta(days=1)
        return first, last
    except ValueError:
        return today, today


def _resolve_relative(kind: str, today: date) -> tuple[date, date]:
    if kind == "today":
        return today, today
    if kind == "yesterday":
        d = today - timedelta(days=1)
        return d, d
    if kind == "day_before_yesterday":
        d = today - timedelta(days=2)
        return d, d
    if kind == "this_week":
        return _week_bounds(today)
    if kind == "last_week":
        last_monday = _week_bounds(today)[0] - timedelta(days=7)
        return last_monday, last_monday + timedelta(days=6)
    if kind == "this_month":
        first = today.replace(day=1)
        if today.month == 12:
            next_first = date(today.year + 1, 1, 1)
        else:
            next_first = date(today.year, today.month + 1, 1)
        return first, next_first - timedelta(days=1)
    if kind == "last_month":
        first_this = today.replace(day=1)
        last_prev = first_this - timedelta(days=1)
        first_prev = last_prev.replace(day=1)
        return first_prev, last_prev
    if kind == "this_year":
        return date(today.year, 1, 1), date(today.year, 12, 31)
    if kind == "last_year":
        y = today.year - 1
        return date(y, 1, 1), date(y, 12, 31)
    if kind == "recent":
        return today - timedelta(days=6), today
    return today, today


def parse_time_window(
    text: str, tz: ZoneInfo, now: datetime
) -> tuple[date, date] | None:
    """Return a closed [start, end] date window in *tz*, or None if no cue."""
    if not text or not text.strip():
        return None
    today = _local_date(now, tz)
    normalized = text.replace(" ", "")

    for pat, kind in _RELATIVE_PATTERNS:
        if pat.search(normalized):
            return _resolve_relative(kind, today)

    m = _DAYS_AGO.search(normalized)
    if m:
        n = int(m.group(1))
        d = today - timedelta(days=n)
        return d, d

    m = _WEEKS_AGO.search(normalized)
    if m:
        n = int(m.group(1))
        anchor = today - timedelta(weeks=n)
        return _week_bounds(anchor)

    m = _ISO_DATE.search(text)
    if m:
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        try:
            single = date(y, mo, d)
            return single, single
        except ValueError:
            pass

    m = _MONTH_DAY.search(text)
    if m:
        mo, d = int(m.group(1)), int(m.group(2))
        single = _closest_past_month_day(today.year, mo, d, today)
        return single, single

    m = _MONTH_ONLY.search(text)
    if m:
        mo = int(m.group(1))
        return _closest_past_month(today.year, mo, today)

    # ── English cues (matched on the original, spaced text) ──────────────────
    for pat, kind in _EN_RELATIVE_PATTERNS:
        if pat.search(text):
            return _resolve_relative(kind, today)

    m = _EN_DAYS_AGO.search(text)
    if m:
        d = today - timedelta(days=int(m.group(1)))
        return d, d

    m = _EN_WEEKS_AGO.search(text)
    if m:
        return _week_bounds(today - timedelta(weeks=int(m.group(1))))

    m = _EN_MONTH_DAY.search(text)
    if m:
        name = (m.group(1) or m.group(4) or "").lower()
        day_str = m.group(2) or m.group(3)
        if name in _EN_MONTHS and day_str:
            single = _closest_past_month_day(
                today.year, _EN_MONTHS[name], int(day_str), today
            )
            return single, single

    m = _EN_SLASH_DATE.search(text)
    if m:
        mo, d = int(m.group(1)), int(m.group(2))
        if 1 <= mo <= 12 and 1 <= d <= 31:
            single = _closest_past_month_day(today.year, mo, d, today)
            return single, single

    return None


def format_time_window_label(
    start: date,
    end: date,
    text: str,
    tz: ZoneInfo,
    now: datetime,
) -> str:
    """Human-readable period header for the chat context block."""
    today = _local_date(now, tz)
    normalized = text.replace(" ", "")

    tag = ""
    if start == end == today and re.search(r"오늘", normalized):
        tag = " (오늘)"
    elif start == end == today - timedelta(days=1) and re.search(r"어제", normalized):
        tag = " (어제)"
    elif start == end == today - timedelta(days=2) and re.search(
        r"그저께|엊그제|그제", normalized
    ):
        tag = " (그저께)"
    elif _week_bounds(today) == (start, end) and re.search(r"이번\s*주", normalized):
        tag = " (이번 주)"
    elif re.search(r"지난\s*주|저번\s*주|지난주|저번주", normalized):
        tag = " (지난주)"
    elif re.search(r"요즘|최근", normalized):
        tag = " (최근 7일)"

    if start == end:
        return f"요청 기간: {start.isoformat()}{tag}"
    return f"요청 기간: {start.isoformat()} ~ {end.isoformat()}{tag}"

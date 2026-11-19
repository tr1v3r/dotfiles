"""Theme-driven capsules; keep Kitty's title formatting and per-tab hit testing."""

import re

from kitty.fast_data_types import Screen, wcswidth
from kitty.tab_bar import (
    DrawData,
    ExtraData,
    TabBarData,
    apply_title_template,
    as_rgb,
    draw_attributed_string,
    truncate_line,
)

_SGR = re.compile(r"\x1b\[[0-9:;]*m")


def draw_tab(
    draw_data: DrawData,
    screen: Screen,
    tab: TabBarData,
    before: int,
    max_tab_length: int,
    index: int,
    is_last: bool,
    extra_data: ExtraData,
) -> int:
    # Reserve both rounded caps, inner padding, and a one-cell inter-tab gap.
    available = min(max_tab_length, screen.columns - before)
    if available <= 0:
        return before
    fg, bg = screen.cursor.fg, screen.cursor.bg
    canvas = as_rgb(int(draw_data.default_bg))
    overhead = 4 + int(not is_last)
    if available <= overhead:
        screen.draw("…")
        return screen.cursor.x

    budget = available - overhead
    title = apply_title_template(draw_data, tab, index, budget).split("\n", 1)[0]
    if wcswidth(_SGR.sub("", title)) > budget:
        title = truncate_line(title, budget)

    screen.cursor.fg, screen.cursor.bg = bg, canvas
    screen.draw("")
    screen.cursor.fg, screen.cursor.bg = fg, bg
    screen.draw(" ")
    draw_attributed_string(title, screen)
    screen.cursor.fg, screen.cursor.bg = fg, bg
    screen.draw(" ")
    screen.cursor.fg, screen.cursor.bg = bg, canvas
    screen.draw("")
    end = screen.cursor.x
    screen.cursor.fg = screen.cursor.bg = 0
    screen.cursor.bold = screen.cursor.italic = False
    if not is_last:
        screen.draw(" ")
    # Exclude the gap from the tab's clickable region; no buffering across tabs.
    return end

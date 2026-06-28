#!/usr/bin/env python3
"""
Generate a ready-to-use book-cover PNG (1200x1800) from an approved typographic
SVG template, substituting AUTHOR and TITLE — no generative AI, no network.

Why this exists
---------------
When no cover is found online (see fb2-to-epub-cover-finder.py), fb2-to-epub
falls back to a typographic cover built from one of 4 approved templates in
design/cover-templates/. SVG text does NOT wrap on its own, so this script
measures each string with PIL (real font + size) and applies the README fit
rules: shrink the type and/or wrap to 2-3 lines so the title never overflows the
safe area and is never clipped.

How substitution works
-----------------------
We do NOT string-replace inside a fixed <text> element (that can't change size,
line count or y). Instead each text zone in the *.tok.svg templates is wrapped
in marker comments carrying layout metadata, e.g.

    <!--BLOCK:TITLE cx=600 cy=830 base=166 min=82 fill=#1A1A1A
        font-family=... pil=/path/Font.ttf idx=0 safe=960 leading=1.16-->
    <text ...>__TITLE__</text>
    <!--/BLOCK:TITLE-->

The script reads the metadata, builds a fresh <text>/<g> block (correct size,
N lines, y-coords, letter-spacing) and replaces everything between the markers.
The original <text> inside is only a human-readable preview of the default.

Fonts: only cairosvg-safe Cyrillic fonts are used (see .patches/012). The PIL
font file in each block's `pil=` must match the family cairosvg resolves, so the
width we measure matches the width cairosvg paints (calibrated: PIL width is a
slightly conservative upper bound of cairosvg ink width — safe for fitting).

CLI
---
    fb2-to-epub-cover-gen.py --author "<author>" --title "<title>"
                             --template <1|2|3|4|all> --out <dir>
                             [--label <ROMAN>] [--templates-dir <dir>]

Writes cover-tmpl<N>.png (1200x1800) for each requested template into --out.

Dependencies: cairosvg, pillow. macOS system fonts.
"""

from __future__ import annotations

import argparse
import html
import os
import re
import sys

try:
    import cairosvg
except Exception as exc:  # pragma: no cover - environment guard
    sys.stderr.write(
        "ERROR: cairosvg is required (pip install cairosvg). %s\n" % exc
    )
    raise

try:
    from PIL import ImageFont
except Exception as exc:  # pragma: no cover - environment guard
    sys.stderr.write(
        "ERROR: Pillow is required (pip install pillow). %s\n" % exc
    )
    raise


CANVAS_W = 1200
CANVAS_H = 1800

# Repo root is the parent of bin/; tokenized templates live under
# design/cover-templates/tokenized/ by default.
_THIS = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(_THIS)
DEFAULT_TEMPLATES_DIR = os.path.join(
    _REPO, "design", "cover-templates", "tokenized"
)

TEMPLATE_FILES = {
    "1": "tmpl-1-minimal.tok.svg",
    "2": "tmpl-2-classic.tok.svg",
    "3": "tmpl-3-modern.tok.svg",
    "4": "tmpl-4-dark.tok.svg",
}

# Per-template footer/label defaults (kept identical to the approved SVGs).
LABEL_DEFAULTS = {"1": "РОМАН", "2": "КЛАССИКА", "3": "РОМАН", "4": "РОМАН"}
# Template 2 has a separate decorative bottom signature.
FOOTER_DEFAULTS = {"2": "КЛАССИКА"}


# --------------------------------------------------------------------------- #
# Block-metadata parsing
# --------------------------------------------------------------------------- #
def _parse_meta(meta_text: str) -> dict:
    """Parse `key=value` tokens from a BLOCK marker.

    Values may contain spaces/commas (e.g. font-family, font paths), so we split
    on the *next* ` key=` boundary rather than on whitespace. Keys are
    [a-z_][a-z0-9_-]*.
    """
    meta_text = " ".join(meta_text.split())  # collapse newlines/space
    out: dict = {}
    # find all key= positions
    keys = list(re.finditer(r"([A-Za-z_][A-Za-z0-9_\-]*)=", meta_text))
    for i, m in enumerate(keys):
        key = m.group(1)
        start = m.end()
        end = keys[i + 1].start() if i + 1 < len(keys) else len(meta_text)
        val = meta_text[start:end].strip()
        out[key] = val
    return out


def _num(meta: dict, key: str, default: float | None = None) -> float:
    if key not in meta:
        if default is None:
            raise KeyError("missing numeric meta key: %s" % key)
        return float(default)
    return float(meta[key])


# --------------------------------------------------------------------------- #
# Text measurement (PIL) + cairosvg-style letter-spacing
# --------------------------------------------------------------------------- #
_FONT_CACHE: dict = {}


def _load_font(path: str, size: int, idx: int) -> ImageFont.FreeTypeFont:
    key = (path, size, idx)
    f = _FONT_CACHE.get(key)
    if f is None:
        f = ImageFont.truetype(path, size, index=idx)
        _FONT_CACHE[key] = f
    return f


def text_width(s: str, path: str, size: int, idx: int, ls: float = 0.0) -> float:
    """Width of `s` at `size` including SVG letter-spacing.

    SVG/cairosvg add `letter-spacing` after every glyph except the last one,
    matching PIL advance + ls*(len-1). Spaces count as glyphs. PIL has no
    letter-spacing, so we add it explicitly. Calibrated against cairosvg ink
    width: this is a slightly conservative upper bound (safe for fitting).
    """
    if not s:
        return 0.0
    f = _load_font(path, size, idx)
    base = f.getlength(s)
    return base + ls * (len(s) - 1)


def _esc(s: str) -> str:
    """XML-escape text for safe embedding in SVG."""
    return html.escape(s, quote=True)


# --------------------------------------------------------------------------- #
# Word wrapping by width
# --------------------------------------------------------------------------- #
def wrap_to_lines(
    words: list[str],
    max_lines: int,
    safe: float,
    path: str,
    size: int,
    idx: int,
    ls: float = 0.0,
) -> list[str] | None:
    """Greedy word-wrap into <= max_lines so every line width <= safe.

    Returns the lines, or None if it doesn't fit (caller then shrinks size).
    A single word longer than `safe` makes this fail (caller shrinks further).
    """
    lines: list[str] = []
    cur = ""
    for w in words:
        trial = w if not cur else (cur + " " + w)
        if text_width(trial, path, size, idx, ls) <= safe:
            cur = trial
        else:
            if cur:
                lines.append(cur)
            cur = w
            # a lone word wider than safe -> fail, shrink size
            if text_width(cur, path, size, idx, ls) > safe:
                return None
            if len(lines) >= max_lines:
                return None
    if cur:
        lines.append(cur)
    if len(lines) > max_lines:
        return None
    return lines or [""]


# --------------------------------------------------------------------------- #
# Centered title block (templates 1, 2, 4)
# --------------------------------------------------------------------------- #
def build_centered_title(text: str, meta: dict) -> str:
    """Centered title that HANGS on a fixed last-line baseline and grows UPWARD.

    The last line's baseline is `baseline` (= the approved single-line position,
    so the decorative accent line under it stays attached in every case). Extra
    wrapped lines stack above. We pick the largest size whose width fits `safe`
    AND whose top line stays below the `ceil` ceiling, so the block never
    collides with the label/divider above or the accent/author below.
    """
    cx = _num(meta, "cx")
    baseline = _num(meta, "baseline")
    ceil = _num(meta, "ceil")
    base = int(_num(meta, "base"))
    floor = int(_num(meta, "min"))
    safe = _num(meta, "safe")
    fill = meta.get("fill", "#000000")
    family = meta["font-family"]
    pil = meta["pil"]
    idx = int(_num(meta, "idx", 0))
    leading = _num(meta, "leading", 1.16)
    style = meta.get("style", "")  # "italic" or ""
    words = text.split()

    def fits_vertically(n_lines: int, size: int) -> bool:
        # cap-height of the top line above its baseline ~ 0.72*size
        step = size * leading
        top_baseline = baseline - step * (n_lines - 1)
        top_edge = top_baseline - size * 0.72
        return top_edge >= ceil

    chosen_size = floor
    chosen_lines = [text]
    # Largest size (base->floor) with fewest lines (1..3) fitting width+height.
    found = False
    for size in range(base, floor - 1, -2):
        best = None
        for max_lines in (1, 2, 3):
            lines = wrap_to_lines(words, max_lines, safe, pil, size, idx, 0.0)
            if lines is not None and fits_vertically(len(lines), size):
                best = lines
                break
        if best is not None:
            chosen_size = size
            chosen_lines = best
            found = True
            break
    if not found:
        # best effort at floor: wrap into up to 3 lines, never clip
        lines = wrap_to_lines(words, 3, safe, pil, floor, idx, 0.0)
        if lines is None:
            lines = words[:3] if len(words) > 3 else words
        chosen_size = floor
        chosen_lines = lines

    step = chosen_size * leading
    n = len(chosen_lines)
    first_baseline = baseline - step * (n - 1)
    style_attr = ' font-style="italic"' if style == "italic" else ""
    tspans = []
    for i, line in enumerate(chosen_lines):
        y = first_baseline + i * step
        tspans.append(
            '<text x="%g" y="%g" text-anchor="middle" '
            'font-family="%s" font-size="%d"%s fill="%s">%s</text>'
            % (cx, y, family, chosen_size, style_attr, fill, _esc(line))
        )
    return "\n  ".join(tspans)


# --------------------------------------------------------------------------- #
# Single-line author with letter-spacing fallback (templates 1, 2, 4)
# --------------------------------------------------------------------------- #
def build_author(text: str, meta: dict) -> str:
    cx = _num(meta, "cx")
    y = _num(meta, "y")
    base = int(_num(meta, "base"))
    floor = int(_num(meta, "min"))
    ls = _num(meta, "ls", 0)
    lsmin = _num(meta, "lsmin", 0)
    safe = _num(meta, "safe")
    fill = meta.get("fill", "#000000")
    family = meta["font-family"]
    pil = meta["pil"]
    idx = int(_num(meta, "idx", 0))
    upper = meta.get("upper", "0") == "1"
    leading = _num(meta, "leading", 1.12)
    s = text.upper() if upper else text

    # 1) try base size, shrinking letter-spacing from ls down to lsmin
    for cur_ls in _frange(ls, lsmin, -1):
        if text_width(s, pil, base, idx, cur_ls) <= safe:
            return _author_line(s, cx, y, base, cur_ls, family, fill)
    # 2) shrink size (at lsmin) down to floor
    for size in range(base, floor - 1, -2):
        if text_width(s, pil, size, idx, lsmin) <= safe:
            return _author_line(s, cx, y, size, lsmin, family, fill)
    # 3) two lines at floor (split into two roughly-equal halves by words)
    words = s.split()
    if len(words) >= 2:
        lines = _split_two(words, pil, floor, idx, lsmin, safe)
        step = floor * leading
        y0 = y - step / 2
        out = []
        for i, ln in enumerate(lines):
            out.append(_author_line(ln, cx, y0 + i * step, floor, lsmin, family, fill))
        return "\n  ".join(out)
    # 4) single very-long token: emit at floor, lsmin (best effort, no clip)
    return _author_line(s, cx, y, floor, lsmin, family, fill)


def _author_line(s, cx, y, size, ls, family, fill):
    ls_attr = (' letter-spacing="%g"' % ls) if ls else ""
    return (
        '<text x="%g" y="%g" text-anchor="middle" font-family="%s" '
        'font-size="%d"%s fill="%s">%s</text>'
        % (cx, y, family, size, ls_attr, fill, _esc(s))
    )


def _split_two(words, pil, size, idx, ls, safe):
    """Split words into two lines, balancing widths."""
    best = None
    best_diff = None
    for cut in range(1, len(words)):
        a = " ".join(words[:cut])
        b = " ".join(words[cut:])
        wa = text_width(a, pil, size, idx, ls)
        wb = text_width(b, pil, size, idx, ls)
        diff = abs(wa - wb) + max(0, wa - safe) * 10 + max(0, wb - safe) * 10
        if best_diff is None or diff < best_diff:
            best_diff = diff
            best = [a, b]
    return best


def _frange(start, stop, step):
    """Inclusive float range stepping by `step` (step<0 for descending)."""
    vals = []
    v = start
    if step < 0:
        while v >= stop - 1e-9:
            vals.append(round(v, 3))
            v += step
    else:
        while v <= stop + 1e-9:
            vals.append(round(v, 3))
            v += step
    return vals


# --------------------------------------------------------------------------- #
# Modern stacked title (template 3)
# --------------------------------------------------------------------------- #
def build_title_stack(text: str, meta: dict) -> str:
    """Modern UPPERCASE stack, left-anchored, kept clear of the SLANTED diagonal.

    The divider is a line y = diag_b - diag_k*x. The lowest title line must stay
    above it: at the line's right-edge x we require
        baseline_bottom <= diag_y(x_right) - clear.
    We pick the largest size whose words wrap to `safe` width and whose lowest
    line clears the diagonal. The last line is accent-coloured only if it clears
    the diagonal (i.e. still on the light zone), else graphite (contrast safety).
    """
    x = _num(meta, "x")
    ytop = _num(meta, "ytop")
    diag_b = _num(meta, "diag_b")
    diag_k = _num(meta, "diag_k")
    clear = _num(meta, "clear", 60)
    base = int(_num(meta, "base"))
    floor = int(_num(meta, "min"))
    ls = _num(meta, "ls", 0)
    safe = _num(meta, "safe")
    fill = meta.get("fill", "#1D1D1D")
    accent = meta.get("accent", fill)
    family = meta["font-family"]
    pil = meta["pil"]
    idx = int(_num(meta, "idx", 0))
    leading = _num(meta, "leading", 0.95)
    s = text.upper()
    words = s.split()

    def diag_y(xx: float) -> float:
        return diag_b - diag_k * xx

    def stack_clears(lines: list[str], size: int) -> bool:
        step = size * leading
        # bottom of caps sits ~0.04*size below baseline (minimal for uppercase)
        for i, line in enumerate(lines):
            baseline = ytop + i * step
            bottom = baseline + size * 0.04
            w = text_width(line, pil, size, idx, ls)
            x_right = x + w
            if bottom > diag_y(x_right) - clear:
                return False
        return True

    chosen_size = floor
    chosen_lines = [s]
    found = False
    for size in range(base, floor - 1, -2):
        # cap line count generously; clearance is the real constraint
        for max_lines in (1, 2, 3, 4):
            lines = wrap_to_lines(words, max_lines, safe, pil, size, idx, ls)
            if lines is None:
                continue
            if stack_clears(lines, size):
                chosen_size = size
                chosen_lines = lines
                found = True
                break
        if found:
            break
    if not found:
        # best effort at floor: wrap to fit width, accept gentle proximity
        lines = wrap_to_lines(words, 4, safe, pil, floor, idx, ls)
        if lines is None:
            lines = words
        chosen_size = floor
        chosen_lines = lines

    step = chosen_size * leading
    n = len(chosen_lines)
    ls_attr = (' letter-spacing="%g"' % ls) if ls else ""
    out = []
    for i, line in enumerate(chosen_lines):
        y = ytop + i * step
        # accent the last line ONLY if it clears the diagonal (stays on light bg)
        on_light = (
            y + chosen_size * 0.04
            <= diag_y(x + text_width(line, pil, chosen_size, idx, ls)) - clear
        )
        col = accent if (i == n - 1 and on_light) else fill
        out.append(
            '<text x="%g" y="%g" font-family="%s" font-weight="bold" '
            'font-size="%d"%s fill="%s">%s</text>'
            % (x, y, family, chosen_size, ls_attr, col, _esc(line))
        )
    return "\n    ".join(out)


# --------------------------------------------------------------------------- #
# Modern author plate (template 3) — plate width = text width + 2*pad
# --------------------------------------------------------------------------- #
def build_author_plate(text: str, meta: dict) -> str:
    px = _num(meta, "px")
    py = _num(meta, "py")
    ph = _num(meta, "ph")
    pad = _num(meta, "pad")
    base = int(_num(meta, "base"))
    floor = int(_num(meta, "min"))
    ls = _num(meta, "ls", 0)
    safemax = _num(meta, "safemax")
    platefill = meta.get("platefill", "#FFFFFF")
    textfill = meta.get("textfill", "#000000")
    family = meta["font-family"]
    pil = meta["pil"]
    idx = int(_num(meta, "idx", 0))
    upper = meta.get("upper", "0") == "1"
    s = text.upper() if upper else text

    # shrink size until plate (text + 2*pad) fits within safemax
    size = base
    for sz in range(base, floor - 1, -2):
        w = text_width(s, pil, sz, idx, ls)
        if w + 2 * pad <= safemax:
            size = sz
            break
    else:
        size = floor

    tw = text_width(s, pil, size, idx, ls)
    plate_w = tw + 2 * pad
    text_x = px + pad
    # baseline roughly vertically centered in the plate
    baseline = py + ph / 2 + size * 0.34
    ls_attr = (' letter-spacing="%g"' % ls) if ls else ""
    return (
        '<rect x="%g" y="%g" width="%g" height="%g" fill="%s"/>\n    '
        '<text x="%g" y="%g" font-family="%s" font-weight="bold" '
        'font-size="%d"%s fill="%s">%s</text>'
        % (
            px, py, plate_w, ph, platefill,
            text_x, baseline, family, size, ls_attr, textfill, _esc(s),
        )
    )


# --------------------------------------------------------------------------- #
# Template assembly: find BLOCK markers, replace their bodies
# --------------------------------------------------------------------------- #
_BLOCK_RE = re.compile(
    r"<!--BLOCK:(?P<kind>[A-Z_]+)(?P<meta>.*?)-->"
    r"(?P<body>.*?)"
    r"<!--/BLOCK:(?P=kind)-->",
    re.DOTALL,
)


def fill_template(svg: str, author: str, title: str, label: str | None,
                  footer: str | None) -> str:
    def repl(m: re.Match) -> str:
        kind = m.group("kind")
        meta = _parse_meta(m.group("meta"))
        if kind == "TITLE":
            return build_centered_title(title, meta)
        if kind == "AUTHOR":
            return build_author(author, meta)
        if kind == "TITLE_STACK":
            return build_title_stack(title, meta)
        if kind == "AUTHOR_PLATE":
            return build_author_plate(author, meta)
        # unknown block: leave untouched
        return m.group(0)

    svg = _BLOCK_RE.sub(repl, svg)

    # Simple non-fitted placeholders (short, fixed-size labels/footers).
    svg = svg.replace("__LABEL__", _esc(label) if label is not None else "")
    svg = svg.replace("__FOOTER__", _esc(footer) if footer is not None else "")
    # Any leftover preview placeholders (none should remain inside blocks).
    svg = svg.replace("__TITLE_LINE__", "").replace("__TITLE__", _esc(title))
    svg = svg.replace("__AUTHOR__", _esc(author))
    return svg


# --------------------------------------------------------------------------- #
# Render
# --------------------------------------------------------------------------- #
def render_png(svg: str, out_path: str) -> None:
    cairosvg.svg2png(
        bytestring=svg.encode("utf-8"),
        write_to=out_path,
        output_width=CANVAS_W,
        output_height=CANVAS_H,
    )


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Generate a typographic book-cover PNG from an SVG template."
    )
    ap.add_argument("--author", required=True, help="Author name")
    ap.add_argument("--title", required=True, help="Book title")
    ap.add_argument(
        "--template", required=True,
        help="Template id: 1, 2, 3, 4, or 'all'",
    )
    ap.add_argument("--out", required=True, help="Output directory")
    ap.add_argument(
        "--label", default=None,
        help="Top label text (default per-template, e.g. РОМАН)",
    )
    ap.add_argument(
        "--templates-dir", default=DEFAULT_TEMPLATES_DIR,
        help="Directory with *.tok.svg templates",
    )
    args = ap.parse_args(argv)

    sel = args.template.strip().lower()
    if sel == "all":
        ids = ["1", "2", "3", "4"]
    else:
        ids = [t.strip() for t in sel.split(",")]
    for t in ids:
        if t not in TEMPLATE_FILES:
            ap.error("unknown template id: %r (use 1|2|3|4|all)" % t)

    os.makedirs(args.out, exist_ok=True)
    written = []
    for t in ids:
        tpl_path = os.path.join(args.templates_dir, TEMPLATE_FILES[t])
        with open(tpl_path, "r", encoding="utf-8") as fh:
            svg = fh.read()
        label = args.label if args.label is not None else LABEL_DEFAULTS.get(t)
        footer = FOOTER_DEFAULTS.get(t)
        filled = fill_template(svg, args.author, args.title, label, footer)
        out_path = os.path.join(args.out, "cover-tmpl%s.png" % t)
        render_png(filled, out_path)
        written.append(out_path)
        print(out_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

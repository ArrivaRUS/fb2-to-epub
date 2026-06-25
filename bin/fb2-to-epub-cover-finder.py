#!/usr/bin/env python3
"""
For an FB2/FB2.ZIP source without an embedded cover, search the internet for a
book cover by title + author.

Two modes:

  LEGACY (single best image):
      cover-finder.py <src> <dst>
    Downloads the single best usable image to <dst> and prints its path.
    Behaviour is unchanged from before --json existed; the watcher still uses
    this path for the 0/1-candidate branches.

  JSON (top-N candidates + previews, for the cover-selection queue):
      cover-finder.py --json --book-id <id> --previews-dir <dir> <src>
    Searches the same sources, keeps the top-N usable candidates (N<=4),
    downloads each preview to <previews-dir>/<book-id>/<rank>.jpg, scores them,
    and prints ONE JSON object to stdout:
      {book_id, title, author,
       candidates:[{id,rank,source,url,preview_path,score}],
       best_candidate_id}
    The watcher owns App Support paths and the final epub path, so it computes
    book_id and passes previews-dir in; this file never hard-codes App Support.

Sources, tried in order (results merged then tried one by one):
  1. Open Library      -- catalog API; fast and stable, narrow Russian coverage
  2. DuckDuckGo Images -- broad search; biased toward book sites for RU queries

A candidate is accepted only if the downloaded image looks like a book cover:
roughly portrait (1.0 <= height/width <= 2.5) and at least 200 px wide. This
rejects author photos, random thumbnails, square logos, and broken images.

If no source yields a usable image, exits with status 1 so the watcher converts
the EPUB without a cover (suppressing Calibre's default placeholder). In --json
mode the same status-1 exit means "no candidates" (nothing printed).

Exit codes:
  0 -- legacy: cover downloaded, path printed | json: candidates printed
  3 -- source already has an embedded cover; no action needed
  1 -- no cover found anywhere (or error)
  2 -- bad arguments
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

EBOOK_META = "/Applications/calibre.app/Contents/MacOS/ebook-meta"
TIMEOUT_SEARCH = 8
TIMEOUT_DOWNLOAD = 8
UA = "fb2-to-epub-watcher/1.0"
MIN_BYTES = 5 * 1024
MAX_BYTES = 10 * 1024 * 1024
MIN_WIDTH = 200
MAX_CANDIDATES = 10        # how many merged URLs we attempt to download
MAX_JSON_CANDIDATES = 4    # how many downloaded previews we keep for the queue


def log(msg: str) -> None:
    print(f"[cover-finder] {msg}", file=sys.stderr)


def http_get(url: str, headers: dict | None = None, timeout: int = 10) -> bytes:
    h = {"User-Agent": UA}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(MAX_BYTES + 1)


def image_dims(data: bytes):
    """Return (width, height) for JPEG or PNG bytes, or None."""
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        return (
            int.from_bytes(data[16:20], "big"),
            int.from_bytes(data[20:24], "big"),
        )
    if data[:3] == b"\xff\xd8\xff":
        i = 2
        while i < len(data) - 9:
            if data[i] != 0xff:
                i += 1
                continue
            m = data[i + 1]
            if 0xc0 <= m <= 0xcf and m not in (0xc4, 0xc8, 0xcc):
                h = int.from_bytes(data[i + 5 : i + 7], "big")
                w = int.from_bytes(data[i + 7 : i + 9], "big")
                return w, h
            seg = int.from_bytes(data[i + 2 : i + 4], "big")
            i += 2 + seg
    return None


def looks_like_cover(w: int, h: int) -> bool:
    if not w or not h or w < MIN_WIDTH:
        return False
    ar = h / w
    return 1.0 <= ar <= 2.5


def score_cover(w: int, h: int, source: str) -> float:
    """Deterministic 0..1 quality score for ranking candidates.

    Three transparent components, weighted:
      - resolution (0.5): wider is better, saturating at ~1000 px so a giant
        scan and a 1000 px cover score the same (both plenty for an e-reader).
      - aspect    (0.35): closeness to the canonical book ratio ~1.5 (h/w);
        full credit in the 1.4-1.6 band, linearly fading to the 1.0/2.5 edges.
      - source    (0.15): catalog hits (Open Library) match title+author by ID,
        so they are more trustworthy than image-search hits.
    Returns 0.0 for anything that fails the cover gate.
    """
    if not looks_like_cover(w, h):
        return 0.0

    res = min(w, 1000) / 1000.0

    ar = h / w
    ideal = 1.5
    if 1.4 <= ar <= 1.6:
        aspect = 1.0
    elif ar < ideal:
        aspect = max(0.0, (ar - 1.0) / (1.4 - 1.0))   # 1.0->0 .. 1.4->1
    else:
        aspect = max(0.0, (2.5 - ar) / (2.5 - 1.6))   # 1.6->1 .. 2.5->0

    src_bonus = 1.0 if source == "open_library" else 0.6

    return round(0.5 * res + 0.35 * aspect + 0.15 * src_bonus, 4)


def has_embedded_cover(src: str) -> bool:
    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, "cover.jpg")
        try:
            subprocess.run(
                [EBOOK_META, src, f"--get-cover={out}"],
                capture_output=True, text=True, timeout=30,
            )
        except Exception:
            return False
        return os.path.exists(out) and os.path.getsize(out) > MIN_BYTES


def get_meta(src: str):
    try:
        r = subprocess.run([EBOOK_META, src], capture_output=True, text=True, timeout=30)
    except Exception:
        return None, None
    title, author = None, None
    for line in r.stdout.splitlines():
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        key, val = key.strip(), val.strip()
        if key == "Title" and not title:
            title = val
        elif key.startswith("Author") and not author:
            first = val.split("&")[0].strip()
            first = re.sub(r"\s*\[.*?\]\s*", "", first)
            if "," in first:
                last, _, given = first.partition(",")
                first = f"{given.strip()} {last.strip()}".strip()
            author = first or None
    return title, author


def search_open_library(title: str, author: str | None):
    params = {"limit": "5"}
    if title:
        params["title"] = title
    if author:
        params["author"] = author
    url = "https://openlibrary.org/search.json?" + urllib.parse.urlencode(params)
    try:
        data = json.loads(http_get(url, timeout=TIMEOUT_SEARCH).decode("utf-8"))
    except Exception as e:
        log(f"open-library err: {e}")
        return []
    out = []
    for doc in data.get("docs", []):
        cid = doc.get("cover_i")
        if cid:
            out.append((f"https://covers.openlibrary.org/b/id/{cid}-L.jpg", "open_library"))
    log(f"open-library: {len(out)} candidates")
    return out


def search_duckduckgo(title: str, author: str | None):
    parts = [f'"{title}"']
    if author:
        parts.append(author)
    parts.append("обложка книги")
    query = " ".join(parts)
    try:
        html = http_get(
            "https://duckduckgo.com/?q=" + urllib.parse.quote(query),
            timeout=TIMEOUT_SEARCH,
        ).decode("utf-8", "ignore")
    except Exception as e:
        log(f"ddg vqd err: {e}")
        return []
    m = re.search(r"vqd=['\"]?(\d-[\d-]+)['\"]?", html)
    if not m:
        log("ddg: no vqd token in response")
        return []
    vqd = m.group(1)
    api = (
        "https://duckduckgo.com/i.js?l=us-en&o=json&p=1"
        f"&q={urllib.parse.quote(query)}&vqd={vqd}"
    )
    try:
        data = json.loads(
            http_get(
                api,
                headers={
                    "Referer": "https://duckduckgo.com/",
                    "X-Requested-With": "XMLHttpRequest",
                },
                timeout=TIMEOUT_SEARCH,
            ).decode("utf-8")
        )
    except Exception as e:
        log(f"ddg api err: {e}")
        return []
    out = []
    for r in (data.get("results") or [])[:15]:
        u = r.get("image")
        w = int(r.get("width") or 0)
        h = int(r.get("height") or 0)
        if u and looks_like_cover(w, h):
            out.append((u, "duckduckgo"))
    log(f"ddg: {len(out)} candidates")
    return out


def try_download(url: str, dst: str) -> bool:
    try:
        data = http_get(url, timeout=TIMEOUT_DOWNLOAD)
    except Exception:
        return False
    if len(data) < MIN_BYTES or len(data) > MAX_BYTES:
        return False
    dims = image_dims(data[:8192]) or image_dims(data)
    if dims:
        w, h = dims
        if not looks_like_cover(w, h):
            return False
    try:
        with open(dst, "wb") as f:
            f.write(data)
    except Exception:
        return False
    return True


def download_preview(url: str, dst: str):
    """Download a candidate to dst and return its (w, h), or None if unusable.

    Same gates as try_download (size, dims, cover-shape) but reports the
    measured dimensions so the caller can score the preview.
    """
    try:
        data = http_get(url, timeout=TIMEOUT_DOWNLOAD)
    except Exception:
        return None
    if len(data) < MIN_BYTES or len(data) > MAX_BYTES:
        return None
    dims = image_dims(data[:8192]) or image_dims(data)
    if not dims:
        return None
    w, h = dims
    if not looks_like_cover(w, h):
        return None
    try:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as f:
            f.write(data)
    except Exception:
        return None
    return w, h


def run_json(src: str, book_id: str, previews_dir: str) -> None:
    """--json mode: build top-N candidates with local previews + scores."""
    if has_embedded_cover(src):
        sys.exit(3)
    title, author = get_meta(src)
    if not title:
        log("no title in metadata; giving up")
        sys.exit(1)
    log(f"[json] searching for: {title!r} / {author!r}")

    seen = set()
    merged: list[tuple[str, str]] = []   # (url, source)
    for src_fn in (search_open_library, search_duckduckgo):
        try:
            for u, source in src_fn(title, author):
                if u not in seen and len(merged) < MAX_CANDIDATES:
                    seen.add(u)
                    merged.append((u, source))
        except Exception as e:
            log(f"{src_fn.__name__} crashed: {e}")

    book_dir = os.path.join(previews_dir, book_id)
    candidates = []
    rank = 0
    for url, source in merged:
        if len(candidates) >= MAX_JSON_CANDIDATES:
            break
        rank += 1
        preview_path = os.path.join(book_dir, f"{rank}.jpg")
        dims = download_preview(url, preview_path)
        if not dims:
            rank -= 1   # this slot did not produce a usable preview
            continue
        w, h = dims
        candidates.append({
            "id": f"{book_id}-{rank}",
            "rank": rank,
            "source": source,
            "url": url,
            "preview_path": preview_path,
            "score": score_cover(w, h, source),
        })
        log(f"[json] candidate #{rank} {source} score={candidates[-1]['score']} {url[:80]}")

    if not candidates:
        log("[json] no usable candidates")
        sys.exit(1)

    candidates.sort(key=lambda c: c["score"], reverse=True)
    best = candidates[0]["id"]

    out = {
        "book_id": book_id,
        "title": title,
        "author": author,
        "candidates": candidates,
        "best_candidate_id": best,
    }
    print(json.dumps(out, ensure_ascii=False))
    sys.exit(0)


def parse_json_args(argv: list[str]):
    """Parse the --json invocation; returns (src, book_id, previews_dir).

    Expected: --json --book-id <id> --previews-dir <dir> <src>
    (flags may appear in any order; exactly one positional <src>.)
    """
    book_id = previews_dir = None
    positionals = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--json":
            i += 1
        elif a == "--book-id":
            book_id = argv[i + 1] if i + 1 < len(argv) else None
            i += 2
        elif a == "--previews-dir":
            previews_dir = argv[i + 1] if i + 1 < len(argv) else None
            i += 2
        else:
            positionals.append(a)
            i += 1
    if not book_id or not previews_dir or len(positionals) != 1:
        sys.exit(2)
    return positionals[0], book_id, previews_dir


def main() -> None:
    args = sys.argv[1:]

    if "--json" in args:
        src, book_id, previews_dir = parse_json_args(args)
        if not os.path.isfile(src):
            sys.exit(1)
        run_json(src, book_id, previews_dir)
        return

    # --- LEGACY single-best mode (unchanged contract) ---
    if len(args) != 2:
        sys.exit(2)
    src, dst = args[0], args[1]
    if not os.path.isfile(src):
        sys.exit(1)
    if has_embedded_cover(src):
        sys.exit(3)
    title, author = get_meta(src)
    if not title:
        log("no title in metadata; giving up")
        sys.exit(1)
    log(f"searching for: {title!r} / {author!r}")

    seen = set()
    candidates: list[str] = []
    for src_fn in (search_open_library, search_duckduckgo):
        try:
            for u, _source in src_fn(title, author):
                if u not in seen and len(candidates) < MAX_CANDIDATES:
                    seen.add(u)
                    candidates.append(u)
        except Exception as e:
            log(f"{src_fn.__name__} crashed: {e}")

    for i, url in enumerate(candidates, 1):
        if try_download(url, dst):
            log(f"hit #{i}: {url[:100]}")
            print(dst)
            sys.exit(0)

    log(f"no usable cover from {len(candidates)} candidates")
    sys.exit(1)


if __name__ == "__main__":
    main()

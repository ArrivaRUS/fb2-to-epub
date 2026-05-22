#!/usr/bin/env python3
"""
For an FB2/FB2.ZIP source, decide whether we need an online cover lookup, and if
so, search for a cover image and save it to the given output path.

Sources, tried in order:
  1. Open Library  -- https://openlibrary.org (stable, no key, handles Russian)
  2. Google Books  -- https://books.google.com (broader catalog, rate-limited per IP)

Exit codes:
  0 -- online cover downloaded; saved path printed to stdout
  3 -- source already has an embedded cover; no action needed
  1 -- no cover found anywhere (or error); proceed without cover
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
TIMEOUT_DOWNLOAD = 15
UA = "fb2-to-epub-watcher/1.0"
MIN_BYTES = 1024


def has_embedded_cover(src: str) -> bool:
    """True if Calibre can extract a non-trivial cover image from the source."""
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
    """Return (title, author) parsed from ebook-meta output."""
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
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=TIMEOUT_SEARCH) as r:
            data = json.loads(r.read().decode("utf-8"))
    except Exception:
        return None
    for doc in data.get("docs", []):
        cover_i = doc.get("cover_i")
        if cover_i:
            return f"https://covers.openlibrary.org/b/id/{cover_i}-L.jpg"
    return None


def search_google_books(title: str, author: str | None):
    q = []
    if title:
        q.append(f'intitle:"{title}"')
    if author:
        q.append(f'inauthor:"{author}"')
    if not q:
        return None
    url = (
        "https://www.googleapis.com/books/v1/volumes?q="
        + "+".join(urllib.parse.quote(p) for p in q)
        + "&maxResults=5"
    )
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=TIMEOUT_SEARCH) as r:
            data = json.loads(r.read().decode("utf-8"))
    except Exception:
        return None
    for item in data.get("items", []):
        imgs = item.get("volumeInfo", {}).get("imageLinks", {})
        for key in ("extraLarge", "large", "medium", "small", "thumbnail", "smallThumbnail"):
            if key in imgs:
                u = imgs[key].replace("http://", "https://")
                u = re.sub(r"zoom=\d+", "zoom=3", u)
                u = u.replace("&edge=curl", "")
                return u
    return None


def search_cover(title: str, author: str | None):
    """Try each source in order; return the first usable cover URL."""
    for fn in (search_open_library, search_google_books):
        u = fn(title, author)
        if u:
            return u
    return None


def download(url: str, dst: str) -> bool:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=TIMEOUT_DOWNLOAD) as r:
            data = r.read()
    except Exception:
        return False
    if len(data) < MIN_BYTES:
        return False
    try:
        with open(dst, "wb") as f:
            f.write(data)
    except Exception:
        return False
    return True


def main():
    if len(sys.argv) != 3:
        sys.exit(2)
    src, dst = sys.argv[1], sys.argv[2]
    if not os.path.isfile(src):
        sys.exit(1)
    if has_embedded_cover(src):
        sys.exit(3)
    title, author = get_meta(src)
    if not title:
        sys.exit(1)
    url = search_cover(title, author)
    if not url:
        sys.exit(1)
    if not download(url, dst):
        sys.exit(1)
    print(dst)
    sys.exit(0)


if __name__ == "__main__":
    main()

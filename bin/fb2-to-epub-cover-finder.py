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
      cover-finder.py --json --book-id <id> --previews-dir <dir>
                      [--exclude <url> ...] [--query <text>] <src>
    Searches the same sources, keeps the top-N usable candidates (N<=4),
    downloads each preview to <previews-dir>/<book-id>/<rank>.jpg, scores them,
    and prints ONE JSON object to stdout:
    --query <text> (optional): a user-supplied search string (author+title) that
    OVERRIDES the epub metadata for searching -- auto-extracted meta is often
    irrelevant, so the user's words drive both sources. --exclude still applies.
      {book_id, title, author,
       candidates:[{id,rank,source,url,preview_path,score,item_title,title_match}],
       best_candidate_id, confident}
    title_match is per-candidate: does the book title appear in that candidate's
    caption (DDG image title / OpenLibrary title)? best_candidate_id is the
    top-scoring TITLE-MATCH candidate, or null if none match; confident mirrors
    that (true iff best_candidate_id is set). All candidates are still returned
    so the user can pick one (web or generated) in the queue UI.
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


# --- title-match ----------------------------------------------------------
# The ranking above only measures "does this image look like a book cover" —
# it says nothing about WHOSE cover it is. For an author who has covers online
# but not THIS book (e.g. «Падчевары» Варламова), image search returns other
# books by the same author and the best-looking one is still the wrong book.
# title-match closes that gap: a candidate is trusted only when the book's
# title words actually appear in the source's caption/structural title. We use
# it to gate `best_candidate_id` (auto-embed) — NOT to drop candidates: every
# candidate is still returned so the user can pick one (web or generated) in
# the picker. Erring strict is deliberate: a wrong auto-cover is worse than
# leaving the choice to the user.

# Service/stop words too generic to carry a title's identity. Kept short and
# RU/EN-mixed because epub titles often blend both ("Книга 1: The Road").
_TITLE_STOPWORDS = {
    "и", "в", "во", "на", "с", "со", "о", "об", "от", "до", "по", "за", "из",
    "у", "к", "ко", "не", "ни", "да", "же", "бы", "ли", "то", "а", "но", "или",
    "the", "a", "an", "of", "and", "or", "to", "in", "on", "at", "for",
    "том", "книга", "часть", "роман",
}

# Word characters for RU+EN; everything else is a separator. \w under re.UNICODE
# also pulls in digits and underscore, which is fine (digits in a title like
# "1984" are significant and worth matching).
_WORD_RE = re.compile(r"[^\W_]+", re.UNICODE)


def _title_tokens(text: str | None) -> list[str]:
    """Normalise a title/caption into comparable tokens.

    lower-case, split on punctuation/whitespace, drop service words and very
    short tokens (<=2 chars, e.g. stray initials) that match too easily. The
    `ё`->`е` fold avoids spurious misses between «ёлка»/«елка»."""
    if not text:
        return []
    text = text.lower().replace("ё", "е")
    out = []
    for tok in _WORD_RE.findall(text):
        if len(tok) <= 2 or tok in _TITLE_STOPWORDS:
            continue
        out.append(tok)
    return out


def _stem(tok: str) -> str:
    """Crude RU stem: drop a short inflectional tail so «Падчевары» and
    «Падчеварах» share a stem. We keep a generous prefix (the longer of 4 chars
    or len-3) rather than a real morphological analyser — enough to absorb case
    endings without collapsing distinct words. Short tokens (<=4) stay whole."""
    if len(tok) <= 4:
        return tok
    keep = max(4, len(tok) - 3)
    return tok[:keep]


def title_matches(needle: str | None, haystack: str | None) -> bool:
    """True when the book title `needle` is present in the candidate's caption
    `haystack` (DDG image `title` or OpenLibrary structural title).

    Match by SIGNIFICANT title words on a stem/prefix basis (so case endings
    don't break it). Require ALL significant title words to be present — strict
    on purpose: a false "this is the book" is worse than leaving the user to
    pick. A needle with no significant words (all stop/short) can't be matched,
    so it returns False (-> not confident -> no auto-embed)."""
    need = _title_tokens(needle)
    if not need:
        return False
    hay_stems = {_stem(t) for t in _title_tokens(haystack)}
    if not hay_stems:
        return False
    for nt in need:
        ns = _stem(nt)
        # A needle stem matches if it is a prefix of (or equal to) any haystack
        # stem, or vice-versa — covers longer surface forms on either side.
        if not any(hs == ns or hs.startswith(ns) or ns.startswith(hs)
                   for hs in hay_stems):
            return False
    return True


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


def search_open_library(title: str, author: str | None, query: str | None = None):
    """Catalog search. When `query` is given (user's free-text hint) it overrides
    title/author and goes into the general `q=` field as one search string; the
    user's words decide the match, not the epub metadata."""
    if query:
        params = {"limit": "5", "q": query}
    else:
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
            # doc["title"] is the catalog's structural book title — captured so
            # the caller can title-match it against what we searched for.
            out.append((
                f"https://covers.openlibrary.org/b/id/{cid}-L.jpg",
                "open_library",
                doc.get("title") or "",
            ))
    log(f"open-library: {len(out)} candidates")
    return out


def search_duckduckgo(title: str, author: str | None, page: int = 1,
                      query: str | None = None):
    """DuckDuckGo image search. `page` maps to the i.js `p=` param: p=1 is the
    first result page, p=2 the next. Page 2 is used by the --exclude/refresh path
    to reach fresh URLs that did not appear on page 1.

    When `query` is given (user's free-text hint) it overrides the title/author
    string: we search by the user's words plus the same "обложка книги" hint that
    biases results toward book covers."""
    if query:
        query = f"{query} обложка книги"
    else:
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
        f"https://duckduckgo.com/i.js?l=us-en&o=json&p={int(page)}"
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
            # r["title"] is the image's caption / source page title — captured so
            # the caller can title-match it against what we searched for.
            out.append((u, "duckduckgo", r.get("title") or ""))
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


def run_json(
    src: str,
    book_id: str,
    previews_dir: str,
    exclude: list[str] | None = None,
    query: str | None = None,
) -> None:
    """--json mode: build top-N candidates with local previews + scores.

    `exclude` is a list of URLs the caller has already shown the user ("Search
    more"): they are seeded into `seen` so they are skipped during the merge,
    and if too few fresh previews survive (< MAX_JSON_CANDIDATES) we top up with
    DuckDuckGo page 2 to reach URLs that did not appear on page 1. The goal is to
    return NEW candidate URLs, none of them in `exclude`. If nothing new is
    found, `candidates` comes back empty (exit 0) so the watcher can flag it.

    `query` is the user's free-text hint (author+title). When non-empty it
    OVERRIDES the epub metadata as the search string for BOTH sources: auto-meta
    is often irrelevant, so the user's words drive the search. `exclude` still
    applies (don't re-offer shown URLs), and the embedded-cover bypass below also
    holds for a query-only first call -- a query is an explicit "find me a cover"
    intent, so we never short-circuit on an already-embedded cover.
    """
    query = (query or "").strip() or None
    refresh = bool(exclude)
    # Refresh/"Search more" (exclude given) means: find NEW variants even when a
    # cover is already embedded -- so skip the embedded-cover early-exit here.
    # An explicit query is the same kind of intent ("search by my words"), so it
    # also bypasses the early-exit. The plain first search (no exclude, no query)
    # keeps it: a present cover means nothing to do.
    if not refresh and not query and has_embedded_cover(src):
        sys.exit(3)
    title, author = get_meta(src)
    # With a user query the search string is the query itself, so missing epub
    # metadata is no longer fatal: only the no-query path still needs a title.
    if not title and not query:
        log("no title in metadata; giving up")
        sys.exit(1)
    log(f"[json] searching for: {title!r} / {author!r}"
        + (f" query={query!r}" if query else "")
        + (f" (refresh, exclude={len(exclude)})" if refresh else ""))

    # The string a candidate's caption must contain to count as title-match.
    # With a user query the user told us what to look for, so match against the
    # query; otherwise match against the epub title.
    match_target = query or title

    # Pre-seed the excluded URLs so the merge step never re-offers them.
    seen: set[str] = set(exclude or [])

    def merge_from(triples, merged: list) -> None:
        """Append unseen (url, source, item_title) triples, capped at
        MAX_CANDIDATES."""
        for u, source, item_title in triples:
            if u and u not in seen and len(merged) < MAX_CANDIDATES:
                seen.add(u)
                merged.append((u, source, item_title))

    merged: list[tuple[str, str, str]] = []   # (url, source, item_title)
    for src_fn in (search_open_library, search_duckduckgo):
        try:
            merge_from(src_fn(title, author, query=query), merged)
        except Exception as e:
            log(f"{src_fn.__name__} crashed: {e}")

    book_dir = os.path.join(previews_dir, book_id)
    candidates: list[dict] = []
    rank = 0

    def harvest(triples) -> None:
        """Download previews for (url, source, item_title) triples, appending
        usable ones to `candidates` (up to MAX_JSON_CANDIDATES), writing each to
        <rank>.jpg. Each candidate carries title_match: whether the book title
        appears in this candidate's caption (gates best/confident below)."""
        nonlocal rank
        for url, source, item_title in triples:
            if len(candidates) >= MAX_JSON_CANDIDATES:
                break
            rank += 1
            preview_path = os.path.join(book_dir, f"{rank}.jpg")
            dims = download_preview(url, preview_path)
            if not dims:
                rank -= 1   # this slot did not produce a usable preview
                continue
            w, h = dims
            tmatch = title_matches(match_target, item_title)
            candidates.append({
                "id": f"{book_id}-{rank}",
                "rank": rank,
                "source": source,
                "url": url,
                "preview_path": preview_path,
                "score": score_cover(w, h, source),
                "item_title": item_title,
                "title_match": tmatch,
            })
            log(f"[json] candidate #{rank} {source} score={candidates[-1]['score']}"
                f" match={tmatch} {url[:80]}")

    harvest(merged)

    # Top-up: if we still owe candidates (some previews failed, or excludes thinned
    # the merged set), reach for DuckDuckGo page 2 to surface NEW URLs not seen on
    # page 1. Only the still-needed shortfall is downloaded.
    if len(candidates) < MAX_JSON_CANDIDATES:
        extra: list[tuple[str, str, str]] = []
        try:
            merge_from(search_duckduckgo(title, author, page=2, query=query), extra)
        except Exception as e:
            log(f"ddg page 2 crashed: {e}")
        if extra:
            log(f"[json] top-up: {len(extra)} new url(s) from ddg page 2")
            harvest(extra)

    if not candidates:
        # In refresh mode an empty set is a valid answer ("no more"): exit 0 with
        # an empty candidates list so the watcher can mark no_more. In the normal
        # first search, no candidates still means "nothing found" -> exit 1.
        if refresh:
            out = {
                "book_id": book_id,
                "title": title,
                "author": author,
                "candidates": [],
                "best_candidate_id": None,
                "confident": False,
            }
            print(json.dumps(out, ensure_ascii=False))
            sys.exit(0)
        log("[json] no usable candidates")
        sys.exit(1)

    candidates.sort(key=lambda c: c["score"], reverse=True)

    # Auto-embed gate: best is the highest-scoring candidate AMONG those whose
    # caption actually contains the book title (title_match). If none match (the
    # author has covers online but not THIS book), best is null and confident is
    # false -> the watcher must NOT auto-embed; the user picks in the queue.
    matched = [c for c in candidates if c.get("title_match")]
    if matched:
        best = matched[0]["id"]   # candidates already sorted by score desc
        confident = True
    else:
        best = None
        confident = False
    log(f"[json] title-match: {len(matched)}/{len(candidates)} -> "
        f"best={best} confident={confident}")

    out = {
        "book_id": book_id,
        "title": title,
        "author": author,
        "candidates": candidates,
        "best_candidate_id": best,
        "confident": confident,
    }
    print(json.dumps(out, ensure_ascii=False))
    sys.exit(0)


def parse_json_args(argv: list[str]):
    """Parse the --json invocation.

    Returns (src, book_id, previews_dir, exclude, query).

    Expected: --json --book-id <id> --previews-dir <dir>
              [--exclude <url> ...] [--query <text>] <src>
    Flags may appear in any order; exactly one positional <src>. --exclude takes
    one or more values and may be repeated; each consumes the following tokens
    that look like URLs (http/https), so the trailing <src> path is never eaten.
    --query takes exactly the single following token as the user's search string
    (it is NOT URL-shaped, so it can never be confused with the <src> positional).
    """
    book_id = previews_dir = None
    exclude: list[str] = []
    query: str | None = None
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
        elif a == "--query":
            query = argv[i + 1] if i + 1 < len(argv) else None
            i += 2
        elif a == "--exclude":
            i += 1
            # Greedily take following URL-looking tokens; stop at the next flag
            # or a non-URL token (e.g. the trailing <src> path).
            while i < len(argv) and argv[i].startswith(("http://", "https://")):
                exclude.append(argv[i])
                i += 1
        else:
            positionals.append(a)
            i += 1
    if not book_id or not previews_dir or len(positionals) != 1:
        sys.exit(2)
    return positionals[0], book_id, previews_dir, exclude, query


def main() -> None:
    args = sys.argv[1:]

    if "--json" in args:
        src, book_id, previews_dir, exclude, query = parse_json_args(args)
        if not os.path.isfile(src):
            sys.exit(1)
        run_json(src, book_id, previews_dir, exclude, query)
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
            # Sources now yield (url, source, item_title); legacy mode only needs
            # the url (single-best contract is unchanged, no title-match gating).
            for u, _source, _item_title in src_fn(title, author):
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

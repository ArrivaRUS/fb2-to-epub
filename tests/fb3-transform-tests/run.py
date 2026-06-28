#!/usr/bin/env python3
# run.py — TAP test runner for the FB3 -> FB2 transform (bin/fb2-to-epub-fb3.py).
#
# Stdlib only (no pytest / no lxml) on purpose: the transform itself ships with
# zero third-party deps, and the project's other suites are self-contained TAP
# runners. This file mirrors that style so it runs anywhere python3 exists.
#
# Two ways the transform is exercised:
#   • in-process  — import the module, call transform()/build_description() and
#                   assert against the parsed FB2 ElementTree (fine-grained:
#                   text/tail, ids, hrefs, binary count, content-types).
#   • subprocess  — run the real CLI for return-code scenarios (rc=0/1/2) and
#                   the determinism/idempotence check (byte-identical reruns).
#
# Fixtures: built in-process by make_fixtures.py (synthetic, portable). Real
# ~/Desktop/fb2-to-epub/*.fb3 are used ADDITIONALLY when present (else skipped).
#
# Optional e2e: if calibre `ebook-convert` is on PATH (or at the conventional
# macOS location), FB3 -> FB2 -> EPUB is run and the EPUB is checked to be a
# valid zip with an OPF; otherwise that single test is reported as a SKIP.
#
# Exit: 0 = all tests passed (skips allowed), 1 = at least one failure.

import base64
import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
SCRIPT = os.path.join(REPO, "bin", "fb2-to-epub-fb3.py")
GENRE_MAP = os.path.join(REPO, "bin", "fb2-to-epub-fb3-genre.json")

FB2 = "http://www.gribuser.ru/xml/fictionbook/2.0"
XL = "http://www.w3.org/1999/xlink"

sys.path.insert(0, HERE)
import make_fixtures as mf  # noqa: E402


# ---------------------------------------------------------------------------
# Import the transform module under test (filename has dashes -> load by path).
# ---------------------------------------------------------------------------
def _load_transform_module():
    spec = importlib.util.spec_from_file_location("fb3_transform", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FB3 = _load_transform_module()
# Silence the transform's stderr diagnostics during in-process calls so the TAP
# stream stays clean. The dedicated stdout/stderr-contract test (t_stdout_mode_*)
# runs the CLI in a subprocess with diagnostics ON, so coverage is unaffected.
FB3._QUIET = True


# ---------------------------------------------------------------------------
# Tiny assert helpers (raise AssertionError with a clear message on failure).
# ---------------------------------------------------------------------------
def _local(tag):
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag


def eq(got, want, what):
    if got != want:
        raise AssertionError("%s: got %r, want %r" % (what, got, want))


def ok(cond, what):
    if not cond:
        raise AssertionError(what)


def parse_fb2_from_fixture(build_fn):
    """Build a fixture, run the transform in-process, return the parsed root."""
    raw = build_fn()
    with tempfile.NamedTemporaryFile(suffix=".fb3", delete=False) as f:
        f.write(raw)
        path = f.name
    try:
        genre = FB3.load_genre_map(GENRE_MAP)
        fb2_bytes = FB3.transform(path, genre)
    finally:
        os.unlink(path)
    return ET.fromstring(fb2_bytes), fb2_bytes


def run_cli(input_bytes, suffix=".fb3", extra_args=None, out_to_file=True):
    """Run the real CLI on input_bytes; return (rc, stdout_bytes, out_fb2_path)."""
    d = tempfile.mkdtemp(prefix="fb3cli.")
    inp = os.path.join(d, "in" + suffix)
    with open(inp, "wb") as f:
        f.write(input_bytes)
    out = os.path.join(d, "out.fb2")
    argv = [sys.executable, SCRIPT, "--quiet", "--genre-map", GENRE_MAP]
    if out_to_file:
        argv += ["--out", out]
    if extra_args:
        argv += extra_args
    argv += [inp]
    p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return p.returncode, p.stdout, (out if (out_to_file and os.path.exists(out)) else None), d


def find_ebook_convert():
    cand = shutil.which("ebook-convert")
    if cand:
        return cand
    mac = "/Applications/calibre.app/Contents/MacOS/ebook-convert"
    return mac if os.path.exists(mac) else None


def find_real_fb3():
    base = os.path.expanduser("~/Desktop/fb2-to-epub")
    if not os.path.isdir(base):
        return []
    out = []
    for n in sorted(os.listdir(base)):
        if n.lower().endswith(".fb3"):
            out.append(os.path.join(base, n))
    return out


# ===========================================================================
# Tests. Each returns None on success or raises AssertionError. SKIP via the
# SkipTest sentinel.
# ===========================================================================
class SkipTest(Exception):
    pass


def t_e2e_valid_fb2():
    """Scenario: transform -> well-formed FB2 (parses) with the right shape."""
    root, _ = parse_fb2_from_fixture(mf.build_full_fb3)
    eq(_local(root.tag), "FictionBook", "root element")
    ok(root.find("{%s}description" % FB2) is not None, "has <description>")
    bodies = root.findall("{%s}body" % FB2)
    ok(len(bodies) >= 1, "has at least one <body>")


def t_e2e_binaries_count_unique():
    """Scenario: #<binary> == number of UNIQUE images (i_001 reused -> 1)."""
    root, _ = parse_fb2_from_fixture(mf.build_full_fb3)
    bins = root.findall("{%s}binary" % FB2)
    eq(len(bins), mf.FULL_UNIQUE_BINARIES, "binary count == unique images")
    ids = sorted(b.get("id") for b in bins)
    # every binary id is u-prefixed and ids are unique
    ok(all(i.startswith("u") for i in ids), "binary ids u-prefixed: %s" % ids)
    eq(len(set(ids)), len(ids), "binary ids unique")
    # base64 payloads decode and are non-empty
    for b in bins:
        raw = base64.b64decode(b.text)
        ok(len(raw) > 0, "binary %s decodes non-empty" % b.get("id"))


def t_e2e_cover():
    """Scenario: cover -> title-info/coverpage + a 'cover' binary (image/png)."""
    root, _ = parse_fb2_from_fixture(mf.build_full_fb3)
    ti = root.find("{%s}description/{%s}title-info" % (FB2, FB2))
    cp = ti.find("{%s}coverpage" % FB2)
    ok(cp is not None, "title-info has <coverpage>")
    img = cp.find("{%s}image" % FB2)
    href = img.get("{%s}href" % XL)
    eq(href, "#ucover", "coverpage image href")
    # the referenced binary exists and is the green cover PNG
    bins = {b.get("id"): b for b in root.findall("{%s}binary" % FB2)}
    ok("ucover" in bins, "binary 'ucover' present")
    eq(bins["ucover"].get("content-type"), "image/png", "cover content-type")
    eq(base64.b64decode(bins["ucover"].text), mf.PNG_GREEN, "cover bytes match")


def t_metadata_core():
    """Scenario: metadata (title/authors/lang/src-lang) + genre via genre-map."""
    root, _ = parse_fb2_from_fixture(mf.build_full_fb3)
    ti = root.find("{%s}description/{%s}title-info" % (FB2, FB2))
    eq(ti.find("{%s}book-title" % FB2).text, "Синтетическая книга", "book-title")
    eq(ti.find("{%s}lang" % FB2).text, "ru", "lang")
    eq(ti.find("{%s}src-lang" % FB2).text, "en", "src-lang")
    # genre via genre-map: "Личные финансы" -> personal_finance
    genres = [g.text for g in ti.findall("{%s}genre" % FB2)]
    ok("personal_finance" in genres, "genre mapped via genre-map: %s" % genres)
    # authors: two <author>, each with last-name
    authors = ti.findall("{%s}author" % FB2)
    eq(len(authors), 2, "two authors")
    lastnames = [a.find("{%s}last-name" % FB2).text for a in authors]
    ok("Сидоров" in lastnames and "Кузнецова" in lastnames,
       "author last names: %s" % lastnames)
    # translator present
    tr = ti.findall("{%s}translator" % FB2)
    eq(len(tr), 1, "one translator")
    eq(tr[0].find("{%s}last-name" % FB2).text, "Борич", "translator last name")


def t_inline_em_and_tails():
    """Scenario: em->emphasis (+strong/sub/sup/strikethrough) and text/tail
    around inline runs are preserved (risk R1)."""
    root, _ = parse_fb2_from_fixture(mf.build_full_fb3)
    p = None
    for cand in root.iter("{%s}p" % FB2):
        if cand.get("id") == "up_inline":
            p = cand
            break
    ok(p is not None, "found inline test paragraph")
    eq(p.text, "before ", "leading text preserved")
    kids = list(p)
    names = [_local(k.tag) for k in kids]
    eq(names, ["emphasis", "strong", "sub", "sup", "strikethrough"],
       "inline rename incl. em->emphasis: %s" % names)
    eq(kids[0].text, "emp", "emphasis text")
    eq(kids[0].tail, " mid ", "tail after emphasis (mixed content kept)")
    eq(kids[-1].tail, " after", "trailing tail preserved")


def t_links_internal_external_note():
    """Scenario: internal #id -> #uid, external as-is, note -> a type=note #uid."""
    root, _ = parse_fb2_from_fixture(mf.build_full_fb3)
    target = None
    for p in root.iter("{%s}p" % FB2):
        if any(_local(c.tag) == "a" for c in p):
            target = p
            break
    ok(target is not None, "found link paragraph")
    a = [c for c in target if _local(c.tag) == "a"]
    eq(a[0].get("{%s}href" % XL), "#usec_two", "internal link rewritten to #uid")
    eq(a[1].get("{%s}href" % XL), "https://example.com/x", "external link as-is")
    eq(a[2].get("{%s}href" % XL), "#un_1", "note href #uid")
    eq(a[2].get("type"), "note", "note carries type=note")
    # tails around the links are preserved
    eq(a[0].tail, " and ", "tail after internal link")
    eq(a[2].tail, " done.", "tail after note")


def t_link_target_ids_exist():
    """Scenario: link/note targets actually exist in the FB2 (id integrity)."""
    root, _ = parse_fb2_from_fixture(mf.build_full_fb3)
    all_ids = set()
    for el in root.iter():
        i = el.get("id")
        if i:
            all_ids.add(i)
    ok("usec_two" in all_ids, "#usec_two target section exists")
    ok("un_1" in all_ids, "#un_1 note target (notebody->section) exists")


def t_lists_ul_ol():
    """Scenario: ul/ol -> cite>p with bullet / ordinal prefixes."""
    root, _ = parse_fb2_from_fixture(mf.build_full_fb3)
    texts = []
    for cite in root.iter("{%s}cite" % FB2):
        ps = [c for c in cite if _local(c.tag) == "p"]
        if ps:
            texts.append(["".join(p.itertext()) for p in ps])
    ul = [t for t in texts if any("alpha" in x for x in t)]
    ol = [t for t in texts if any("one" in x for x in t)]
    ok(ul, "ul mapped to cite>p")
    ok(ol, "ol mapped to cite>p")
    ok(ul[0][0].startswith("•"), "ul item has bullet prefix: %r" % ul[0][0])
    ok(ol[0][0].startswith("1"), "ol item starts with ordinal: %r" % ol[0][0])
    ok(ol[0][1].startswith("2"), "ol second item ordinal 2: %r" % ol[0][1])


def t_table():
    """Scenario: table -> FB2 table with th/td preserved (+ id u-prefixed)."""
    root, _ = parse_fb2_from_fixture(mf.build_full_fb3)
    tbls = list(root.iter("{%s}table" % FB2))
    eq(len(tbls), 1, "one table")
    eq(tbls[0].get("id"), "utbl1", "table id u-prefixed")
    rows = list(tbls[0])
    ths = [c for c in rows[0] if _local(c.tag) == "th"]
    tds = [c for c in rows[1] if _local(c.tag) == "td"]
    eq([t.text for t in ths], ["H1", "H2"], "header cells")
    eq([t.text for t in tds], ["a1", "b1"], "data cells")


def t_multisection():
    """Scenario: nested section>section depth preserved."""
    root, _ = parse_fb2_from_fixture(mf.build_full_fb3)
    main = root.find("{%s}body" % FB2)
    top = [c for c in main if _local(c.tag) == "section"]
    eq(len(top), 2, "two top-level sections")

    def depth(sec, d=1):
        subs = [c for c in sec if _local(c.tag) == "section"]
        return d if not subs else max(depth(s, d + 1) for s in subs)
    by_id = {s.get("id"): s for s in top}
    eq(depth(by_id["usec_two"]), 2, "sec_two has a nested section (depth 2)")
    eq(by_id["usec_two_nested"] if "usec_two_nested" in by_id else
       (by_id["usec_two"].find("{%s}section" % FB2).get("id")),
       "usec_two_nested", "nested section id preserved (u-prefixed)")


def t_notes_count_gt1():
    """Scenario: two <notes> -> single <body name="notes"> with two sections."""
    root, _ = parse_fb2_from_fixture(mf.build_full_fb3)
    notes_bodies = [b for b in root.findall("{%s}body" % FB2)
                    if b.get("name") == "notes"]
    eq(len(notes_bodies), 1, "exactly one notes body")
    secs = [s for s in notes_bodies[0] if _local(s.tag) == "section"]
    eq(len(secs), 2, "two sections (one per <notes> block)")
    inner_ids = sorted(s.get("id") for s in notes_bodies[0].iter("{%s}section" % FB2)
                       if s.get("id"))
    eq(inner_ids, ["un_1", "un_2"], "notebody ids u-prefixed")


def t_notes_count_eq1():
    """Scenario: one <notes> -> single notes body with one section."""
    root, _ = parse_fb2_from_fixture(mf.build_single_notes_fb3)
    notes_bodies = [b for b in root.findall("{%s}body" % FB2)
                    if b.get("name") == "notes"]
    eq(len(notes_bodies), 1, "one notes body")
    inner_ids = [s.get("id") for s in notes_bodies[0].iter("{%s}section" % FB2)
                 if s.get("id")]
    eq(inner_ids, ["un_1"], "single notebody id")


def t_svg_graceful():
    """Scenario: SVG image -> graceful (inlined as image/svg+xml, no crash)."""
    root, _ = parse_fb2_from_fixture(mf.build_full_fb3)
    bins = {b.get("id"): b for b in root.findall("{%s}binary" % FB2)}
    ok("upic.svg" in bins, "svg inlined as binary 'upic.svg'")
    eq(bins["upic.svg"].get("content-type"), "image/svg+xml", "svg content-type")
    # and it is referenced by an <image> in the body
    hrefs = [img.get("{%s}href" % XL) for img in root.iter("{%s}image" % FB2)]
    ok("#upic.svg" in hrefs, "svg referenced by an <image>: %s" % hrefs)


def t_image_dedup():
    """Scenario: same image used twice -> one <binary>, two <image> refs."""
    root, _ = parse_fb2_from_fixture(mf.build_full_fb3)
    img_hrefs = [img.get("{%s}href" % XL) for img in root.iter("{%s}image" % FB2)]
    eq(img_hrefs.count("#ui_001.png"), 2, "i_001 referenced twice")
    bins = [b for b in root.findall("{%s}binary" % FB2)
            if b.get("id") == "ui_001.png"]
    eq(len(bins), 1, "i_001 inlined exactly once (dedup)")


def t_no_cover_path():
    """Scenario: no thumbnail rel & no coverpage -> NO <coverpage> in FB2
    (downstream finder/generator kicks in)."""
    root, _ = parse_fb2_from_fixture(mf.build_no_cover_fb3)
    ti = root.find("{%s}description/{%s}title-info" % (FB2, FB2))
    ok(ti.find("{%s}coverpage" % FB2) is None, "no coverpage when no thumbnail")
    # ... and no 'cover' binary leaked in
    ids = [b.get("id") for b in root.findall("{%s}binary" % FB2)]
    ok("ucover" not in ids, "no cover binary: %s" % ids)


def t_rc_not_fb3_zip():
    """Scenario error: a plain .zip (no [Content_Types].xml) -> rc=2."""
    rc, _, _, d = run_cli(mf.build_not_opc_zip(), suffix=".fb3")
    shutil.rmtree(d, ignore_errors=True)
    eq(rc, 2, "rc for non-OPC zip")


def t_rc_not_fb3_plain():
    """Scenario error: a non-zip file -> rc=2."""
    rc, _, _, d = run_cli(mf.build_plain_file(), suffix=".fb3")
    shutil.rmtree(d, ignore_errors=True)
    eq(rc, 2, "rc for plain (non-zip) file")


def t_rc_broken_body_xml():
    """Scenario error: malformed body.xml inside a valid FB3 -> rc=1 (!=0,!=2)."""
    rc, _, _, d = run_cli(mf.build_broken_body_fb3(), suffix=".fb3")
    shutil.rmtree(d, ignore_errors=True)
    eq(rc, 1, "rc for broken body.xml")


def t_rc_broken_descr_xml():
    """Scenario error: malformed description.xml -> rc=1."""
    rc, _, _, d = run_cli(mf.build_broken_descr_fb3(), suffix=".fb3")
    shutil.rmtree(d, ignore_errors=True)
    eq(rc, 1, "rc for broken description.xml")


def t_rc_zip_bomb_guard():
    """Scenario security: a zip-bomb-like FB3 (absurd compression ratio) is
    rejected with rc=1 by the guard BEFORE any entry is read -> no OOM.

    Run via the real CLI (subprocess) so an actual out-of-memory would surface
    as a non-1 rc / crash rather than being swallowed in-process. A short
    timeout turns a regression (guard removed -> reads/inflates the bomb) into a
    visible failure instead of a hang."""
    d = tempfile.mkdtemp(prefix="fb3bomb.")
    inp = os.path.join(d, "in.fb3")
    with open(inp, "wb") as f:
        f.write(mf.build_zip_bomb_fb3())
    try:
        argv = [sys.executable, SCRIPT, "--quiet", "--genre-map", GENRE_MAP,
                "--out", os.path.join(d, "out.fb2"), inp]
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=60)
        eq(p.returncode, 1, "zip-bomb rejected with rc=1 (stderr: %s)"
           % p.stderr.decode("utf-8", "replace")[-200:])
        ok(not os.path.exists(os.path.join(d, "out.fb2")),
           "no FB2 written for a rejected bomb")
    except subprocess.TimeoutExpired:
        raise AssertionError("guard missing: transform hung on the zip-bomb")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def t_rc_success():
    """Scenario: valid FB3 via the real CLI -> rc=0 and a non-empty FB2 file."""
    rc, _, out, d = run_cli(mf.build_full_fb3(), suffix=".fb3")
    try:
        eq(rc, 0, "rc for valid FB3")
        ok(out is not None and os.path.getsize(out) > 0, "FB2 written non-empty")
        ET.parse(out)  # parses
    finally:
        shutil.rmtree(d, ignore_errors=True)


def t_determinism_idempotent():
    """Scenario: transforming the SAME input twice yields byte-identical FB2."""
    raw = mf.build_full_fb3()
    rc1, _, out1, d1 = run_cli(raw, suffix=".fb3")
    rc2, _, out2, d2 = run_cli(raw, suffix=".fb3")
    try:
        eq(rc1, 0, "first run rc")
        eq(rc2, 0, "second run rc")
        b1 = open(out1, "rb").read()
        b2 = open(out2, "rb").read()
        eq(b1, b2, "two runs produce byte-identical FB2")
    finally:
        shutil.rmtree(d1, ignore_errors=True)
        shutil.rmtree(d2, ignore_errors=True)


def t_stdout_mode_is_fb2_only():
    """Scenario: without --out, stdout carries ONLY FB2 bytes (parseable),
    diagnostics go to stderr. Confirms the watcher's stdout contract."""
    d = tempfile.mkdtemp(prefix="fb3stdout.")
    inp = os.path.join(d, "in.fb3")
    with open(inp, "wb") as f:
        f.write(mf.build_full_fb3())
    # NOT quiet, NO --out: stderr should get the 'fb3:' info line, stdout pure FB2
    p = subprocess.run(
        [sys.executable, SCRIPT, "--genre-map", GENRE_MAP, inp],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    shutil.rmtree(d, ignore_errors=True)
    eq(p.returncode, 0, "rc for stdout mode")
    root = ET.fromstring(p.stdout)  # stdout must parse as FB2 on its own
    eq(_local(root.tag), "FictionBook", "stdout is FB2")
    ok(b"fb3:" in p.stderr, "diagnostics went to stderr, not stdout")


def t_e2e_ebook_convert():
    """Optional e2e: FB3 -> FB2 -> EPUB via calibre ebook-convert. SKIP if
    calibre is not installed (it is not in CI / the repo)."""
    ec = find_ebook_convert()
    if not ec:
        raise SkipTest("ebook-convert not installed")
    d = tempfile.mkdtemp(prefix="fb3epub.")
    try:
        inp = os.path.join(d, "in.fb3")
        with open(inp, "wb") as f:
            f.write(mf.build_full_fb3())
        fb2 = os.path.join(d, "book.fb2")
        rc, _, out, d2 = run_cli(mf.build_full_fb3(), suffix=".fb3")
        shutil.rmtree(d2, ignore_errors=True)
        eq(rc, 0, "transform rc before ebook-convert")
        # write the produced FB2 fresh for calibre
        with open(fb2, "wb") as f:
            f.write(FB3.transform(inp, FB3.load_genre_map(GENRE_MAP)))
        epub = os.path.join(d, "book.epub")
        p = subprocess.run([ec, fb2, epub],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        eq(p.returncode, 0, "ebook-convert rc (stderr: %s)"
           % p.stderr.decode("utf-8", "replace")[-300:])
        ok(os.path.exists(epub) and os.path.getsize(epub) > 0, "epub produced")
        ok(zipfile.is_zipfile(epub), "epub is a zip container")
        with zipfile.ZipFile(epub) as z:
            names = z.namelist()
        ok(any(n.endswith(".opf") for n in names), "epub has an OPF package")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def t_real_desktop_files():
    """Optional: run the transform on any real ~/Desktop/fb2-to-epub/*.fb3.
    SKIP when none are present (they are not in the repo / CI)."""
    files = find_real_fb3()
    if not files:
        raise SkipTest("no real *.fb3 on Desktop")
    genre = FB3.load_genre_map(GENRE_MAP)
    for path in files:
        fb2 = FB3.transform(path, genre)
        root = ET.fromstring(fb2)  # must parse
        eq(_local(root.tag), "FictionBook", "real file -> FB2 (%s)"
           % os.path.basename(path))


# ---------------------------------------------------------------------------
# TAP driver
# ---------------------------------------------------------------------------
TESTS = [
    ("e2e: transform -> well-formed FB2", t_e2e_valid_fb2),
    ("e2e: binary count == unique images", t_e2e_binaries_count_unique),
    ("e2e: cover (coverpage + cover binary)", t_e2e_cover),
    ("metadata: title/authors/lang/genre-map", t_metadata_core),
    ("mapping: em->emphasis + text/tail kept", t_inline_em_and_tails),
    ("mapping: links internal/external/note", t_links_internal_external_note),
    ("mapping: link/note targets exist", t_link_target_ids_exist),
    ("mapping: ul/ol lists", t_lists_ul_ol),
    ("mapping: table th/td", t_table),
    ("mapping: nested sections (multisection)", t_multisection),
    ("mapping: notes count>1 -> 1 notes body/2 sec", t_notes_count_gt1),
    ("mapping: notes count==1", t_notes_count_eq1),
    ("mapping: SVG image graceful (inlined)", t_svg_graceful),
    ("mapping: duplicate image deduped", t_image_dedup),
    ("edge: no cover -> no <coverpage>", t_no_cover_path),
    ("error: non-OPC zip -> rc=2", t_rc_not_fb3_zip),
    ("error: plain file -> rc=2", t_rc_not_fb3_plain),
    ("error: broken body.xml -> rc=1", t_rc_broken_body_xml),
    ("error: broken description.xml -> rc=1", t_rc_broken_descr_xml),
    ("security: zip-bomb guard -> rc=1, no OOM", t_rc_zip_bomb_guard),
    ("cli: valid FB3 -> rc=0 + FB2 file", t_rc_success),
    ("determinism: rerun is byte-identical", t_determinism_idempotent),
    ("cli: stdout is FB2-only, diag on stderr", t_stdout_mode_is_fb2_only),
    ("e2e: FB3->FB2->EPUB (calibre, optional)", t_e2e_ebook_convert),
    ("real: ~/Desktop/*.fb3 (optional)", t_real_desktop_files),
]


def main():
    print("TAP version 13")
    print("1..%d" % len(TESTS))
    passed = failed = skipped = 0
    for i, (name, fn) in enumerate(TESTS, start=1):
        try:
            fn()
        except SkipTest as e:
            skipped += 1
            print("ok %d - %s # SKIP %s" % (i, name, e))
        except AssertionError as e:
            failed += 1
            print("not ok %d - %s" % (i, name))
            for line in ("%s" % e).splitlines():
                print("  # %s" % line)
        except Exception as e:  # unexpected -> a failure, with type
            failed += 1
            print("not ok %d - %s" % (i, name))
            print("  # unexpected %s: %s" % (type(e).__name__, e))
        else:
            passed += 1
            print("ok %d - %s" % (i, name))
    print("# passed=%d failed=%d skipped=%d total=%d"
          % (passed, failed, skipped, len(TESTS)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

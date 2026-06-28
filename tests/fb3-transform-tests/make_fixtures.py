#!/usr/bin/env python3
# make_fixtures.py — synthetic FB3 fixtures for the FB3->FB2 transform tests.
#
# WHY synthetic (not the real ~/Desktop/*.fb3): those files are NOT in the repo
# or CI. This module builds a minimal-but-complete FB3 (valid OPC/ZIP container)
# entirely in-process from string templates, so the suite is portable and
# deterministic. Real Desktop files, when present, are exercised ADDITIONALLY by
# run.py (skipped otherwise).
#
# What `build_full_fb3()` produces (the "kitchen-sink" book) — one fixture that
# touches every mapping branch the transform supports:
#   container : [Content_Types].xml, _rels/.rels (Book rel + metadata/thumbnail
#               cover rel), fb3/_rels/description.xml.rels (body rel),
#               fb3/_rels/body.xml.rels (image rels).
#   metadata  : title/main, two authors + a translator, lang, src-lang, a genre
#               subject that the genre-map resolves, annotation (with <em>),
#               sequence, written/date, document-info (id/version/program-used).
#   body      : two top-level <section>s; nested section (multi-section depth);
#               <p> with em/strong/sub/sup/strikethrough + surrounding text/tail;
#               an internal link (#sec_two), an external link, a <note>;
#               <ul> and <ol>; a <table> with th/td; an image paragraph
#               referencing i_001.png AND a second paragraph reusing the SAME
#               image (dedup check); a distinct second image i_002.png; an SVG
#               image (graceful path); TWO <notes> blocks (count>1 -> single
#               <body name="notes"> with two <section>s).
#   images    : i_001.png, i_002.png (distinct 1x1 PNGs), pic.svg, cover.png.
#
# Variants (all derived from the same templates):
#   build_full_fb3()          -> bytes of the kitchen-sink .fb3
#   build_no_cover_fb3()      -> same, but NO thumbnail rel and NO coverpage
#   build_single_notes_fb3()  -> exactly ONE <notes> block (count==1 path)
#   build_broken_body_fb3()   -> body.xml is malformed XML        (rc=1)
#   build_broken_descr_fb3()  -> description.xml is malformed XML (rc=1)
#   build_not_opc_zip()       -> a plain .zip, no [Content_Types].xml (rc=2)
#   build_plain_file()        -> not a zip at all                 (rc=2)
#
# Everything is stdlib only (zipfile/base64), mirroring the transform itself.

import base64
import io
import zipfile

# ---------------------------------------------------------------------------
# Tiny real raster bytes (so base64 round-trips and Calibre can read them).
# 1x1 PNGs, two visually-distinct ones so "unique image count" is meaningful.
# ---------------------------------------------------------------------------
# 1x1 opaque-red PNG
PNG_RED = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmM"
    "IQAAAABJRU5ErkJggg=="
)
# 1x1 opaque-blue PNG
PNG_BLUE = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYPhfDwAChwGA60e6"
    "kgAAAABJRU5ErkJggg=="
)
# 1x1 opaque-green PNG (used for the cover so it is byte-distinct from body imgs)
PNG_GREEN = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwAEhQGAVrW8"
    "wwAAAABJRU5ErkJggg=="
)
SVG_PIC = (
    b'<?xml version="1.0" encoding="UTF-8"?>\n'
    b'<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4">'
    b'<rect width="4" height="4" fill="#888"/></svg>\n'
)

CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="png" ContentType="image/png"/>
  <Default Extension="jpg" ContentType="image/jpeg"/>
  <Default Extension="svg" ContentType="image/svg+xml"/>
  <Override PartName="/fb3/description.xml" ContentType="application/vnd.fictionbook.fb3-description+xml"/>
  <Override PartName="/fb3/body.xml" ContentType="application/vnd.fictionbook.fb3-body+xml"/>
</Types>
"""

# Root relationships. The Book rel points at description.xml; the metadata/
# thumbnail rel points at the cover image (this is how real LitRes FB3 carry the
# cover — there is no <coverpage> in description). `with_cover=False` drops the
# thumbnail rel entirely (no-cover variant).
def _root_rels(with_cover=True):
    cover = (
        '  <Relationship Id="rIdCover" '
        'Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail" '
        'Target="fb3/img/cover.png"/>\n'
        if with_cover else ""
    )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\n'
        '  <Relationship Id="rIdBook" '
        'Type="http://www.fictionbook.org/FictionBook3/relationships/Book" '
        'Target="fb3/description.xml"/>\n'
        + cover +
        '</Relationships>\n'
    )

DESCR_RELS = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rIdBody" Type="http://www.fictionbook.org/FictionBook3/relationships/body" Target="body.xml"/>
</Relationships>
"""

# body.xml.rels — image rIds. Targets are relative to the body part's dir (fb3/),
# matching real files and exercising zip_join's relative resolution.
BODY_RELS = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="img1" Type="http://www.fictionbook.org/FictionBook3/relationships/image" Target="img/i_001.png"/>
  <Relationship Id="img2" Type="http://www.fictionbook.org/FictionBook3/relationships/image" Target="img/i_002.png"/>
  <Relationship Id="imgsvg" Type="http://www.fictionbook.org/FictionBook3/relationships/image" Target="img/pic.svg"/>
</Relationships>
"""

# description.xml — covers genre/authors/translator/lang/src-lang/annotation/
# sequence/date/document-info. `KEY_FINANCE` subject must be present in the
# genre-map fixture so it resolves to an FB2 genre.
DESCR_XML = """<?xml version="1.0" encoding="UTF-8"?>
<fb3-description xmlns="http://www.fictionbook.org/FictionBook3/description"
                 xmlns:l="http://www.w3.org/1999/xlink"
                 id="DOC-ID-12345" version="1.2">
  <title>
    <main>Синтетическая книга</main>
  </title>
  <fb3-relations>
    <subject link="author">
      <first-name>Иван</first-name>
      <middle-name>Петрович</middle-name>
      <last-name>Сидоров</last-name>
    </subject>
    <subject link="author">
      <first-name>Анна</first-name>
      <last-name>Кузнецова</last-name>
    </subject>
    <subject link="translator">
      <first-name>Сергей</first-name>
      <last-name>Борич</last-name>
    </subject>
  </fb3-relations>
  <fb3-classification>
    <subject>Личные финансы</subject>
  </fb3-classification>
  <annotation>
    <p>Это <em>аннотация</em> к книге.</p>
  </annotation>
  <keywords>финансы, тест</keywords>
  <lang>ru</lang>
  <written>
    <lang>en</lang>
    <date value="2019-03-01">2019</date>
  </written>
  <sequence>
    <title><main>Тестовая серия</main></title>
  </sequence>
  <document-info editor="Редактор Тест" program-used="fb2-to-epub-tests" created="2026-06-28">
  </document-info>
  <paper-publish-info title="Бумажное издание" publisher="Издатель" city="Москва" year="2020">
    <isbn>978-5-00000-000-0</isbn>
  </paper-publish-info>
</fb3-description>
"""

# body.xml — the kitchen sink. `notes_count` controls how many <notes> blocks
# are appended (1 -> single notes body; 2 -> body name="notes" with 2 sections).
def _body_xml(notes_count=2):
    notes_one = """  <notes>
    <title><p>Примечания</p></title>
    <notebody id="n_1">
      <p>Первая сноска.</p>
    </notebody>
  </notes>
"""
    notes_two = """  <notes>
    <notebody id="n_2">
      <p>Вторая сноска (второй блок).</p>
    </notebody>
  </notes>
"""
    notes = notes_one
    if notes_count >= 2:
        notes += notes_two

    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<fb3-body xmlns="http://www.fictionbook.org/FictionBook3/body"\n'
        '          xmlns:l="http://www.w3.org/1999/xlink">\n'
        '  <section id="sec_one">\n'
        '    <title><p>Глава первая</p></title>\n'
        # inline formatting with surrounding text + tails (R1: text/tail keep)
        '    <p id="p_inline">before <em>emp</em> mid <strong>str</strong> '
        '<sub>lo</sub> <sup>hi</sup> <strikethrough>del</strikethrough> after</p>\n'
        # internal link, external link, note (all on one paragraph, with tails)
        '    <p>see <a l:href="#sec_two">section two</a> and '
        '<a l:href="https://example.com/x">site</a> plus<note href="n_1">1</note> done.</p>\n'
        # unordered + ordered lists
        '    <ul>\n'
        '      <li>alpha</li>\n'
        '      <li>beta</li>\n'
        '    </ul>\n'
        '    <ol>\n'
        '      <li>one</li>\n'
        '      <li>two</li>\n'
        '    </ol>\n'
        # table with header + data cells
        '    <table id="tbl1">\n'
        '      <tr><th>H1</th><th>H2</th></tr>\n'
        '      <tr><td>a1</td><td>b1</td></tr>\n'
        '    </table>\n'
        # image paragraph (i_001) ...
        '    <p><img src="img1"/></p>\n'
        # ... and the SAME image reused (dedup: still one <binary>) ...
        '    <p><img src="img1"/></p>\n'
        # ... a distinct second image (i_002) ...
        '    <p><img src="img2"/></p>\n'
        # ... and an SVG image (graceful path)
        '    <p><img src="imgsvg"/></p>\n'
        '  </section>\n'
        # second top-level section, with a NESTED section (multi-section depth)
        '  <section id="sec_two">\n'
        '    <title><p>Глава вторая</p></title>\n'
        '    <p>Текст второй главы.</p>\n'
        '    <section id="sec_two_nested">\n'
        '      <title><p>Подраздел</p></title>\n'
        '      <p>Вложенный текст.</p>\n'
        '    </section>\n'
        '  </section>\n'
        + notes +
        '</fb3-body>\n'
    )


def _zip_bytes(entries):
    """entries: list of (arcname, bytes). Returns the zip as bytes."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data in entries:
            if isinstance(data, str):
                data = data.encode("utf-8")
            zf.writestr(name, data)
    return buf.getvalue()


def _common_entries(with_cover=True, notes_count=2,
                    descr_xml=DESCR_XML, body_xml=None):
    if body_xml is None:
        body_xml = _body_xml(notes_count=notes_count)
    entries = [
        ("[Content_Types].xml", CONTENT_TYPES),
        ("_rels/.rels", _root_rels(with_cover=with_cover)),
        ("fb3/description.xml", descr_xml),
        ("fb3/_rels/description.xml.rels", DESCR_RELS),
        ("fb3/body.xml", body_xml),
        ("fb3/_rels/body.xml.rels", BODY_RELS),
        ("fb3/img/i_001.png", PNG_RED),
        ("fb3/img/i_002.png", PNG_BLUE),
        ("fb3/img/pic.svg", SVG_PIC),
    ]
    if with_cover:
        entries.append(("fb3/img/cover.png", PNG_GREEN))
    return entries


# ---------------------------------------------------------------------------
# Public builders
# ---------------------------------------------------------------------------
def build_full_fb3():
    return _zip_bytes(_common_entries(with_cover=True, notes_count=2))


def build_no_cover_fb3():
    # No thumbnail rel and no cover.png file -> transform emits NO <coverpage>.
    return _zip_bytes(_common_entries(with_cover=False, notes_count=2))


def build_single_notes_fb3():
    return _zip_bytes(_common_entries(with_cover=True, notes_count=1))


def build_broken_body_fb3():
    bad_body = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<fb3-body xmlns="http://www.fictionbook.org/FictionBook3/body">\n'
        '  <section><p>unclosed paragraph\n'
        '</fb3-body>\n'  # <p> and <section> never closed -> ParseError
    )
    return _zip_bytes(_common_entries(with_cover=True, body_xml=bad_body))


def build_broken_descr_fb3():
    bad_descr = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<fb3-description xmlns="http://www.fictionbook.org/FictionBook3/description">\n'
        '  <title><main>oops</main>\n'  # <title> never closed -> ParseError
    )
    return _zip_bytes(_common_entries(with_cover=True, descr_xml=bad_descr))


def build_not_opc_zip():
    # A valid zip, but with NO [Content_Types].xml -> NotFb3 (rc=2).
    return _zip_bytes([
        ("readme.txt", "just a normal zip, not an FB3"),
        ("data/file.bin", b"\x00\x01\x02\x03"),
    ])


def build_plain_file():
    # Not a zip at all -> BadZipFile -> NotFb3 (rc=2).
    return b"this is plainly not a zip archive\n"


# Zip-bomb-like fixture: a valid OPC container (has [Content_Types].xml, so it
# passes the not-FB3 gate) whose single payload entry expands enormously from a
# tiny compressed size. We use ~60 MB of NUL bytes in ONE entry: it deflates to
# a few KB, so uncompressed/compressed >> 200x and the ratio guard trips BEFORE
# the transform reads (and base64-inflates) any entry. 60 MB keeps the fixture
# build itself cheap and OOM-free; the guard must fire on ratio, not on the 300
# MB absolute ceiling (which would force materializing 300 MB here).
BOMB_ENTRY_UNCOMPRESSED = 60 * 1024 * 1024  # 60 MB of zeros in one entry


def build_zip_bomb_fb3():
    """A crafted FB3 whose compression ratio is absurd (zip-bomb-like).

    Built by streaming zeros chunk-by-chunk into a ZIP entry so we never hold the
    full 60 MB in a single Python bytes object. The container still has a valid
    [Content_Types].xml so the input is recognized as an OPC package and the
    transform reaches the zip-bomb guard (rather than bailing as not-FB3).
    """
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        # Minimal OPC marker so it's not rejected as "not an OPC package".
        zf.writestr("[Content_Types].xml", CONTENT_TYPES)
        # The bomb payload: a single highly-compressible entry, written in chunks.
        chunk = b"\x00" * (1024 * 1024)  # 1 MB of zeros, reused
        full_chunks, rem = divmod(BOMB_ENTRY_UNCOMPRESSED, len(chunk))
        with zf.open("fb3/bomb.bin", "w") as dst:
            for _ in range(full_chunks):
                dst.write(chunk)
            if rem:
                dst.write(b"\x00" * rem)
    return buf.getvalue()


# Number of UNIQUE images the full fixture should inline as <binary>:
#   i_001.png (reused twice -> 1), i_002.png (1), pic.svg (1), cover.png (1) = 4
FULL_UNIQUE_BINARIES = 4
# ... and the non-SVG raster subset (what survives if SVG were ever skipped):
FULL_RASTER_BINARIES = 3


_FIXTURE_BUILDERS = {
    "full.fb3": build_full_fb3,
    "no-cover.fb3": build_no_cover_fb3,
    "single-notes.fb3": build_single_notes_fb3,
    "broken-body.fb3": build_broken_body_fb3,
    "broken-descr.fb3": build_broken_descr_fb3,
    "not-opc.zip": build_not_opc_zip,
    "plain.txt": build_plain_file,
    "zip-bomb.fb3": build_zip_bomb_fb3,
}


def write_all(dest_dir):
    """Write every fixture into dest_dir; return {name: abspath}."""
    import os
    os.makedirs(dest_dir, exist_ok=True)
    out = {}
    for name, fn in _FIXTURE_BUILDERS.items():
        path = os.path.join(dest_dir, name)
        with open(path, "wb") as f:
            f.write(fn())
        out[name] = path
    return out


if __name__ == "__main__":
    import os
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
    written = write_all(here)
    for n, p in sorted(written.items()):
        print("%-18s %d bytes" % (n, os.path.getsize(p)))

#!/usr/bin/env python3
"""
Transform an FB3 e-book (OPC/ZIP container) into a single FB2 file, using only
the Python standard library (no lxml).

Pipeline role:
  The watcher detects a `.fb3`, runs this script to produce a temporary `.fb2`,
  then hands that `.fb2` to the EXISTING FB2->EPUB path (Calibre ebook-convert +
  our cover-finder/cover-gen). Everything downstream sees a normal FB2.

Usage:
  fb2-to-epub-fb3.py [--out <path.fb2>] [--genre-map <path.json>]
                     [--quiet] <input.fb3>

  <input.fb3>     positional, absolute path to the FB3 file.
  --out <file>    write FB2 to this file (how the watcher calls it). Without
                  --out, FB2 is written to stdout.
  --genre-map     path to the FB3->FB2 genre JSON. Default: a file named
                  `fb2-to-epub-fb3-genre.json` next to this script.
  --quiet         suppress non-error diagnostics on stderr.

Return codes (the watcher branches on these, like it does for cover-finder):
  0  success (FB2 written).
  2  input does not look like an FB3 (missing [Content_Types].xml /
     description.xml / body.xml) -> watcher logs and skips, does NOT fail.
  1  internal transform error (broken XML, etc.) -> watcher logs FAIL, cleans
     up temp, keeps the batch going.

Diagnostics go to stderr (the watcher redirects 2>>"$LOG_FILE"); stdout carries
only FB2 bytes (or nothing when --out is used).

Semantics mirror the official XSLT (fb3_2_fb2_body.xsl / fb3_2_fb2_descr.xsl):
  - element/attribute mapping per those stylesheets,
  - every copied id is prefixed with `u` (XSLT `id="u{...}"`),
  - namespaces: default FB2 gribuser + prefix `l:` = xlink.
The cover is taken from the OPC package thumbnail (_rels/.rels) when the
description has no <coverpage>, which is the case for real LitRes FB3 files.
"""

import argparse
import base64
import json
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

# ---------------------------------------------------------------------------
# Namespaces
# ---------------------------------------------------------------------------
FB3_BODY = "http://www.fictionbook.org/FictionBook3/body"
FB3_DESCR = "http://www.fictionbook.org/FictionBook3/description"
XLINK = "http://www.w3.org/1999/xlink"
FB2 = "http://www.gribuser.ru/xml/fictionbook/2.0"
OPC_REL = "http://schemas.openxmlformats.org/package/2006/relationships"

REL_TYPE_THUMBNAIL = (
    "http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail"
)
REL_TYPE_BOOK = "http://www.fictionbook.org/FictionBook3/relationships/Book"
REL_TYPE_BODY = "http://www.fictionbook.org/FictionBook3/relationships/body"

# Pre-built Clark-notation tags for the FB3 body namespace (parsing side).
B = "{%s}" % FB3_BODY
D = "{%s}" % FB3_DESCR
L = "{%s}" % XLINK

CONTENT_TYPE_BY_EXT = {
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "png": "image/png",
    "gif": "image/gif",
    "svg": "image/svg+xml",
}

# Zip-bomb guard (FB3 files are downloaded from the net). A real FB3 is tiny:
# total uncompressed is a few MB and the compression ratio sits around 1.3-15x
# (measured: real LitRes books ~0.2 and ~0.8 MB uncompressed, ratio ~1.3-1.5x).
# These ceilings leave a huge margin for genuine books while refusing a crafted
# archive before we read (and base64-inflate) any entry into memory.
MAX_UNCOMPRESSED_BYTES = 300 * 1024 * 1024   # 300 MB total expanded size
MAX_COMPRESSION_RATIO = 200                   # uncompressed / compressed

_QUIET = False


def warn(msg):
    if not _QUIET:
        sys.stderr.write(msg.rstrip("\n") + "\n")


def info(msg):
    if not _QUIET:
        sys.stderr.write(msg.rstrip("\n") + "\n")


class Fb3Error(Exception):
    """Internal transform failure -> rc=1."""


class NotFb3(Exception):
    """Input is not a recognizable FB3 -> rc=2."""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def local(tag):
    """Local name of a Clark-notation tag (strip namespace)."""
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag


def lower_translit(s):
    """Mirror the XSLT `lower` template (RU+latin lowercase)."""
    # Python's str.lower() handles Cyrillic and Latin uniformly; ё/Ё too.
    return (s or "").lower()


def normalize_space(s):
    """XPath normalize-space(): collapse internal whitespace, strip ends."""
    return re.sub(r"\s+", " ", (s or "")).strip()


def text_content(el):
    """XPath string-value of an element: all descendant text concatenated."""
    return "".join(el.itertext())


def zip_join(base_dir, target):
    """Resolve an OPC relationship Target (relative to base_dir) to a zip path.

    Targets in real files are relative (e.g. body.xml.rels lives in fb3/_rels/
    and points to img/i_001.jpg, which is relative to fb3/). OPC says rel
    Targets are relative to the PART's directory, not the _rels directory.
    """
    target = target.lstrip("/")
    if not base_dir:
        path = target
    else:
        path = base_dir.rstrip("/") + "/" + target
    # Normalize ../ and ./ without touching the zip.
    parts = []
    for seg in path.split("/"):
        if seg in ("", "."):
            continue
        if seg == "..":
            if parts:
                parts.pop()
            continue
        parts.append(seg)
    return "/".join(parts)


def parse_rels(zf, rels_path):
    """Parse an OPC .rels file -> {Id: (Target, Type)}. Missing file -> {}."""
    try:
        data = zf.read(rels_path)
    except KeyError:
        return {}
    try:
        root = ET.fromstring(data)
    except ET.ParseError as e:
        raise Fb3Error("bad rels %s: %s" % (rels_path, e))
    out = {}
    for rel in root:
        if local(rel.tag) != "Relationship":
            continue
        rid = rel.get("Id")
        tgt = rel.get("Target")
        typ = rel.get("Type")
        if rid is not None and tgt is not None:
            out[rid] = (tgt, typ)
    return out


# ---------------------------------------------------------------------------
# FB3 package
# ---------------------------------------------------------------------------
class Fb3Package:
    def __init__(self, zf, descr_tree, body_tree, descr_dir, body_dir,
                 root_rels, descr_rels, body_rels):
        self.zf = zf
        self.descr_tree = descr_tree
        self.body_tree = body_tree
        self.descr_dir = descr_dir      # dir of description.xml inside the zip
        self.body_dir = body_dir        # dir of body.xml inside the zip
        self.root_rels = root_rels      # {Id: (Target, Type)} from _rels/.rels
        self.descr_rels = descr_rels    # from description.xml.rels
        self.body_rels = body_rels      # from body.xml.rels


def open_fb3(path):
    """Open an FB3 file and parse its core parts. Raises NotFb3 / Fb3Error."""
    try:
        zf = zipfile.ZipFile(path, "r")
    except (zipfile.BadZipFile, OSError) as e:
        raise NotFb3("not a zip/OPC container: %s" % e)

    names = set(zf.namelist())
    if "[Content_Types].xml" not in names:
        raise NotFb3("no [Content_Types].xml (not an OPC package)")

    # Zip-bomb guard: reject before reading any entry into memory. Trip on either
    # an absurd total expanded size or an extreme compression ratio (a tiny
    # archive that explodes to gigabytes). rc=1 so the watcher logs FAIL & cleans
    # up, rather than letting the process OOM.
    total_uncompressed = sum(zi.file_size for zi in zf.infolist())
    total_compressed = sum(zi.compress_size for zi in zf.infolist())
    if total_uncompressed > MAX_UNCOMPRESSED_BYTES:
        raise Fb3Error(
            "archive too large: uncompressed %d bytes exceeds limit %d"
            % (total_uncompressed, MAX_UNCOMPRESSED_BYTES))
    if total_compressed > 0 and (total_uncompressed / total_compressed) > MAX_COMPRESSION_RATIO:
        raise Fb3Error(
            "suspicious compression ratio: %.1fx exceeds limit %dx"
            % (total_uncompressed / total_compressed, MAX_COMPRESSION_RATIO))

    # Resolve description.xml via the root relationships (Book type), with a
    # sane fallback to the conventional fb3/description.xml.
    root_rels = parse_rels(zf, "_rels/.rels")
    descr_path = None
    for rid, (tgt, typ) in root_rels.items():
        if typ == REL_TYPE_BOOK:
            descr_path = zip_join("", tgt)
            break
    if descr_path is None or descr_path not in names:
        if "fb3/description.xml" in names:
            descr_path = "fb3/description.xml"
        else:
            raise NotFb3("no description.xml (Book relationship missing)")

    descr_dir = os.path.dirname(descr_path)

    # Resolve body.xml via description.xml.rels (body type), fallback to
    # conventional <descr_dir>/body.xml.
    descr_rels_path = zip_join(descr_dir, "_rels/%s.rels" % os.path.basename(descr_path))
    descr_rels = parse_rels(zf, descr_rels_path)
    body_path = None
    for rid, (tgt, typ) in descr_rels.items():
        if typ == REL_TYPE_BODY:
            body_path = zip_join(descr_dir, tgt)
            break
    if body_path is None or body_path not in names:
        cand = zip_join(descr_dir, "body.xml")
        if cand in names:
            body_path = cand
        else:
            raise NotFb3("no body.xml (body relationship missing)")

    body_dir = os.path.dirname(body_path)
    body_rels_path = zip_join(body_dir, "_rels/%s.rels" % os.path.basename(body_path))
    body_rels = parse_rels(zf, body_rels_path)

    try:
        descr_tree = ET.fromstring(zf.read(descr_path))
    except ET.ParseError as e:
        raise Fb3Error("bad description.xml: %s" % e)
    try:
        body_tree = ET.fromstring(zf.read(body_path))
    except ET.ParseError as e:
        raise Fb3Error("bad body.xml: %s" % e)

    info("fb3: descr=%s body=%s thumbnail=%s images=%d"
         % (descr_path, body_path,
            next((zip_join("", t) for (t, ty) in root_rels.values()
                  if ty == REL_TYPE_THUMBNAIL), "-"),
            len(body_rels)))

    return Fb3Package(zf, descr_tree, body_tree, descr_dir, body_dir,
                      root_rels, descr_rels, body_rels)


# ---------------------------------------------------------------------------
# RelResolver: rId -> file -> stable FB2 binary id  (analog of ltr:RplId)
# ---------------------------------------------------------------------------
class RelResolver:
    def __init__(self, pkg):
        self.pkg = pkg
        self._rid_to_binid = {}       # rId -> FB2 binary id (e.g. "i_001.jpg")
        self._used_binids = {}        # binary id -> (zip_path, content_type)
        self._taken_ids = set()       # collision guard for basenames

    def _content_type(self, zip_path):
        ext = zip_path.rsplit(".", 1)[-1].lower() if "." in zip_path else ""
        return CONTENT_TYPE_BY_EXT.get(ext, "application/octet-stream")

    def RplId(self, rid):
        """rId (e.g. 'img2') -> FB2 binary id (basename, uniquified).

        Records that the underlying file must be inlined exactly once. Returns
        None when the rId is unknown or the file is missing (caller drops it).
        """
        if rid is None:
            return None
        if rid in self._rid_to_binid:
            return self._rid_to_binid[rid]
        rel = self.pkg.body_rels.get(rid)
        if rel is None:
            warn("WARN missing-rel rId=%s" % rid)
            return None
        target = rel[0]
        zip_path = zip_join(self.pkg.body_dir, target)
        if zip_path not in self.pkg.zf.namelist():
            warn("WARN missing-image %s (rId=%s)" % (zip_path, rid))
            return None
        binid = os.path.basename(zip_path)
        # Uniquify basename collisions across directories.
        if binid in self._taken_ids and self._used_binids.get(binid, (None,))[0] != zip_path:
            stem, dot, ext = binid.partition(".")
            n = 2
            while ("%s_%d%s%s" % (stem, n, dot, ext)) in self._taken_ids:
                n += 1
            binid = "%s_%d%s%s" % (stem, n, dot, ext)
        self._taken_ids.add(binid)
        self._rid_to_binid[rid] = binid
        self._used_binids[binid] = (zip_path, self._content_type(zip_path))
        return binid

    def register_file(self, zip_path, forced_id=None):
        """Mark a file (e.g. the OPC-thumbnail cover) for inlining.

        Returns the FB2 binary id used. `forced_id` lets the cover claim the
        conventional id 'cover'.
        """
        if zip_path not in self.pkg.zf.namelist():
            return None
        binid = forced_id or os.path.basename(zip_path)
        if binid in self._used_binids and self._used_binids[binid][0] == zip_path:
            return binid
        if binid in self._taken_ids and self._used_binids.get(binid, (None,))[0] != zip_path:
            stem, dot, ext = binid.partition(".")
            n = 2
            while ("%s_%d%s%s" % (stem, n, dot, ext)) in self._taken_ids:
                n += 1
            binid = "%s_%d%s%s" % (stem, n, dot, ext)
        self._taken_ids.add(binid)
        self._used_binids[binid] = (zip_path, self._content_type(zip_path))
        return binid

    def collect_binaries(self):
        """Return [(fb2_id, content_type, base64_text)] for inlined files.

        SVG and any read failure degrade gracefully: the file is skipped with a
        WARN so the rest of the book survives.
        """
        out = []
        for binid, (zip_path, ctype) in self._used_binids.items():
            try:
                raw = self.pkg.zf.read(zip_path)
            except KeyError:
                warn("WARN binary-read-failed %s" % zip_path)
                continue
            b64 = base64.b64encode(raw).decode("ascii")
            out.append(("u" + binid, ctype, b64))
        return out

    def has_binary_for(self, binid):
        return binid in self._used_binids


def rpl_local_href(href, prefix="u"):
    """Mirror ltr:RplLocalHref: internal '#id' -> '#u{id}', external as-is."""
    if href is None:
        return ""
    if href.startswith("#"):
        return "#" + prefix + href[1:]
    return href


# ---------------------------------------------------------------------------
# FB2 element construction helpers
# ---------------------------------------------------------------------------
def E(parent, tag, text=None):
    """Create an FB2 child element (default namespace) under parent."""
    el = ET.SubElement(parent, "{%s}%s" % (FB2, tag))
    if text is not None:
        el.text = text
    return el


def E_root(tag):
    el = ET.Element("{%s}%s" % (FB2, tag))
    return el


def set_xlink(el, attr, value):
    el.set("{%s}%s" % (XLINK, attr), value)


def append_text(parent, last_child, text):
    """Append `text` to the right place: parent.text if no children yet,
    else the tail of the last appended child. This is the core of preserving
    mixed content when wrappers are unwrapped (risk R1)."""
    if not text:
        return last_child
    if last_child is None:
        parent.text = (parent.text or "") + text
    else:
        last_child.tail = (last_child.tail or "") + text
    return last_child


# ---------------------------------------------------------------------------
# BODY mapping  (fb3_2_fb2_body.xsl)
# ---------------------------------------------------------------------------
INLINE_RENAME = {
    "strong": "strong",
    "em": "emphasis",   # the key rename
    "sub": "sub",
    "sup": "sup",
    "strikethrough": "strikethrough",
    "code": "code",     # handled specially inside stanza
}
# Wrappers with no FB2 analog: drop the wrapper, keep the content ("just kill").
KILL_WRAPPERS = {"span", "underline", "spacing", "marker", "paper-page-break"}


class BodyMapper:
    def __init__(self, rel):
        self.rel = rel

    # -- inline content -----------------------------------------------------
    def map_inline_children(self, fb3_el, fb2_parent, in_stanza=False):
        """Map the mixed inline content of fb3_el into fb2_parent, preserving
        text and tails. Handles inline formatting, links, notes, images, and
        unwrapping of kill-wrappers/span."""
        last = append_text(fb2_parent, None, fb3_el.text)
        for child in fb3_el:
            last = self._map_inline_node(child, fb2_parent, last, in_stanza)
        return last

    def _map_inline_node(self, child, fb2_parent, last, in_stanza):
        name = local(child.tag)

        if name in KILL_WRAPPERS or name == "span":
            # Unwrap: splice child's own inline content into the parent, then
            # carry the child's tail.
            last = self.map_inline_children(child, fb2_parent, in_stanza)
            last = append_text(fb2_parent, last, child.tail)
            return last

        if name == "code" and in_stanza:
            # <code> inside a stanza: unwrap.
            last = self.map_inline_children(child, fb2_parent, in_stanza)
            last = append_text(fb2_parent, last, child.tail)
            return last

        if name in INLINE_RENAME:
            el = E(fb2_parent, INLINE_RENAME[name])
            self.map_inline_children(child, el, in_stanza)
            el.tail = child.tail
            return el

        if name == "img":
            el = self._make_image(child, fb2_parent)
            if el is not None:
                el.tail = child.tail
                return el
            # image dropped (missing/SVG-skip): keep tail text on parent.
            return append_text(fb2_parent, last, child.tail)

        if name == "a":
            el = E(fb2_parent, "a")
            href = child.get("{%s}href" % XLINK) or child.get("href")
            set_xlink(el, "href", rpl_local_href(href, "u"))
            self.map_inline_children(child, el, in_stanza)
            el.tail = child.tail
            return el

        if name == "note":
            el = E(fb2_parent, "a")
            set_xlink(el, "href", "#u" + (child.get("href") or ""))
            el.set("type", "note")
            self.map_inline_children(child, el, in_stanza)
            el.tail = child.tail
            return el

        # Unknown inline element: unwrap conservatively (keep text + tail).
        last = self.map_inline_children(child, fb2_parent, in_stanza)
        last = append_text(fb2_parent, last, child.tail)
        return last

    def _make_image(self, fb3_img, fb2_parent):
        src = fb3_img.get("src") or fb3_img.get("{%s}href" % XLINK)
        binid = self.rel.RplId(src)
        if binid is None:
            return None
        el = E(fb2_parent, "image")
        set_xlink(el, "href", "#u" + binid)
        if fb3_img.get("alt"):
            el.set("alt", fb3_img.get("alt"))
        if fb3_img.get("id"):
            # XSLT: id="u{RplId(@id)}" -- @id is a separate id, run through RplId
            # too. For non-rId ids RplId returns None, so fall back to raw id.
            iid = self.rel.RplId(fb3_img.get("id")) or fb3_img.get("id")
            el.set("id", "u" + iid)
        return el

    # -- block content ------------------------------------------------------
    def _is_image_only_p(self, p):
        """XSLT image-paragraph test: exactly one <img>, no other element
        children, empty normalized text."""
        imgs = sum(1 for c in p if local(c.tag) == "img")
        non_imgs = sum(1 for c in p if local(c.tag) != "img")
        txt = normalize_space(text_content(p))
        return imgs == 1 and non_imgs == 0 and len(txt) == 0

    def _div_has_image_p(self, div):
        """XSLT: div (not on-one-page) that contains a <p> with an <img> and
        empty normalized text -> treat as image div (unwrap + empty-line)."""
        for c in div:
            if local(c.tag) == "p":
                has_img = any(local(g.tag) == "img" for g in c)
                if has_img and len(normalize_space(text_content(c))) == 0:
                    return True
        return False

    def map_block_children(self, fb3_parent, fb2_parent):
        """Map block-level children of fb3_parent into fb2_parent."""
        for child in fb3_parent:
            self._map_block_node(child, fb2_parent, parent_name=local(fb3_parent.tag))

    def _map_block_node(self, child, fb2_parent, parent_name):
        name = local(child.tag)

        if name == "title":
            # Inside blockquote -> subtitle; else title.
            tag = "subtitle" if parent_name == "blockquote" else "title"
            el = E(fb2_parent, tag)
            self.map_block_children(child, el)
            return

        if name == "subtitle":
            el = E(fb2_parent, "subtitle")
            if child.get("id"):
                el.set("id", "u" + child.get("id"))
            self.map_block_children(child, el)
            return

        if name == "annotation":
            el = E(fb2_parent, "annotation")
            self.map_block_children(child, el)
            return

        if name == "epigraph":
            el = E(fb2_parent, "epigraph")
            self.map_block_children(child, el)
            return

        if name == "section":
            el = E(fb2_parent, "section")
            if child.get("id"):
                el.set("id", "u" + child.get("id"))
            self.map_block_children(child, el)
            return

        if name == "preamble":
            el = E(fb2_parent, "section")
            self.map_block_children(child, el)
            return

        if name == "p":
            self._map_p(child, fb2_parent, parent_name)
            return

        if name == "br":
            E(fb2_parent, "empty-line")
            return

        if name == "blockquote":
            el = E(fb2_parent, "cite")
            if child.get("id"):
                el.set("id", "u" + child.get("id"))
            self.map_block_children(child, el)
            return

        if name == "div":
            self._map_div(child, fb2_parent)
            return

        if name == "pre":
            cite = E(fb2_parent, "cite")
            p = E(cite, "p")
            code = E(p, "code")
            self.map_inline_children(child, code)
            return

        if name == "poem":
            self._map_poem(child, fb2_parent)
            return

        if name == "stanza":
            self._map_stanza(child, fb2_parent)
            return

        if name == "subscription":
            # Outside poem: unwrap (its children are blocks/inline).
            self.map_block_children(child, fb2_parent)
            return

        if name == "table":
            self._map_table(child, fb2_parent)
            return

        if name == "ul":
            self._map_list(child, fb2_parent, ordered=False)
            return

        if name == "ol":
            self._map_list(child, fb2_parent, ordered=True)
            return

        if name == "code":
            # block-level code outside stanza -> <code> wrapping inline content
            el = E(fb2_parent, "code")
            self.map_inline_children(child, el)
            return

        # Fallback for any other block-ish element: recurse into it so we never
        # silently lose its content.
        self.map_block_children(child, fb2_parent)

    def _map_p(self, p, fb2_parent, parent_name):
        # Image-only paragraph special case.
        if self._is_image_only_p(p) and parent_name != "title":
            for c in p:
                if local(c.tag) == "img":
                    self._make_image(c, fb2_parent)
            if parent_name != "div":
                E(fb2_parent, "empty-line")
            return
        # <p> inside a <title> that is itself inside a <blockquote>: inline only.
        if parent_name == "title":
            # We don't have grandparent here; approximate XSLT by emitting a
            # plain <p>. The common real case (title>p) maps fine as <p>.
            el = E(fb2_parent, "p")
            self.map_inline_children(p, el)
            return
        el = E(fb2_parent, "p")
        if p.get("id"):
            el.set("id", "u" + p.get("id"))
        self.map_inline_children(p, el)

    def _map_div(self, div, fb2_parent):
        on_one_page = div.get("on-one-page")
        is_one_page = on_one_page in ("true", "1")
        if is_one_page:
            self.map_block_children(div, fb2_parent)
            E(fb2_parent, "empty-line")
            return
        if self._div_has_image_p(div):
            self.map_block_children(div, fb2_parent)
            E(fb2_parent, "empty-line")
            return
        cite = E(fb2_parent, "cite")
        if div.get("id"):
            cite.set("id", "u" + div.get("id"))
        self.map_block_children(div, cite)

    def _map_poem(self, poem, fb2_parent):
        el = E(fb2_parent, "poem")
        for child in poem:
            name = local(child.tag)
            if name == "subscription":
                ta = E(el, "text-author")
                self._map_subscription_inline(child, ta)
            else:
                # default poem mode: apply the normal block template
                self._map_block_node(child, el, parent_name="poem")

    def _map_subscription_inline(self, sub, fb2_parent):
        """poem_subscription mode: each p/li -> inline; two-space separators
        between items; <br> dropped."""
        items = [c for c in sub if local(c.tag) in ("p", "li")]
        # ul/ol wrap li; flatten one level for li.
        if not items:
            for c in sub:
                if local(c.tag) in ("ul", "ol"):
                    items.extend(g for g in c if local(g.tag) == "li")
        last = None
        first = True
        for it in items:
            if not first:
                last = append_text(fb2_parent, last, "  ")
            first = False
            last = self.map_inline_children(it, fb2_parent)

    def _map_stanza(self, stanza, fb2_parent):
        el = E(fb2_parent, "stanza")
        for child in stanza:
            name = local(child.tag)
            if name == "p":
                v = E(el, "v")
                self.map_inline_children(child, v)
            elif name == "br":
                continue  # dropped in stanza mode
            elif name in ("title", "subtitle", "epigraph"):
                # stanza may legitimately carry a title/subtitle in FB2.
                self._map_block_node(child, el, parent_name="stanza")
            # other elements ignored within stanza

    def _map_table(self, table, fb2_parent):
        el = E(fb2_parent, "table")
        if table.get("id"):
            el.set("id", "u" + table.get("id"))
        for child in table:
            if local(child.tag) == "tr":
                tr = E(el, "tr")
                for cell in child:
                    cn = local(cell.tag)
                    if cn == "th":
                        th = E(tr, "th")
                        self._map_cell_content(cell, th)
                    elif cn == "td":
                        td = E(tr, "td")
                        for a in ("id", "align", "colspan", "rowspan"):
                            v = cell.get(a)
                            if v is not None:
                                td.set("id" if a == "id" else a,
                                       ("u" + v) if a == "id" else v)
                        self._map_cell_content(cell, td)

    def _map_cell_content(self, cell, fb2_cell):
        """th/td: a single <p> child is unwrapped (XSLT td/p -> apply-templates);
        otherwise map inline content directly."""
        children = list(cell)
        ps = [c for c in children if local(c.tag) == "p"]
        if ps and all(local(c.tag) == "p" for c in children):
            # unwrap each <p> into inline content of the cell, separated by
            # an empty-line between paragraphs (keeps multi-p cells readable).
            for i, p in enumerate(ps):
                self.map_inline_children(p, fb2_cell)
                if i < len(ps) - 1:
                    E(fb2_cell, "empty-line")
        else:
            self.map_inline_children(cell, fb2_cell)

    def _map_list(self, lst, fb2_parent, ordered):
        cite = E(fb2_parent, "cite")
        lis = [c for c in lst if local(c.tag) == "li"]
        if ordered:
            for i, li in enumerate(lis, start=1):
                self._map_li(li, cite, prefix=str(i))
        else:
            prefix = lst.get("type") or "•"
            for li in lis:
                self._map_li(li, cite, prefix=prefix)

    def _map_li(self, li, fb2_parent, prefix):
        p = E(fb2_parent, "p")
        p.text = prefix + " "  # prefix + nbsp, then inline content
        self.map_inline_children(li, p)
        # map_inline_children appended starting at p.text; ensure prefix kept:
        # since p.text already set, append_text(parent, None, ...) concatenates.

    # -- top level ----------------------------------------------------------
    def build_bodies(self, fb3_body):
        """Return (main_body_el, notes_body_el_or_None)."""
        main = E_root("body")
        for child in fb3_body:
            name = local(child.tag)
            if name in ("title", "epigraph", "preamble", "section"):
                self._map_block_node(child, main, parent_name="fb3-body")
            # notes handled separately below

        notes_blocks = [c for c in fb3_body if local(c.tag) == "notes"]
        notes_body = None
        if len(notes_blocks) == 1:
            notes_body = self._map_notes_single(notes_blocks[0])
        elif len(notes_blocks) > 1:
            notes_body = E_root("body")
            notes_body.set("name", "notes")
            for nb in notes_blocks:
                sec = E(notes_body, "section")
                self._map_notes_children(nb, sec)
        return main, notes_body

    def _map_notes_single(self, notes):
        body = E_root("body")
        body.set("name", "notes")
        self._map_notes_children(notes, body)
        return body

    def _map_notes_children(self, notes, fb2_parent):
        """notes mode: title -> title/subtitle; notebody -> section id=u{id}."""
        for child in notes:
            name = local(child.tag)
            if name == "title":
                # notes/title -> title (XSLT `notes` mode keeps title as title)
                el = E(fb2_parent, "title")
                self.map_block_children(child, el)
            elif name == "subtitle":
                el = E(fb2_parent, "subtitle")
                if child.get("id"):
                    el.set("id", "u" + child.get("id"))
                self.map_block_children(child, el)
            elif name == "notebody":
                sec = E(fb2_parent, "section")
                if child.get("id"):
                    sec.set("id", "u" + child.get("id"))
                self.map_block_children(child, sec)
            elif name == "epigraph":
                el = E(fb2_parent, "epigraph")
                self.map_block_children(child, el)


# ---------------------------------------------------------------------------
# DESCRIPTION mapping  (fb3_2_fb2_descr.xsl)
# ---------------------------------------------------------------------------
class DescrMapper:
    def __init__(self, rel, genre_map):
        self.rel = rel
        self.genre_map = genre_map or {}

    def _find(self, parent, name):
        return parent.find("{%s}%s" % (FB3_DESCR, name))

    def _findall(self, parent, name):
        return parent.findall("{%s}%s" % (FB3_DESCR, name))

    def map_inline_descr(self, fb3_el, fb2_parent):
        """Inline content for annotation/history/keywords: p/br/strong/em/a."""
        last = append_text(fb2_parent, None, fb3_el.text)
        for child in fb3_el:
            name = local(child.tag)
            if name == "p":
                el = E(fb2_parent, "p")
                self.map_inline_descr(child, el)
                el.tail = child.tail
                last = el
            elif name == "br":
                el = E(fb2_parent, "empty-line")
                el.tail = child.tail
                last = el
            elif name == "strong":
                el = E(fb2_parent, "strong")
                self.map_inline_descr(child, el)
                el.tail = child.tail
                last = el
            elif name == "em":
                el = E(fb2_parent, "emphasis")
                self.map_inline_descr(child, el)
                el.tail = child.tail
                last = el
            elif name == "a":
                el = E(fb2_parent, "a")
                set_xlink(el, "href", child.get("href") or "")
                self.map_inline_descr(child, el)
                el.tail = child.tail
                last = el
            else:
                last = self.map_inline_descr(child, fb2_parent)
                last = append_text(fb2_parent, last, child.tail)
        return last

    def build_description(self):
        root = self.rel.pkg.descr_tree  # fb3-description element
        descr = E_root("description")

        title_info = E(descr, "title-info")
        self._build_title_info(root, title_info)

        document_info = E(descr, "document-info")
        self._build_document_info(root, document_info)

        # publish-info from paper-publish-info
        ppi = self._find(root, "paper-publish-info")
        if ppi is not None:
            self._build_publish_info(ppi, descr)

        # custom-info: direct custom-info elements + selected blocks
        for ci in self._findall(root, "custom-info"):
            el = E(descr, "custom-info")
            el.set("info-type", ci.get("info-type") or "")
            self.map_inline_descr(ci, el)

        self._build_extra_custom_info(root, descr)

        return descr

    def _build_title_info(self, root, ti):
        # genres
        classification = self._find(root, "fb3-classification")
        genres = []
        if classification is not None:
            for subj in self._findall(classification, "subject"):
                key = lower_translit(normalize_space(text_content(subj)))
                fb2_genre = self.genre_map.get(key)
                if fb2_genre and fb2_genre not in genres:
                    genres.append(fb2_genre)
        for g in genres:
            E(ti, "genre", g)

        # authors
        relations = self._find(root, "fb3-relations")
        authors = []
        translators = []
        if relations is not None:
            for subj in self._findall(relations, "subject"):
                link = subj.get("link")
                if link == "author":
                    authors.append(subj)
                elif link == "translator":
                    translators.append(subj)
        for a in authors:
            self._emit_person(ti, "author", a)
        if not authors:
            anon = E(ti, "author")
            E(anon, "nickname", "Аноним")

        # book-title
        title_el = self._find(root, "title")
        if title_el is not None:
            main = self._find(title_el, "main")
            E(ti, "book-title", (main.text if main is not None else "") or "")

        # annotation
        ann = self._find(root, "annotation")
        if ann is not None:
            el = E(ti, "annotation")
            self.map_inline_descr(ann, el)

        # keywords
        kw = self._find(root, "keywords")
        if kw is not None:
            el = E(ti, "keywords")
            self.map_inline_descr(kw, el)

        # date from written/date
        written = self._find(root, "written")
        if written is not None:
            self._emit_written_date(written, ti)

        # coverpage (rare; OPC-thumbnail path is the real cover source)
        cover = self._find(root, "coverpage")
        if cover is not None:
            href = cover.get("{%s}href" % XLINK) or cover.get("href")
            binid = self.rel.RplId(href) if href else None
            if binid:
                cp = E(ti, "coverpage")
                img = E(cp, "image")
                set_xlink(img, "href", "#u" + binid)

        # lang
        lang = self._find(root, "lang")
        if lang is not None:
            E(ti, "lang", (lang.text or "").strip())

        # src-lang from written/lang
        if written is not None:
            wlang = self._find(written, "lang")
            if wlang is not None and (wlang.text or "").strip():
                E(ti, "src-lang", wlang.text.strip())

        # translators
        for t in translators:
            self._emit_person(ti, "translator", t)

        # sequence (recursive)
        for seq in self._findall(root, "sequence"):
            self._emit_sequence(seq, ti)

    def _emit_person(self, parent, tag, subj):
        el = E(parent, tag)
        fn = self._find(subj, "first-name")
        mn = self._find(subj, "middle-name")
        ln = self._find(subj, "last-name")
        E(el, "first-name", (fn.text if fn is not None else "") or "")
        if mn is not None:
            E(el, "middle-name", (mn.text or ""))
        E(el, "last-name", (ln.text if ln is not None else "") or "")
        if subj.get("id"):
            E(el, "id", subj.get("id"))

    def _emit_written_date(self, written, ti):
        date = self._find(written, "date")
        if date is None:
            return
        value = date.get("value")
        if not value:
            return
        d = E(ti, "date")
        d.set("value", value)
        if date.text and date.text.strip():
            d.text = date.text
        else:
            d.text = value[:4]

    def _emit_sequence(self, seq, parent):
        el = E(parent, "sequence")
        title = self._find(seq, "title")
        name = ""
        if title is not None:
            main = self._find(title, "main")
            if main is not None:
                name = text_content(main)
        el.set("name", name)
        if seq.get("number"):
            el.set("number", seq.get("number"))
        for sub in self._findall(seq, "sequence"):
            self._emit_sequence(sub, el)

    def _build_document_info(self, root, di):
        dinfo = self._find(root, "document-info")
        editor = "Аноним"
        if dinfo is not None and dinfo.get("editor"):
            editor = dinfo.get("editor")
        author = E(di, "author")
        E(author, "nickname", editor)

        if dinfo is not None:
            pu = dinfo.get("program-used")
            if pu:
                E(di, "program-used", pu)
            created = dinfo.get("created") or ""
            y = created[0:4]
            m = created[5:7]
            d = created[8:10]
            date = E(di, "date")
            date.set("value", "%s-%s-%s" % (y, m, d))
            date.text = "%s.%s.%s" % (d, m, y)
            if dinfo.get("src-url"):
                E(di, "src-url", dinfo.get("src-url"))
            if dinfo.get("ocr"):
                E(di, "src-ocr", dinfo.get("ocr"))
        else:
            # still emit a date skeleton so FB2 has document-info/date
            date = E(di, "date")
            date.set("value", "--")
            date.text = ".."

        # id + version from the description root attributes
        E(di, "id", root.get("id") or "")
        E(di, "version", root.get("version") or "")

        # history (sibling of document-info under the root)
        history = self._find(root, "history")
        if history is not None:
            el = E(di, "history")
            self.map_inline_descr(history, el)

    def _build_publish_info(self, ppi, descr):
        pi = E(descr, "publish-info")
        E(pi, "book-name", ppi.get("title") or "")
        if ppi.get("publisher"):
            E(pi, "publisher", ppi.get("publisher"))
        if ppi.get("city"):
            E(pi, "city", ppi.get("city"))
        if ppi.get("year"):
            E(pi, "year", ppi.get("year"))
        isbn = self._find(ppi, "isbn")
        if isbn is not None:
            E(pi, "isbn", text_content(isbn))
        for seq in self._findall(ppi, "sequence"):
            el = E(pi, "sequence")
            el.set("name", text_content(seq))

    def _build_extra_custom_info(self, root, descr):
        """MVP of the XSLT custom-info recursion: flatten selected blocks into
        flat <custom-info info-type="..."> entries. Covers the visible cases;
        deep attribute recursion is intentionally partial (risk R2)."""
        base = "fb3d:fb3-description"

        def emit_block(node):
            if node is None:
                return
            nm = local(node.tag)
            path = "%s/fb3d:%s" % (base, nm)
            # attributes (skip number on sequence, per XSLT)
            for k, v in node.attrib.items():
                kn = local(k)
                if nm == "sequence" and kn == "number":
                    continue
                if not v:
                    continue
                ci = E(descr, "custom-info")
                ci.set("info-type", "%s/@%s" % (path, kn))
                ci.text = v
            # child elements with text (skip main/subject per XSLT)
            for ch in node:
                cn = local(ch.tag)
                if cn in ("main", "subject"):
                    continue
                txt = normalize_space(text_content(ch))
                if txt:
                    ci = E(descr, "custom-info")
                    ci.set("info-type", "%s/fb3d:%s" % (path, cn))
                    ci.text = txt

        # periodical, title, sequence, fb3-classification, written(+country/
        # date-public), translated, copyrights
        for nm in ("periodical", "title"):
            emit_block(self._find(root, nm))
        for seq in self._findall(root, "sequence"):
            emit_block(seq)
        emit_block(self._find(root, "fb3-classification"))
        written = self._find(root, "written")
        if written is not None and (self._find(written, "country") is not None
                                    or self._find(written, "date-public") is not None):
            emit_block(written)
        emit_block(self._find(root, "translated"))
        emit_block(self._find(root, "copyrights"))


# ---------------------------------------------------------------------------
# Cover resolution
# ---------------------------------------------------------------------------
def resolve_cover(pkg, rel, descr):
    """Ensure a cover is present. Priority:
    1. description <coverpage> (already handled in DescrMapper, which inlines
       its image and emits title-info/coverpage).
    2. OPC package thumbnail (_rels/.rels metadata/thumbnail) -> inline as
       binary id 'cover' and emit title-info/coverpage.
    Returns nothing; mutates descr/rel.
    """
    title_info = descr.find("{%s}title-info" % FB2)
    if title_info is None:
        return
    existing_cover = title_info.find("{%s}coverpage" % FB2)
    if existing_cover is not None:
        # description provided the cover; verify its binary will be inlined.
        return

    # OPC thumbnail
    thumb_target = None
    for rid, (tgt, typ) in pkg.root_rels.items():
        if typ == REL_TYPE_THUMBNAIL:
            thumb_target = tgt
            break
    if not thumb_target:
        return
    zip_path = zip_join("", thumb_target)
    if zip_path not in pkg.zf.namelist():
        warn("WARN thumbnail-missing %s" % zip_path)
        return

    # SVG cover: inline as-is per plan (Calibre understands SVG); on failure the
    # downstream cover-gen kicks in. We still inline it here.
    binid = rel.register_file(zip_path, forced_id="cover")
    if binid is None:
        return
    cp = ET.Element("{%s}coverpage" % FB2)
    img = ET.SubElement(cp, "{%s}image" % FB2)
    set_xlink(img, "href", "#u" + binid)
    # Insert coverpage after annotation per FB2 ordering convention; appending
    # at end of title-info is also valid for Calibre. Place after last of
    # book-title/annotation to be safe -> simplest: append to title-info.
    title_info.append(cp)


# ---------------------------------------------------------------------------
# FB2 assembly
# ---------------------------------------------------------------------------
def build_fb2(descr, main_body, notes_body, binaries):
    ET.register_namespace("", FB2)
    ET.register_namespace("l", XLINK)
    root = E_root("FictionBook")
    root.append(descr)
    root.append(main_body)
    if notes_body is not None:
        root.append(notes_body)
    for binid, ctype, b64 in binaries:
        b = ET.SubElement(root, "{%s}binary" % FB2)
        b.set("id", binid)
        b.set("content-type", ctype)
        b.text = b64
    _indent(root)
    xml_bytes = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    return xml_bytes


def _indent(elem, level=0):
    """Light pretty-print, but never reflow elements that carry mixed content
    (text/tail) so inline formatting stays intact."""
    has_mixed = (elem.text and elem.text.strip()) or any(
        (c.tail and c.tail.strip()) for c in elem
    )
    if len(elem) and not has_mixed:
        if not (elem.text and elem.text.strip()):
            elem.text = "\n" + "  " * (level + 1)
        children = list(elem)
        for i, c in enumerate(children):
            _indent(c, level + 1)
            if not (c.tail and c.tail.strip()):
                if i == len(children) - 1:
                    c.tail = "\n" + "  " * level
                else:
                    c.tail = "\n" + "  " * (level + 1)
    # leaf or mixed: leave text/tail as-is


# ---------------------------------------------------------------------------
# Pipeline + CLI
# ---------------------------------------------------------------------------
def transform(path, genre_map):
    pkg = open_fb3(path)
    rel = RelResolver(pkg)

    # description first (so cover from <coverpage> registers before body images
    # is irrelevant for ordering, but keeps title-info coverpage early).
    descr_mapper = DescrMapper(rel, genre_map)
    descr = descr_mapper.build_description()

    # body
    body_mapper = BodyMapper(rel)
    main_body, notes_body = body_mapper.build_bodies(pkg.body_tree)

    # cover (OPC thumbnail fallback)
    resolve_cover(pkg, rel, descr)

    # binaries (all files registered during the steps above)
    binaries = rel.collect_binaries()

    return build_fb2(descr, main_body, notes_body, binaries)


def load_genre_map(arg_path):
    if arg_path:
        path = arg_path
    else:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "fb2-to-epub-fb3-genre.json")
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        warn("WARN genre-map unavailable (%s): genres will be skipped" % e)
        return {}


def main(argv):
    global _QUIET
    ap = argparse.ArgumentParser(
        prog="fb2-to-epub-fb3.py",
        description="Transform an FB3 file into an FB2 file (stdlib only).")
    ap.add_argument("input", help="path to the input .fb3 file")
    ap.add_argument("--out", help="write FB2 to this path (default: stdout)")
    ap.add_argument("--genre-map", help="path to fb2-to-epub-fb3-genre.json")
    ap.add_argument("--quiet", action="store_true",
                    help="suppress non-error diagnostics")
    args = ap.parse_args(argv)
    _QUIET = args.quiet

    if not os.path.isfile(args.input):
        sys.stderr.write("fb2-to-epub-fb3: no such file: %s\n" % args.input)
        return 2

    genre_map = load_genre_map(args.genre_map)

    try:
        fb2_bytes = transform(args.input, genre_map)
    except NotFb3 as e:
        sys.stderr.write("fb2-to-epub-fb3: not an FB3: %s\n" % e)
        return 2
    except Fb3Error as e:
        sys.stderr.write("fb2-to-epub-fb3: transform error: %s\n" % e)
        return 1
    except Exception as e:  # defensive: any unexpected failure -> rc=1
        sys.stderr.write("fb2-to-epub-fb3: unexpected error: %s\n" % e)
        return 1

    if args.out:
        try:
            with open(args.out, "wb") as f:
                f.write(fb2_bytes)
        except OSError as e:
            sys.stderr.write("fb2-to-epub-fb3: cannot write %s: %s\n"
                             % (args.out, e))
            return 1
    else:
        sys.stdout.buffer.write(fb2_bytes)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

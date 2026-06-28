// CoverGenerator.swift — NATIVE fallback book-cover renderer (1200×1800 PNG).
//
// Why this exists
// ---------------
// When no cover is found online, fb2-to-epub falls back to a typographic cover
// built from one of 4 approved SVG templates in design/cover-templates/. The
// reference logic is the Python prototype bin/fb2-to-epub-cover-gen.py (which
// uses cairosvg + PIL). We do NOT want to depend on python/cairo on the user's
// Mac, so this module renders the SAME templates NATIVELY through an offscreen
// WKWebView: a real browser engine + macOS system fonts paint the Cyrillic
// typography pixel-faithfully, and we measure text width via the DOM
// (getComputedTextLength()) — more accurate than PIL's conservative estimate.
//
// How it works
// ------------
// 1. The 4 tokenized templates (*.tok.svg) ship in the bundle at
//    Contents/Resources/cover-templates/. Each text zone is wrapped in BLOCK
//    marker comments carrying layout metadata, e.g.
//        <!--BLOCK:TITLE cx=600 baseline=860 ceil=480 base=166 min=82 ...-->
//        <text ...>__TITLE__</text>
//        <!--/BLOCK:TITLE-->
//    The original <text> inside is just a human-readable preview of the default.
// 2. We load the chosen template, embed it inside an HTML page together with a
//    <script> that re-implements the prototype's fit rules (shrink the type and/
//    or wrap to 2–3 lines so the title never overflows the safe area and is
//    never clipped) — but measures with the DOM instead of PIL. The script
//    reads the BLOCK metadata, builds a fresh <text>/<g> block (correct size, N
//    lines, y-coords, letter-spacing) and replaces everything between markers.
// 3. After the navigation finishes we run the fit (evaluateJavaScript), then
//    takeSnapshot at exactly 1200×1800 → NSImage → PNG Data.
//
// Fonts: only macOS system fonts proven to render Cyrillic correctly are used
// (see .patches/012): Hoefler Text, Georgia italic, Cochin, Gill Sans,
// Baskerville, Helvetica Neue. font-family always carries a fallback stack.
//
// This file is STEP 1 (renderer + test harness). Wiring it into the cover-pick
// window is a separate step.

import Foundation
import AppKit
import WebKit

/// Renders a fallback typographic book cover (1200×1800 PNG) from one of the 4
/// approved SVG templates by substituting author + title and fitting the text.
///
/// Webview rendering is asynchronous, so the generator holds a strong reference
/// to its WKWebView + navigation delegate for the lifetime of a render and only
/// releases them once the snapshot (or failure) is delivered.
final class CoverGenerator: NSObject {

    /// The fixed cover canvas (portrait 2:3), matching the templates' viewBox.
    static let canvasWidth: CGFloat = 1200
    static let canvasHeight: CGFloat = 1800

    // Strong refs kept alive for the duration of one async render.
    private var webView: WKWebView?
    private var navDelegate: NavDelegate?

    /// Render a cover for `template` (1...4). Returns PNG `Data`, or nil on any
    /// failure (unknown template, missing resource, webview/snapshot error).
    ///
    /// Must be called on the main thread (WKWebView is main-thread only).
    @MainActor
    func render(author: String, title: String, template: Int) async -> Data? {
        guard (1...4).contains(template) else {
            NSLog("CoverGenerator: template %d out of range (1...4)", template)
            return nil
        }
        guard let svg = Self.loadTemplateSVG(template: template) else {
            NSLog("CoverGenerator: could not load template %d from bundle", template)
            return nil
        }

        let html = Self.buildHTML(svg: svg, author: author, title: title)

        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let config = WKWebViewConfiguration()
            let frame = NSRect(x: 0, y: 0, width: Self.canvasWidth, height: Self.canvasHeight)
            let web = WKWebView(frame: frame, configuration: config)
            // Opaque white backing is irrelevant — every template paints a full
            // background rect — but set the frame precisely so the snapshot is 1:1.
            web.setValue(false, forKey: "drawsBackground") // honour SVG bg, no white flash

            // Deliver the result at most once, then drop the webview + delegate.
            var finished = false
            let finish: (Data?) -> Void = { [weak self] data in
                guard !finished else { return }
                finished = true
                self?.webView = nil
                self?.navDelegate = nil
                continuation.resume(returning: data)
            }

            let delegate = NavDelegate(onFinish: { [weak web] in
                guard let web = web else { finish(nil); return }
                Self.runFitThenSnapshot(web: web, finish: finish)
            }, onFail: { err in
                NSLog("CoverGenerator: navigation failed: %@", String(describing: err))
                finish(nil)
            })

            self.webView = web
            self.navDelegate = delegate
            web.navigationDelegate = delegate

            // baseURL nil is fine: everything (SVG, fonts via system, script) is inline.
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    // MARK: - Fit + snapshot (after navigation finished)

    @MainActor
    private static func runFitThenSnapshot(web: WKWebView, finish: @escaping (Data?) -> Void) {
        // Run the JS fit. It returns a short status string ("ok") on success.
        web.evaluateJavaScript("__fb2FitCover();") { _, err in
            if let err = err {
                NSLog("CoverGenerator: fit JS error: %@", String(describing: err))
                // Still try to snapshot — the SVG preview text would render unfitted,
                // but a blank/error is worse. Proceed to snapshot regardless.
            }
            // Give the layout/paint one runloop turn to settle before snapshotting.
            DispatchQueue.main.async {
                let cfg = WKSnapshotConfiguration()
                cfg.rect = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
                // Force the output bitmap to exactly 1200×1800 device pixels regardless
                // of the screen's backing scale (snapshotWidth is in points; the image
                // we then re-encode at the canvas size).
                cfg.snapshotWidth = NSNumber(value: Double(canvasWidth))
                web.takeSnapshot(with: cfg) { image, snapErr in
                    if let snapErr = snapErr {
                        NSLog("CoverGenerator: takeSnapshot error: %@", String(describing: snapErr))
                        finish(nil)
                        return
                    }
                    guard let image = image else {
                        NSLog("CoverGenerator: takeSnapshot returned no image")
                        finish(nil)
                        return
                    }
                    finish(pngData(from: image))
                }
            }
        }
    }

    /// Encode an NSImage to PNG at exactly canvasWidth×canvasHeight pixels.
    static func pngData(from image: NSImage) -> Data? {
        let w = Int(canvasWidth)
        let h = Int(canvasHeight)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            NSLog("CoverGenerator: failed to allocate bitmap rep")
            return nil
        }
        rep.size = NSSize(width: w, height: h)
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSLog("CoverGenerator: failed to make graphics context")
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(
            in: NSRect(x: 0, y: 0, width: w, height: h),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Template loading

    static let templateFiles: [Int: String] = [
        1: "tmpl-1-minimal.tok.svg",
        2: "tmpl-2-classic.tok.svg",
        3: "tmpl-3-modern.tok.svg",
        4: "tmpl-4-dark.tok.svg",
    ]

    /// Per-template footer/label defaults — kept identical to the approved SVGs
    /// and to the Python prototype (LABEL_DEFAULTS / FOOTER_DEFAULTS).
    static let labelDefaults: [Int: String] = [1: "РОМАН", 2: "КЛАССИКА", 3: "РОМАН", 4: "РОМАН"]
    static let footerDefaults: [Int: String] = [2: "КЛАССИКА"]

    /// Read a tokenized template SVG from Contents/Resources/cover-templates/.
    /// Honours FB2_COVER_TEMPLATES_DIR for tests run outside a bundle.
    static func loadTemplateSVG(template: Int) -> String? {
        guard let file = templateFiles[template] else { return nil }
        let dir = templatesDir()
        let path = (dir as NSString).appendingPathComponent(file)
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    static func templatesDir() -> String {
        if let override = ProcessInfo.processInfo.environment["FB2_COVER_TEMPLATES_DIR"],
           !override.isEmpty {
            return override
        }
        if let res = Bundle.main.resourcePath {
            return (res as NSString).appendingPathComponent("cover-templates")
        }
        return "cover-templates"
    }

    // MARK: - HTML assembly

    /// Build the offscreen HTML page: the inline SVG (with its BLOCK markers and
    /// preview text intact) + the JS fit engine. author/title/label/footer are
    /// passed to JS as JSON-escaped string literals so any quotes/specials are safe.
    static func buildHTML(svg: String, author: String, title: String) -> String {
        // The template id is encoded only via its content; label/footer come from
        // the per-template defaults resolved here (matching the prototype CLI).
        // We detect the template from a marker substring to pick the right label.
        let label = labelFor(svg: svg)
        let footer = footerFor(svg: svg)

        let svgJS = jsString(svg)
        let authorJS = jsString(author)
        let titleJS = jsString(title)
        let labelJS = jsString(label ?? "")
        let footerJS = jsString(footer ?? "")

        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
          html,body{margin:0;padding:0;background:transparent;}
          #stage{width:1200px;height:1800px;}
          #stage svg{display:block;width:1200px;height:1800px;}
        </style>
        </head>
        <body>
        <div id="stage"></div>
        <script>
        \(fitScript)
        // --- inputs from Swift (JSON-escaped string literals) ---
        var __SVG__   = \(svgJS);
        var __AUTHOR__name = \(authorJS);
        var __TITLE__name  = \(titleJS);
        var __LABEL__name  = \(labelJS);
        var __FOOTER__name = \(footerJS);
        // Fill once on load so a snapshot taken before __fb2FitCover() still shows
        // fitted text (defensive; Swift always calls __fb2FitCover explicitly).
        try { __fb2FitCover(); } catch (e) { /* reported via return value path */ }
        </script>
        </body></html>
        """
    }

    /// Which top label this template uses (РОМАН / КЛАССИКА). The classic
    /// template (id 2) is the only one with a decorative FOOTER signature.
    static func labelFor(svg: String) -> String? {
        if svg.contains("классика") || svg.contains("Классика") { return labelDefaults[2] }
        if svg.contains("модерн")   || svg.contains("Модерн")   { return labelDefaults[3] }
        if svg.contains("тёмный")   || svg.contains("Тёмный")   { return labelDefaults[4] }
        return labelDefaults[1]
    }

    static func footerFor(svg: String) -> String? {
        if svg.contains("__FOOTER__") { return footerDefaults[2] }
        return nil
    }

    /// JSON-encode a string into a safe JS string literal (with surrounding quotes).
    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: []))
            ?? Data("[\"\"]".utf8)
        var json = String(data: data, encoding: .utf8) ?? "[\"\"]"
        // strip the wrapping [ ] of the single-element array → leaves the quoted literal
        if json.hasPrefix("[") { json.removeFirst() }
        if json.hasSuffix("]") { json.removeLast() }
        // also escape </script and U+2028/2029 which JSON leaves raw but break inline JS
        json = json
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return json.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - JS fit engine

extension CoverGenerator {

    /// The in-page fit engine. It is a faithful port of the Python prototype
    /// (bin/fb2-to-epub-cover-gen.py) — same BLOCK markers, same fit rules
    /// (centered title hangs on a fixed last-line baseline and grows upward;
    /// single-line author shrinks letter-spacing then size then wraps to 2 lines;
    /// modern UPPERCASE stack stays clear of the diagonal; author plate width =
    /// text + 2*pad) — but it measures text with the DOM (getComputedTextLength)
    /// instead of PIL, then string-builds the final SVG and injects it.
    ///
    /// Entry point: window.__fb2FitCover() — fills #stage with the fitted SVG and
    /// returns "ok" (or "err:<msg>"). Inputs are read from globals __SVG__,
    /// __AUTHOR__name, __TITLE__name, __LABEL__name, __FOOTER__name.
    static let fitScript: String = #"""
    (function () {
      // ---- XML escaping (matches Python html.escape(quote=True)) ----
      function esc(s) {
        return String(s)
          .replace(/&/g, "&amp;")
          .replace(/</g, "&lt;")
          .replace(/>/g, "&gt;")
          .replace(/"/g, "&quot;")
          .replace(/'/g, "&#x27;");
      }

      // ---- numeric coercion with default (mirrors _num) ----
      function num(meta, key, def) {
        if (!(key in meta)) {
          if (def === undefined) throw new Error("missing numeric meta key: " + key);
          return def;
        }
        return parseFloat(meta[key]);
      }

      // ---- parse `key=value` tokens from a BLOCK marker (mirrors _parse_meta) ----
      // Values may contain spaces/commas (font-family, font paths), so split on the
      // NEXT ` key=` boundary, not on whitespace. Keys are [A-Za-z_][A-Za-z0-9_-]*.
      function parseMeta(metaText) {
        metaText = metaText.replace(/\s+/g, " ").trim();
        var out = {};
        var re = /([A-Za-z_][A-Za-z0-9_\-]*)=/g;
        var keys = [];
        var m;
        while ((m = re.exec(metaText)) !== null) {
          keys.push({ key: m[1], start: m.index + m[0].length, kstart: m.index });
        }
        for (var i = 0; i < keys.length; i++) {
          var start = keys[i].start;
          var end = (i + 1 < keys.length) ? keys[i + 1].kstart : metaText.length;
          out[keys[i].key] = metaText.slice(start, end).trim();
        }
        return out;
      }

      // ---- DOM text measurement (replaces PIL text_width) ----
      // A hidden <text> in the live SVG; getComputedTextLength() returns the SAME
      // advance width WebKit paints, including letter-spacing — so this is exact,
      // not a conservative estimate. Spaces count as glyphs (as in SVG/cairosvg).
      var _svgNS = "http://www.w3.org/2000/svg";
      var _measSVG = null, _measText = null;
      function ensureMeasurer() {
        if (_measSVG) return;
        _measSVG = document.createElementNS(_svgNS, "svg");
        _measSVG.setAttribute("width", "1200");
        _measSVG.setAttribute("height", "1800");
        _measSVG.style.position = "absolute";
        _measSVG.style.left = "-99999px";
        _measSVG.style.top = "0";
        _measSVG.style.visibility = "hidden";
        _measText = document.createElementNS(_svgNS, "text");
        _measSVG.appendChild(_measText);
        document.body.appendChild(_measSVG);
      }
      // opts: {family, size, ls, style, weight}
      function textWidth(s, opts) {
        if (!s) return 0;
        ensureMeasurer();
        _measText.setAttribute("font-family", opts.family);
        _measText.setAttribute("font-size", String(opts.size));
        if (opts.ls) _measText.setAttribute("letter-spacing", String(opts.ls));
        else _measText.removeAttribute("letter-spacing");
        if (opts.style === "italic") _measText.setAttribute("font-style", "italic");
        else _measText.removeAttribute("font-style");
        if (opts.weight) _measText.setAttribute("font-weight", opts.weight);
        else _measText.removeAttribute("font-weight");
        _measText.textContent = s;
        return _measText.getComputedTextLength();
      }

      // ---- greedy word-wrap into <= maxLines so each line width <= safe ----
      // (mirrors wrap_to_lines) Returns array of lines, or null if it doesn't fit.
      function wrapToLines(words, maxLines, safe, opts) {
        var lines = [];
        var cur = "";
        for (var i = 0; i < words.length; i++) {
          var w = words[i];
          var trial = cur ? (cur + " " + w) : w;
          if (textWidth(trial, opts) <= safe) {
            cur = trial;
          } else {
            if (cur) lines.push(cur);
            cur = w;
            if (textWidth(cur, opts) > safe) return null;       // lone word too wide
            if (lines.length >= maxLines) return null;
          }
        }
        if (cur) lines.push(cur);
        if (lines.length > maxLines) return null;
        return lines.length ? lines : [""];
      }

      // inclusive float range stepping by step (step<0 descending) — mirrors _frange
      function frange(start, stop, step) {
        var vals = [], v = start;
        if (step < 0) { while (v >= stop - 1e-9) { vals.push(Math.round(v * 1000) / 1000); v += step; } }
        else          { while (v <= stop + 1e-9) { vals.push(Math.round(v * 1000) / 1000); v += step; } }
        return vals;
      }

      // ===================== centered title (templates 1, 2, 4) =====================
      // Faithful port of build_centered_title: largest size (base->floor, step -2)
      // with fewest lines (1..3) fitting width (safe) AND height (top stays >= ceil).
      // Block hangs on a FIXED last-line baseline and grows upward; leading is
      // proportional to size; never clips.
      function buildCenteredTitle(text, meta) {
        var cx = num(meta, "cx");
        var baseline = num(meta, "baseline");
        var ceil = num(meta, "ceil");
        var base = Math.round(num(meta, "base"));
        var floor = Math.round(num(meta, "min"));
        var safe = num(meta, "safe");
        var fill = meta["fill"] || "#000000";
        var family = meta["font-family"];
        var leading = num(meta, "leading", 1.16);
        var style = meta["style"] || "";
        var words = text.split(/\s+/).filter(Boolean);
        var opts = { family: family, size: base, ls: 0, style: style };

        function fitsVertically(nLines, size) {
          var step = size * leading;
          var topBaseline = baseline - step * (nLines - 1);
          var topEdge = topBaseline - size * 0.72; // cap-height of top line above baseline
          return topEdge >= ceil;
        }

        var chosenSize = floor, chosenLines = [text], found = false;
        for (var size = base; size >= floor; size -= 2) {
          opts.size = size;
          var best = null;
          var ml = [1, 2, 3];
          for (var k = 0; k < ml.length; k++) {
            var lines = wrapToLines(words, ml[k], safe, opts);
            if (lines !== null && fitsVertically(lines.length, size)) { best = lines; break; }
          }
          if (best !== null) { chosenSize = size; chosenLines = best; found = true; break; }
        }
        if (!found) {
          opts.size = floor;
          var lines2 = wrapToLines(words, 3, safe, opts);
          if (lines2 === null) lines2 = (words.length > 3) ? words.slice(0, 3) : words;
          chosenSize = floor; chosenLines = lines2;
        }

        var step = chosenSize * leading;
        var n = chosenLines.length;
        var firstBaseline = baseline - step * (n - 1);
        var styleAttr = (style === "italic") ? ' font-style="italic"' : "";
        var out = [];
        for (var i = 0; i < n; i++) {
          var y = firstBaseline + i * step;
          out.push('<text x="' + cx + '" y="' + fmt(y) + '" text-anchor="middle" ' +
            'font-family="' + family + '" font-size="' + chosenSize + '"' + styleAttr +
            ' fill="' + fill + '">' + esc(chosenLines[i]) + '</text>');
        }
        return out.join("\n  ");
      }

      // ===================== single-line author (templates 1, 2, 4) =====================
      // Faithful port of build_author: try base size shrinking ls (ls->lsmin),
      // then shrink size (at lsmin) to floor, then 2 balanced lines, else best effort.
      function buildAuthor(text, meta) {
        var cx = num(meta, "cx");
        var y = num(meta, "y");
        var base = Math.round(num(meta, "base"));
        var floor = Math.round(num(meta, "min"));
        var ls = num(meta, "ls", 0);
        var lsmin = num(meta, "lsmin", 0);
        var safe = num(meta, "safe");
        var fill = meta["fill"] || "#000000";
        var family = meta["font-family"];
        var upper = (meta["upper"] || "0") === "1";
        var leading = num(meta, "leading", 1.12);
        var s = upper ? text.toUpperCase() : text;
        var opts = { family: family, size: base, ls: ls };

        // 1) base size, shrinking letter-spacing
        var lsList = frange(ls, lsmin, -1);
        for (var a = 0; a < lsList.length; a++) {
          opts.size = base; opts.ls = lsList[a];
          if (textWidth(s, opts) <= safe) return authorLine(s, cx, y, base, lsList[a], family, fill);
        }
        // 2) shrink size (at lsmin) to floor
        for (var size = base; size >= floor; size -= 2) {
          opts.size = size; opts.ls = lsmin;
          if (textWidth(s, opts) <= safe) return authorLine(s, cx, y, size, lsmin, family, fill);
        }
        // 3) two balanced lines at floor
        var words = s.split(/\s+/).filter(Boolean);
        if (words.length >= 2) {
          var lines = splitTwo(words, floor, lsmin, safe, family);
          var step = floor * leading;
          var y0 = y - step / 2;
          var out = [];
          for (var i = 0; i < lines.length; i++) out.push(authorLine(lines[i], cx, y0 + i * step, floor, lsmin, family, fill));
          return out.join("\n  ");
        }
        // 4) single very-long token: best effort, no clip
        return authorLine(s, cx, y, floor, lsmin, family, fill);
      }

      function authorLine(s, cx, y, size, ls, family, fill) {
        var lsAttr = ls ? (' letter-spacing="' + fmt(ls) + '"') : "";
        return '<text x="' + cx + '" y="' + fmt(y) + '" text-anchor="middle" font-family="' +
          family + '" font-size="' + size + '"' + lsAttr + ' fill="' + fill + '">' + esc(s) + '</text>';
      }

      // split words into two lines balancing widths (mirrors _split_two)
      function splitTwo(words, size, ls, safe, family) {
        var opts = { family: family, size: size, ls: ls };
        var best = null, bestDiff = null;
        for (var cut = 1; cut < words.length; cut++) {
          var a = words.slice(0, cut).join(" ");
          var b = words.slice(cut).join(" ");
          var wa = textWidth(a, opts), wb = textWidth(b, opts);
          var diff = Math.abs(wa - wb) + Math.max(0, wa - safe) * 10 + Math.max(0, wb - safe) * 10;
          if (bestDiff === null || diff < bestDiff) { bestDiff = diff; best = [a, b]; }
        }
        return best;
      }

      // ===================== modern stacked title (template 3) =====================
      // Faithful port of build_title_stack: UPPERCASE, left-anchored, kept clear of
      // the slanted diagonal y = diag_b - diag_k*x. Largest size whose words wrap to
      // safe width and whose lowest line clears the diagonal (clearance = real
      // constraint). Last line accent only if it clears the diagonal (stays on light).
      function buildTitleStack(text, meta) {
        var x = num(meta, "x");
        var ytop = num(meta, "ytop");
        var diagB = num(meta, "diag_b");
        var diagK = num(meta, "diag_k");
        var clear = num(meta, "clear", 60);
        var base = Math.round(num(meta, "base"));
        var floor = Math.round(num(meta, "min"));
        var ls = num(meta, "ls", 0);
        var safe = num(meta, "safe");
        var fill = meta["fill"] || "#1D1D1D";
        var accent = meta["accent"] || fill;
        var family = meta["font-family"];
        var leading = num(meta, "leading", 0.95);
        var s = text.toUpperCase();
        var words = s.split(/\s+/).filter(Boolean);
        var opts = { family: family, size: base, ls: ls, weight: "bold" };

        function diagY(xx) { return diagB - diagK * xx; }

        function stackClears(lines, size) {
          opts.size = size;
          var step = size * leading;
          for (var i = 0; i < lines.length; i++) {
            var baseline = ytop + i * step;
            var bottom = baseline + size * 0.04; // caps sit ~0.04*size below baseline
            var w = textWidth(lines[i], opts);
            var xRight = x + w;
            if (bottom > diagY(xRight) - clear) return false;
          }
          return true;
        }

        var chosenSize = floor, chosenLines = [s], found = false;
        for (var size = base; size >= floor; size -= 2) {
          opts.size = size;
          var ml = [1, 2, 3, 4];
          for (var k = 0; k < ml.length; k++) {
            var lines = wrapToLines(words, ml[k], safe, opts);
            if (lines === null) continue;
            if (stackClears(lines, size)) { chosenSize = size; chosenLines = lines; found = true; break; }
          }
          if (found) break;
        }
        if (!found) {
          opts.size = floor;
          var lines3 = wrapToLines(words, 4, safe, opts);
          if (lines3 === null) lines3 = words;
          chosenSize = floor; chosenLines = lines3;
        }

        var step = chosenSize * leading;
        var n = chosenLines.length;
        var lsAttr = ls ? (' letter-spacing="' + fmt(ls) + '"') : "";
        opts.size = chosenSize;
        var out = [];
        for (var i = 0; i < n; i++) {
          var y = ytop + i * step;
          var onLight = (y + chosenSize * 0.04) <= (diagY(x + textWidth(chosenLines[i], opts)) - clear);
          var col = (i === n - 1 && onLight) ? accent : fill;
          out.push('<text x="' + x + '" y="' + fmt(y) + '" font-family="' + family +
            '" font-weight="bold" font-size="' + chosenSize + '"' + lsAttr +
            ' fill="' + col + '">' + esc(chosenLines[i]) + '</text>');
        }
        return out.join("\n    ");
      }

      // ===================== modern author plate (template 3) =====================
      // Faithful port of build_author_plate: plate width = text width + 2*pad,
      // shrink size until it fits safemax; baseline vertically centered in plate.
      function buildAuthorPlate(text, meta) {
        var px = num(meta, "px");
        var py = num(meta, "py");
        var ph = num(meta, "ph");
        var pad = num(meta, "pad");
        var base = Math.round(num(meta, "base"));
        var floor = Math.round(num(meta, "min"));
        var ls = num(meta, "ls", 0);
        var safemax = num(meta, "safemax");
        var platefill = meta["platefill"] || "#FFFFFF";
        var textfill = meta["textfill"] || "#000000";
        var family = meta["font-family"];
        var upper = (meta["upper"] || "0") === "1";
        var s = upper ? text.toUpperCase() : text;
        var opts = { family: family, size: base, ls: ls, weight: "bold" };

        var size = floor;
        var picked = false;
        for (var sz = base; sz >= floor; sz -= 2) {
          opts.size = sz;
          var w = textWidth(s, opts);
          if (w + 2 * pad <= safemax) { size = sz; picked = true; break; }
        }
        if (!picked) size = floor;

        opts.size = size;
        var tw = textWidth(s, opts);
        var plateW = tw + 2 * pad;
        var textX = px + pad;
        var baseline = py + ph / 2 + size * 0.34;
        var lsAttr = ls ? (' letter-spacing="' + fmt(ls) + '"') : "";
        return '<rect x="' + px + '" y="' + py + '" width="' + fmt(plateW) + '" height="' + ph +
          '" fill="' + platefill + '"/>\n    ' +
          '<text x="' + fmt(textX) + '" y="' + fmt(baseline) + '" font-family="' + family +
          '" font-weight="bold" font-size="' + size + '"' + lsAttr + ' fill="' + textfill +
          '">' + esc(s) + '</text>';
      }

      // tidy number formatting (avoid 12.000000001) — mirrors %g enough for our use
      function fmt(v) {
        var r = Math.round(v * 1000) / 1000;
        return String(r);
      }

      // ===================== template assembly =====================
      // Find BLOCK markers, replace their bodies (mirrors fill_template + _BLOCK_RE).
      function fillTemplate(svg, author, title, label, footer) {
        var blockRe = /<!--BLOCK:([A-Z_]+)([\s\S]*?)-->([\s\S]*?)<!--\/BLOCK:\1-->/g;
        svg = svg.replace(blockRe, function (whole, kind, metaText, body) {
          var meta = parseMeta(metaText);
          if (kind === "TITLE")        return buildCenteredTitle(title, meta);
          if (kind === "AUTHOR")       return buildAuthor(author, meta);
          if (kind === "TITLE_STACK")  return buildTitleStack(title, meta);
          if (kind === "AUTHOR_PLATE") return buildAuthorPlate(author, meta);
          return whole; // unknown block: leave untouched
        });

        // Simple fixed-size placeholders (short labels/footers).
        svg = svg.split("__LABEL__").join(label != null ? esc(label) : "");
        svg = svg.split("__FOOTER__").join(footer != null ? esc(footer) : "");
        // Any leftover preview placeholders (none should remain inside blocks).
        svg = svg.split("__TITLE_LINE__").join("");
        svg = svg.split("__TITLE__").join(esc(title));
        svg = svg.split("__AUTHOR__").join(esc(author));
        return svg;
      }

      // Public entry point.
      window.__fb2FitCover = function () {
        try {
          var filled = fillTemplate(__SVG__, __AUTHOR__name, __TITLE__name,
                                    __LABEL__name, __FOOTER__name);
          document.getElementById("stage").innerHTML = filled;
          return "ok";
        } catch (e) {
          return "err:" + (e && e.message ? e.message : String(e));
        }
      };
    })();
    """#
}

// MARK: - Navigation delegate

private final class NavDelegate: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    let onFail: (Error?) -> Void
    init(onFinish: @escaping () -> Void, onFail: @escaping (Error?) -> Void) {
        self.onFinish = onFinish
        self.onFail = onFail
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFail(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFail(error)
    }
}

import SwiftUI
import WebKit
import AppKit

private let previewHoverMessageHandlerName = "ecrivissePreviewHover"

struct MarkdownWebPreviewView: NSViewRepresentable {
    let markdown: String
    let previewFont: PreviewFontOption
    let editorFollowRatio: Double
    let editorFollowEventID: Int
    var onHorizontalSwipe: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SwipeAwareWebView {
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.addUserScript(
            WKUserScript(
                source: MarkdownWebRenderer.previewInteractionScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        let weakHandler = WeakScriptMessageHandler(delegate: context.coordinator)
        userContentController.add(weakHandler, name: previewHoverMessageHandlerName)
        config.userContentController = userContentController

        let webView = SwipeAwareWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.onHorizontalSwipe = onHorizontalSwipe
        webView.shouldHandleHorizontalSwipe = { [weak coordinator = context.coordinator] in
            !(coordinator?.isHoveringScrollableCodeBlock ?? false)
        }
        configureOverlayScrollbars(for: webView)
        DispatchQueue.main.async {
            configureOverlayScrollbars(for: webView)
        }
        webView.loadHTMLString(MarkdownWebRenderer.htmlDocument(from: markdown, previewFont: previewFont), baseURL: nil)
        context.coordinator.markInitiallyRendered(
            markdown: markdown,
            previewFont: previewFont,
            editorFollowRatio: editorFollowRatio,
            editorFollowEventID: editorFollowEventID
        )
        return webView
    }

    func updateNSView(_ nsView: SwipeAwareWebView, context: Context) {
        nsView.navigationDelegate = context.coordinator
        nsView.onHorizontalSwipe = onHorizontalSwipe
        nsView.shouldHandleHorizontalSwipe = { [weak coordinator = context.coordinator] in
            !(coordinator?.isHoveringScrollableCodeBlock ?? false)
        }
        configureOverlayScrollbars(for: nsView)
        context.coordinator.render(
            markdown: markdown,
            previewFont: previewFont,
            editorFollowRatio: editorFollowRatio,
            editorFollowEventID: editorFollowEventID,
            in: nsView
        )
    }

    private func configureOverlayScrollbars(for webView: WKWebView) {
        guard let scrollView = firstScrollView(in: webView) else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScroller?.controlSize = .small
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }

        for subview in view.subviews {
            if let found = firstScrollView(in: subview) {
                return found
            }
        }

        return nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private var lastMarkdown: String = ""
        private var lastPreviewFont: PreviewFontOption = .systemSans
        private var pendingEditorFollow: (eventID: Int, ratio: Double)?
        private var lastAppliedEditorFollowEventID: Int = -1
        var isHoveringScrollableCodeBlock: Bool = false

        func markInitiallyRendered(
            markdown: String,
            previewFont: PreviewFontOption,
            editorFollowRatio: Double,
            editorFollowEventID: Int
        ) {
            lastMarkdown = markdown
            lastPreviewFont = previewFont
            queueEditorFollow(ratio: editorFollowRatio, eventID: editorFollowEventID)
        }

        func render(
            markdown: String,
            previewFont: PreviewFontOption,
            editorFollowRatio: Double,
            editorFollowEventID: Int,
            in webView: WKWebView
        ) {
            queueEditorFollow(ratio: editorFollowRatio, eventID: editorFollowEventID)

            if previewFont != lastPreviewFont {
                lastPreviewFont = previewFont
                lastMarkdown = markdown
                webView.loadHTMLString(MarkdownWebRenderer.htmlDocument(from: markdown, previewFont: previewFont), baseURL: nil)
                return
            }

            if markdown == lastMarkdown {
                applyPendingEditorFollow(in: webView)
                return
            }
            lastMarkdown = markdown
            let bodyHTML = MarkdownWebRenderer.htmlBody(from: markdown)
            let encodedBodyHTML = Self.javaScriptStringLiteral(bodyHTML)
            let pendingFollowEventID = pendingEditorFollow?.eventID
            let ratioLiteral = pendingEditorFollow.map { Self.javaScriptNumberLiteral($0.ratio) } ?? "null"
            let shouldFollowLiteral = pendingFollowEventID == nil ? "false" : "true"
            let script = "window.ecrivisseUpdateBody(\(encodedBodyHTML), \(ratioLiteral), \(shouldFollowLiteral));"

            webView.evaluateJavaScript(script) { [weak self, weak webView] _, error in
                guard let self, let webView else { return }
                if error != nil {
                    webView.loadHTMLString(MarkdownWebRenderer.htmlDocument(from: markdown, previewFont: previewFont), baseURL: nil)
                    return
                }
                if let pendingFollowEventID {
                    self.consumeEditorFollow(eventID: pendingFollowEventID)
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == previewHoverMessageHandlerName else { return }
            if let value = message.body as? Bool {
                isHoveringScrollableCodeBlock = value
                return
            }
            if let value = message.body as? NSNumber {
                isHoveringScrollableCodeBlock = value.boolValue
                return
            }
            isHoveringScrollableCodeBlock = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyPendingEditorFollow(in: webView)
        }

        private static func javaScriptStringLiteral(_ value: String) -> String {
            if let data = try? JSONEncoder().encode(value),
               let encoded = String(data: data, encoding: .utf8) {
                return encoded
            }
            return "\"\""
        }

        private static func javaScriptNumberLiteral(_ value: Double) -> String {
            guard value.isFinite else { return "0" }
            return String(format: "%.8f", max(0, min(1, value)))
        }

        private func queueEditorFollow(ratio: Double, eventID: Int) {
            guard eventID > lastAppliedEditorFollowEventID else { return }
            pendingEditorFollow = (eventID: eventID, ratio: max(0, min(1, ratio)))
        }

        private func consumeEditorFollow(eventID: Int) {
            guard let pending = pendingEditorFollow else { return }
            guard pending.eventID == eventID else { return }
            lastAppliedEditorFollowEventID = max(lastAppliedEditorFollowEventID, eventID)
            pendingEditorFollow = nil
        }

        private func applyPendingEditorFollow(in webView: WKWebView) {
            guard let pending = pendingEditorFollow else { return }
            let ratioLiteral = Self.javaScriptNumberLiteral(pending.ratio)
            let script = "window.ecrivisseScrollToRatio(\(ratioLiteral));"

            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard error == nil else { return }
                self?.consumeEditorFollow(eventID: pending.eventID)
            }
        }
    }

    final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
        weak var delegate: WKScriptMessageHandler?

        init(delegate: WKScriptMessageHandler) {
            self.delegate = delegate
            super.init()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            delegate?.userContentController(userContentController, didReceive: message)
        }
    }
}

final class SwipeAwareWebView: WKWebView {
    var onHorizontalSwipe: ((CGFloat) -> Void)?
    var shouldHandleHorizontalSwipe: (() -> Bool)?

    private var horizontalSwipeAccumulator: CGFloat = 0
    private var didEmitHorizontalSwipe = false

    override func scrollWheel(with event: NSEvent) {
        handleHorizontalSwipeEvent(event)
        super.scrollWheel(with: event)
    }

    private func handleHorizontalSwipeEvent(_ event: NSEvent) {
        if event.phase == .began || event.phase == .mayBegin {
            horizontalSwipeAccumulator = 0
            didEmitHorizontalSwipe = false
        }

        let rawDeltaX = event.scrollingDeltaX
        let rawDeltaY = event.scrollingDeltaY
        guard abs(rawDeltaX) > abs(rawDeltaY), abs(rawDeltaX) > 0.01 else {
            resetHorizontalSwipeIfEnded(event)
            return
        }

        if let shouldHandleHorizontalSwipe, !shouldHandleHorizontalSwipe() {
            horizontalSwipeAccumulator = 0
            didEmitHorizontalSwipe = false
            resetHorizontalSwipeIfEnded(event)
            return
        }

        let normalizedDeltaX = event.isDirectionInvertedFromDevice ? -rawDeltaX : rawDeltaX
        horizontalSwipeAccumulator += normalizedDeltaX

        let threshold: CGFloat = 55
        if !didEmitHorizontalSwipe, abs(horizontalSwipeAccumulator) >= threshold {
            didEmitHorizontalSwipe = true
            onHorizontalSwipe?(horizontalSwipeAccumulator)
        }

        resetHorizontalSwipeIfEnded(event)
    }

    private func resetHorizontalSwipeIfEnded(_ event: NSEvent) {
        if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
            horizontalSwipeAccumulator = 0
            didEmitHorizontalSwipe = false
        }
    }
}

enum MarkdownWebRenderer {
    static let previewInteractionScript = """
    (() => {
      const handler = window.webkit?.messageHandlers?.\(previewHoverMessageHandlerName);
      if (!handler) { return; }

      const isInHorizontallyScrollableCode = (element) => {
        const pre = element?.closest?.("pre");
        if (!pre) { return false; }
        return (pre.scrollWidth - pre.clientWidth) > 1;
      };

      let lastValue = null;
      const publish = (value) => {
        if (lastValue === value) { return; }
        lastValue = value;
        handler.postMessage(value);
      };

      const updateFromEvent = (event) => {
        publish(isInHorizontallyScrollableCode(event.target));
      };

      document.addEventListener("mouseover", updateFromEvent, { passive: true });
      document.addEventListener("mousemove", updateFromEvent, { passive: true });
      document.addEventListener("mouseleave", () => publish(false), { passive: true });
      publish(false);
    })();
    """

    private enum ListType {
        case unordered
        case ordered

        var tagName: String {
            switch self {
            case .unordered:
                return "ul"
            case .ordered:
                return "ol"
            }
        }
    }

    private struct ListContext {
        var type: ListType
        var indent: Int
        var hasOpenListItem: Bool
    }

    private enum TableAlignment {
        case left
        case center
        case right

        var cssValue: String {
            switch self {
            case .left:
                return "left"
            case .center:
                return "center"
            case .right:
                return "right"
            }
        }
    }

    private struct TaskListItem {
        var checked: Bool
        var content: String
    }

    private struct LinkReferenceDefinition {
        var url: String
        var title: String?
    }

    static func htmlDocument(from markdown: String, previewFont: PreviewFontOption = .systemSans) -> String {
        let bodyHTML = makeHTMLBody(from: markdown)
        let previewFontStack = previewFont.cssFontStack
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <style>
            :root {
              color-scheme: light dark;
              --bg: #ffffff;
              --fg: #1d1d1f;
              --muted: #5c5f66;
              --rule: #d9dade;
              --code-bg: #f5f6f8;
              --link: #3b6ea9;
            }
            @media (prefers-color-scheme: dark) {
              :root {
                --bg: #111214;
                --fg: #e8e9ed;
                --muted: #a0a4ad;
                --rule: #2b2f36;
                --code-bg: #1a1d22;
                --link: #8eb7eb;
              }
            }
            html, body {
              margin: 0;
              padding: 0;
              background: var(--bg);
              color: var(--fg);
              font-family: \(previewFontStack);
              font-size: 15px;
              line-height: 1.65;
            }
            .wrap {
              max-width: 760px;
              margin: 0 auto;
              padding: 42px 38px 92px;
              box-sizing: border-box;
            }
            ul, ol {
              margin: 0.8em 0;
              padding-left: 1.2em;
              list-style-position: inside;
            }
            ul.task-list {
              list-style: none;
              padding-left: 0;
              margin-left: 0;
            }
            ul.task-list li {
              display: flex;
              align-items: flex-start;
              gap: 0.48em;
              margin: 0.28em 0;
            }
            ul.task-list input[type="checkbox"] {
              margin-top: 0.18em;
              accent-color: #3b6ea9;
            }
            ul.task-list .task-text {
              flex: 1;
            }
            li {
              margin: 0.2em 0;
            }
            li > ul, li > ol {
              margin: 0.35em 0 0.35em 1.1em;
              padding-left: 0.9em;
            }
            h1, h2, h3, h4, h5, h6 {
              line-height: 1.28;
              margin-top: 1.3em;
              margin-bottom: 0.45em;
              letter-spacing: 0;
              overflow: visible;
            }
            p, ul, ol, blockquote, pre {
              margin: 0.85em 0;
            }
            hr {
              border: none;
              border-top: 1px solid var(--rule);
              margin: 1.6em 0;
            }
            a { color: var(--link); text-decoration: none; }
            a:hover { text-decoration: underline; }
            img {
              max-width: 100%;
              height: auto;
              border-radius: 10px;
              display: block;
              margin: 0.7em 0;
            }
            blockquote {
              border-left: 3px solid var(--rule);
              margin-left: 0;
              padding-left: 0.9em;
              color: var(--muted);
            }
            code, pre {
              font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
              font-size: 0.92em;
            }
            code {
              background: var(--code-bg);
              border-radius: 6px;
              padding: 0.08em 0.35em;
            }
            pre {
              background: var(--code-bg);
              border-radius: 10px;
              padding: 0.85em 1em;
              overflow-x: auto;
            }
            pre code {
              background: transparent;
              padding: 0;
            }
            table {
              width: 100%;
              border-collapse: collapse;
              margin: 1em 0;
            }
            th, td {
              border: 1px solid var(--rule);
              padding: 0.5em 0.65em;
              text-align: left;
            }
            .math-block {
              margin: 1.05em 0;
              overflow-x: auto;
            }
            .math-block mjx-container[display="true"] {
              margin: 0.2em 0 !important;
            }
            .math-inline mjx-container {
              margin: 0 !important;
            }
            dl {
              margin: 0.95em 0;
            }
            dt {
              margin-top: 0.45em;
              font-weight: 600;
            }
            dd {
              margin: 0.18em 0 0.58em 1.25em;
              color: var(--muted);
            }
            .mention, .hashtag {
              color: var(--link);
              font-weight: 600;
            }
            .footnote-ref a {
              text-decoration: none;
              font-size: 0.86em;
              vertical-align: super;
            }
            .footnotes {
              margin-top: 1.75em;
              color: var(--muted);
              font-size: 0.93em;
            }
            .footnotes ol {
              padding-left: 1.25em;
            }
            .footnotes li {
              margin: 0.3em 0;
            }
            .footnote-backref {
              text-decoration: none;
              margin-left: 0.34em;
            }
          </style>
          <script>
            window.ecrivisseScrollToRatio = (ratio) => {
              const safeRatio = Number.isFinite(ratio) ? Math.max(0, Math.min(1, ratio)) : 0;
              let calibratedRatio = safeRatio;
              if (safeRatio > 0 && safeRatio < 0.25) {
                const topT = safeRatio / 0.25;
                calibratedRatio = Math.max(0, safeRatio - ((1 - topT) * 0.028));
              }
              const doc = document.documentElement;
              const body = document.body;
              const maxHeight = Math.max(doc.scrollHeight || 0, body.scrollHeight || 0);
              const viewport = window.innerHeight || doc.clientHeight || 0;
              const maxOffset = Math.max(maxHeight - viewport, 0);
              const targetOffset = maxOffset * calibratedRatio;
              const currentOffset = window.scrollY || doc.scrollTop || body.scrollTop || 0;
              if (Math.abs(targetOffset - currentOffset) < 8) {
                return;
              }
              window.scrollTo(0, targetOffset);
            };

            window.ecrivisseCaptureExistingImages = (root) => {
              const pool = new Map();
              if (!root) { return pool; }
              const images = root.querySelectorAll("img");
              images.forEach((img) => {
                const key = [
                  img.getAttribute("src") || "",
                  img.getAttribute("alt") || "",
                  img.getAttribute("title") || ""
                ].join("\\u0001");
                if (!pool.has(key)) {
                  pool.set(key, []);
                }
                pool.get(key).push(img);
              });
              return pool;
            };

            window.ecrivisseRestoreExistingImages = (root, pool) => {
              if (!root || !pool) { return; }
              const images = root.querySelectorAll("img");
              images.forEach((newImg) => {
                const key = [
                  newImg.getAttribute("src") || "",
                  newImg.getAttribute("alt") || "",
                  newImg.getAttribute("title") || ""
                ].join("\\u0001");
                const candidates = pool.get(key);
                if (!candidates || candidates.length === 0) { return; }

                const existingImg = candidates.shift();
                if (!existingImg) { return; }

                existingImg.className = newImg.className;
                existingImg.style.cssText = newImg.style.cssText;
                if (newImg.width) { existingImg.width = newImg.width; }
                if (newImg.height) { existingImg.height = newImg.height; }
                newImg.replaceWith(existingImg);
              });
            };

            window.ecrivisseUpdateBody = (rawHTML, editorRatio = null, shouldFollowEditor = false) => {
              const main = document.querySelector("main.wrap");
              if (!main) { return; }

              const doc = document.documentElement;
              const body = document.body;
              const previousOffset = window.scrollY || doc.scrollTop || body.scrollTop || 0;
              const existingImagePool = window.ecrivisseCaptureExistingImages(main);

              main.innerHTML = rawHTML;
              window.ecrivisseRestoreExistingImages(main, existingImagePool);

              const restoreScroll = () => {
                if (shouldFollowEditor && Number.isFinite(editorRatio)) {
                  window.ecrivisseScrollToRatio(editorRatio);
                  return;
                }
                const maxHeight = Math.max(doc.scrollHeight || 0, body.scrollHeight || 0);
                const viewport = window.innerHeight || doc.clientHeight || 0;
                const maxOffset = Math.max(maxHeight - viewport, 0);
                window.scrollTo(0, Math.min(maxOffset, previousOffset));
              };

              if (window.MathJax?.typesetPromise) {
                try {
                  window.MathJax.typesetClear?.([main]);
                } catch (_) {}
                window.MathJax.typesetPromise([main]).then(restoreScroll).catch(restoreScroll);
              } else {
                restoreScroll();
              }
            };
          </script>
          <script>
            window.MathJax = {
              tex: {
                inlineMath: [["\\\\(", "\\\\)"]],
                displayMath: [["\\\\[", "\\\\]"]],
                processEscapes: true
              },
              options: {
                skipHtmlTags: ["script", "noscript", "style", "textarea", "pre", "code"]
              }
            };
          </script>
          <script async src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-chtml.js"></script>
        </head>
        <body>
          <main class="wrap">\(bodyHTML)</main>
        </body>
        </html>
        """
    }

    static func htmlBody(from markdown: String) -> String {
        makeHTMLBody(from: markdown)
    }

    private static func makeHTMLBody(from markdown: String) -> String {
        guard !markdown.isEmpty else {
            return "<p></p>"
        }

        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.components(separatedBy: "\n")
        let extraction = extractDefinitions(from: rawLines)
        let lines = extraction.contentLines
        let linkDefinitions = extraction.linkDefinitions
        let footnoteDefinitions = extraction.footnoteDefinitions

        var htmlParts: [String] = []
        var paragraphBuffer: [String] = []
        var listStack: [ListContext] = []
        var footnoteOrder: [String] = []
        var footnoteIndexByID: [String: Int] = [:]
        var index = 0

        func parseInlineContent(_ text: String, trackFootnotes: Bool = true) -> String {
            Self.parseInline(
                text,
                linkDefinitions: linkDefinitions,
                footnoteIndexByID: &footnoteIndexByID,
                footnoteOrder: &footnoteOrder,
                collectFootnoteReferences: trackFootnotes
            )
        }

        func closeCurrentListItemIfNeeded() {
            guard !listStack.isEmpty else { return }
            if listStack[listStack.count - 1].hasOpenListItem {
                htmlParts.append("</li>")
                listStack[listStack.count - 1].hasOpenListItem = false
            }
        }

        func openList(_ type: ListType, indent: Int) {
            htmlParts.append("<\(type.tagName)>")
            listStack.append(ListContext(type: type, indent: indent, hasOpenListItem: false))
        }

        func closeTopList() {
            guard !listStack.isEmpty else { return }
            closeCurrentListItemIfNeeded()
            let closed = listStack.removeLast()
            htmlParts.append("</\(closed.type.tagName)>")
        }

        func closeLists(downToLessThan indent: Int) {
            while let top = listStack.last, top.indent >= indent {
                closeTopList()
            }
        }

        func closeAllLists() {
            while !listStack.isEmpty {
                closeTopList()
            }
        }

        func flushParagraphIfNeeded() {
            guard !paragraphBuffer.isEmpty else { return }
            let inline = paragraphBuffer.map { parseInlineContent($0) }.joined(separator: "<br/>")
            htmlParts.append("<p>\(inline)</p>")
            paragraphBuffer.removeAll(keepingCapacity: true)
        }

        func appendListItem(type: ListType, indent: Int, text: String) {
            while let top = listStack.last, indent < top.indent {
                closeTopList()
            }

            if let top = listStack.last {
                if indent > top.indent {
                    openList(type, indent: indent)
                } else if indent == top.indent {
                    if top.type == type {
                        closeCurrentListItemIfNeeded()
                    } else {
                        closeTopList()
                        if listStack.isEmpty || indent > (listStack.last?.indent ?? -1) {
                            openList(type, indent: indent)
                        } else {
                            while let sibling = listStack.last,
                                  sibling.indent == indent,
                                  sibling.type != type {
                                closeTopList()
                            }
                            if listStack.last?.indent != indent || listStack.last?.type != type {
                                openList(type, indent: indent)
                            }
                        }
                    }
                }
            } else {
                openList(type, indent: indent)
            }

            if listStack.last?.indent != indent || listStack.last?.type != type {
                openList(type, indent: indent)
            }

            htmlParts.append("<li>\(parseInlineContent(text))")
            listStack[listStack.count - 1].hasOpenListItem = true
        }

        func renderTaskListItemHTML(_ item: TaskListItem) -> String {
            let checkedAttribute = item.checked ? " checked" : ""
            return "<li><input type=\"checkbox\" disabled\(checkedAttribute) /><span class=\"task-text\">\(parseInlineContent(item.content))</span></li>"
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = captureGroups(in: line, pattern: #"^\s*```([A-Za-z0-9_-]+)?\s*$"#) {
                flushParagraphIfNeeded()
                closeAllLists()

                let language = (fence.count > 1 ? fence[1] : "").trimmingCharacters(in: .whitespacesAndNewlines)
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    let current = lines[index]
                    if current.range(of: #"^\s*```\s*$"#, options: .regularExpression) != nil {
                        break
                    }
                    codeLines.append(current)
                    index += 1
                }
                let code = escapeHTML(codeLines.joined(separator: "\n"))
                let classAttribute = language.isEmpty ? "" : " class=\"language-\(escapeHTML(language))\""
                htmlParts.append("<pre><code\(classAttribute)>\(code)</code></pre>")
                if index < lines.count {
                    index += 1
                }
                continue
            }

            if let singleLineMath = parseSingleLineDisplayMath(line) {
                flushParagraphIfNeeded()
                closeAllLists()
                htmlParts.append("<div class=\"math-block\">\\[\(escapeHTML(singleLineMath))\\]</div>")
                index += 1
                continue
            }

            if trimmed == "$$" {
                flushParagraphIfNeeded()
                closeAllLists()

                var mathLines: [String] = []
                index += 1
                while index < lines.count {
                    let current = lines[index]
                    if current.trimmingCharacters(in: .whitespaces) == "$$" {
                        index += 1
                        break
                    }
                    mathLines.append(current)
                    index += 1
                }

                let expression = mathLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                htmlParts.append("<div class=\"math-block\">\\[\(escapeHTML(expression))\\]</div>")
                continue
            }

            if trimmed.isEmpty {
                flushParagraphIfNeeded()
                closeAllLists()
                index += 1
                continue
            }

            if line.range(of: #"^\s*(?:-{3,}|\*{3,}|_{3,})\s*$"#, options: .regularExpression) != nil {
                flushParagraphIfNeeded()
                closeAllLists()
                htmlParts.append("<hr/>")
                index += 1
                continue
            }

            if trimmed.lowercased().hasPrefix("<details") {
                flushParagraphIfNeeded()
                closeAllLists()

                var htmlBlockLines: [String] = [line]
                index += 1
                while index < lines.count {
                    let current = lines[index]
                    htmlBlockLines.append(current)
                    index += 1
                    if current.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("</details") {
                        break
                    }
                }

                htmlParts.append(htmlBlockLines.joined(separator: "\n"))
                continue
            }

            if index + 1 < lines.count,
               isDefinitionListTermLine(line),
               parseDefinitionListLine(lines[index + 1]) != nil {
                flushParagraphIfNeeded()
                closeAllLists()

                htmlParts.append("<dl>")
                var rowIndex = index
                while rowIndex < lines.count {
                    let termLine = lines[rowIndex]
                    let trimmedTerm = termLine.trimmingCharacters(in: .whitespaces)
                    guard !trimmedTerm.isEmpty,
                          isDefinitionListTermLine(termLine),
                          rowIndex + 1 < lines.count,
                          parseDefinitionListLine(lines[rowIndex + 1]) != nil else {
                        break
                    }

                    htmlParts.append("<dt>\(parseInlineContent(trimmedTerm))</dt>")
                    var definitionIndex = rowIndex + 1
                    while definitionIndex < lines.count,
                          let definitionText = parseDefinitionListLine(lines[definitionIndex]) {
                        htmlParts.append("<dd>\(parseInlineContent(definitionText))</dd>")
                        definitionIndex += 1
                    }
                    rowIndex = definitionIndex
                }
                htmlParts.append("</dl>")
                index = rowIndex
                continue
            }

            if index + 1 < lines.count,
               let headerCells = parseTableRow(lines[index]),
               let alignments = parseTableDivider(lines[index + 1], expectedColumnCount: headerCells.count) {
                flushParagraphIfNeeded()
                closeAllLists()

                htmlParts.append("<table><thead><tr>")
                for (columnIndex, rawCell) in headerCells.enumerated() {
                    let alignmentAttribute = tableAlignmentAttribute(alignments[columnIndex])
                    htmlParts.append("<th\(alignmentAttribute)>\(parseInlineContent(rawCell))</th>")
                }
                htmlParts.append("</tr></thead>")

                var bodyRows: [[String]] = []
                var rowIndex = index + 2
                while rowIndex < lines.count {
                    let candidate = lines[rowIndex]
                    if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                        break
                    }
                    guard let parsedRow = parseTableRow(candidate) else {
                        break
                    }
                    bodyRows.append(normalizeTableCells(parsedRow, expectedColumnCount: headerCells.count))
                    rowIndex += 1
                }

                if !bodyRows.isEmpty {
                    htmlParts.append("<tbody>")
                    for row in bodyRows {
                        htmlParts.append("<tr>")
                        for (columnIndex, rawCell) in row.enumerated() {
                            let alignmentAttribute = tableAlignmentAttribute(alignments[columnIndex])
                            htmlParts.append("<td\(alignmentAttribute)>\(parseInlineContent(rawCell))</td>")
                        }
                        htmlParts.append("</tr>")
                    }
                    htmlParts.append("</tbody>")
                }

                htmlParts.append("</table>")
                index = rowIndex
                continue
            }

            if let heading = captureGroups(in: line, pattern: #"^(#{1,6})\s+(.+?)\s*$"#) {
                flushParagraphIfNeeded()
                closeAllLists()
                let level = heading[1].count
                let content = parseInlineContent(heading[2])
                htmlParts.append("<h\(level)>\(content)</h\(level)>")
                index += 1
                continue
            }

            if line.range(of: #"^\s*>\s?.*$"#, options: .regularExpression) != nil {
                flushParagraphIfNeeded()
                closeAllLists()

                var quoteLines: [String] = []
                while index < lines.count,
                      lines[index].range(of: #"^\s*>\s?.*$"#, options: .regularExpression) != nil {
                    let stripped = replaceFirst(
                        in: lines[index],
                        pattern: #"^\s*>\s?"#,
                        with: ""
                    )
                    quoteLines.append(parseInlineContent(stripped))
                    index += 1
                }

                htmlParts.append("<blockquote><p>\(quoteLines.joined(separator: "<br/>"))</p></blockquote>")
                continue
            }

            if let firstTask = parseTaskListLine(line) {
                flushParagraphIfNeeded()
                closeAllLists()

                var items: [TaskListItem] = [firstTask]
                var rowIndex = index + 1
                while rowIndex < lines.count, let item = parseTaskListLine(lines[rowIndex]) {
                    items.append(item)
                    rowIndex += 1
                }

                htmlParts.append("<ul class=\"task-list\">")
                for item in items {
                    htmlParts.append(renderTaskListItemHTML(item))
                }
                htmlParts.append("</ul>")

                index = rowIndex
                continue
            }

            if let unordered = captureGroups(in: line, pattern: #"^([ \t]*)([-+*])\s+(.+)$"#) {
                flushParagraphIfNeeded()
                let indent = indentationWidth(unordered[1])
                appendListItem(type: .unordered, indent: indent, text: unordered[3])
                index += 1
                continue
            }

            if let ordered = captureGroups(in: line, pattern: #"^([ \t]*)(\d+)\.\s+(.+)$"#) {
                flushParagraphIfNeeded()
                let indent = indentationWidth(ordered[1])
                appendListItem(type: .ordered, indent: indent, text: ordered[3])
                index += 1
                continue
            }

            closeAllLists()
            paragraphBuffer.append(trimmed)
            index += 1
        }

        flushParagraphIfNeeded()
        closeAllLists()

        if !footnoteOrder.isEmpty {
            htmlParts.append("<section class=\"footnotes\">")
            htmlParts.append("<hr/>")
            htmlParts.append("<ol>")
            for footnoteID in footnoteOrder {
                let safeID = safeAnchorID(for: footnoteID)
                let body: String
                if let definition = footnoteDefinitions[footnoteID], !definition.isEmpty {
                    body = parseInlineContent(definition, trackFootnotes: false)
                } else {
                    body = "<em>Missing footnote definition.</em>"
                }
                htmlParts.append("<li id=\"fn:\(safeID)\">\(body) <a class=\"footnote-backref\" href=\"#fnref:\(safeID)\">↩</a></li>")
            }
            htmlParts.append("</ol>")
            htmlParts.append("</section>")
        }

        return htmlParts.joined(separator: "\n")
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func parseInline(
        _ text: String,
        linkDefinitions: [String: LinkReferenceDefinition],
        footnoteIndexByID: inout [String: Int],
        footnoteOrder: inout [String],
        collectFootnoteReferences: Bool = true
    ) -> String {
        var working = text
        var escapedLiterals: [String] = []
        var codeSnippets: [String] = []
        var mathSnippets: [String] = []
        var rawHTMLTags: [String] = []
        var preservedSnippets: [String] = []

        func preserveSnippet(_ html: String) -> String {
            let token = "@@CWTOKENSNIP\(preservedSnippets.count)@@"
            preservedSnippets.append(html)
            return token
        }

        working = replacingMatches(in: working, pattern: #"\\([\\`*_{}\[\]()#+\-.!|~$]+)"#) { match, ns in
            let literal = ns.substring(with: match.range(at: 1))
            let token = "@@CWTOKENESC\(escapedLiterals.count)@@"
            escapedLiterals.append(escapeHTML(literal))
            return token
        }

        working = replacingMatches(in: working, pattern: #"`([^`]+)`"#) { match, ns in
            let codeText = ns.substring(with: match.range(at: 1))
            let token = "@@CWTOKENCODE\(codeSnippets.count)@@"
            codeSnippets.append("<code>\(escapeHTML(codeText))</code>")
            return token
        }

        working = replacingMatches(in: working, pattern: #"(?<!\$)\$([^$\n]+?)\$(?!\$)"#) { match, ns in
            let expression = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let token = "@@CWTOKENMATH\(mathSnippets.count)@@"
            mathSnippets.append("<span class=\"math-inline\">\\(\(escapeHTML(expression))\\)</span>")
            return token
        }

        if collectFootnoteReferences {
            working = replacingMatches(in: working, pattern: #"\[\^([^\]]+)\]"#) { match, ns in
                let rawID = ns.substring(with: match.range(at: 1))
                let normalizedID = normalizeReferenceKey(rawID)
                let index: Int
                if let existing = footnoteIndexByID[normalizedID] {
                    index = existing
                } else {
                    index = footnoteOrder.count + 1
                    footnoteIndexByID[normalizedID] = index
                    footnoteOrder.append(normalizedID)
                }

                let safeID = safeAnchorID(for: normalizedID)
                let html = "<sup class=\"footnote-ref\"><a id=\"fnref:\(safeID)\" href=\"#fn:\(safeID)\">[\(index)]</a></sup>"
                return preserveSnippet(html)
            }
        }

        working = replacingMatches(in: working, pattern: #"<((?:https?|ftp)://[^>\s]+)>"#) { match, ns in
            let url = cleanURL(ns.substring(with: match.range(at: 1)))
            let html = "<a href=\"\(escapeHTML(url))\">\(escapeHTML(url))</a>"
            return preserveSnippet(html)
        }

        working = replacingMatches(
            in: working,
            pattern: #"<([A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,})>"#,
            options: [.caseInsensitive]
        ) { match, ns in
            let email = ns.substring(with: match.range(at: 1))
            let html = "<a href=\"mailto:\(escapeHTML(email))\">\(escapeHTML(email))</a>"
            return preserveSnippet(html)
        }

        working = replacingMatches(in: working, pattern: #"!\[([^\]]*)\]\[([^\]]+)\]"#) { match, ns in
            let alt = ns.substring(with: match.range(at: 1))
            let referenceID = normalizeReferenceKey(ns.substring(with: match.range(at: 2)))
            guard let definition = linkDefinitions[referenceID] else {
                return ns.substring(with: match.range(at: 0))
            }

            let titleAttribute = definition.title.map { " title=\"\(escapeHTML($0))\"" } ?? ""
            let html = "<img src=\"\(escapeHTML(definition.url))\" alt=\"\(escapeHTML(alt))\"\(titleAttribute) />"
            return preserveSnippet(html)
        }

        working = replacingMatches(in: working, pattern: #"!\[([^\]]*)\]\[\]"#) { match, ns in
            let alt = ns.substring(with: match.range(at: 1))
            let referenceID = normalizeReferenceKey(alt)
            guard let definition = linkDefinitions[referenceID] else {
                return ns.substring(with: match.range(at: 0))
            }

            let titleAttribute = definition.title.map { " title=\"\(escapeHTML($0))\"" } ?? ""
            let html = "<img src=\"\(escapeHTML(definition.url))\" alt=\"\(escapeHTML(alt))\"\(titleAttribute) />"
            return preserveSnippet(html)
        }

        working = replacingMatches(in: working, pattern: #"</?[A-Za-z][A-Za-z0-9:-]*(?:\s+[^<>]*?)?/?>"#) { match, ns in
            let tag = ns.substring(with: match.range(at: 0))
            guard let name = htmlTagName(in: tag),
                  allowedInlineHTMLTags.contains(name.lowercased()) else {
                return tag
            }
            let token = "@@CWTOKENHTML\(rawHTMLTags.count)@@"
            rawHTMLTags.append(tag)
            return token
        }

        working = escapeHTML(working)

        working = replacingMatches(in: working, pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) { match, ns in
            let alt = ns.substring(with: match.range(at: 1))
            let rawURL = ns.substring(with: match.range(at: 2))
            let url = cleanURL(rawURL)
            return "<img src=\"\(escapeHTML(url))\" alt=\"\(escapeHTML(alt))\" />"
        }

        working = replacingMatches(in: working, pattern: #"(?<!!)\[([^\]]+)\]\(([^)]+)\)"#) { match, ns in
            let label = ns.substring(with: match.range(at: 1))
            let rawURL = ns.substring(with: match.range(at: 2))
            let url = cleanURL(rawURL)
            return "<a href=\"\(escapeHTML(url))\">\(label)</a>"
        }

        working = replacingMatches(in: working, pattern: #"(?<!!)\[([^\]]+)\]\[([^\]]+)\]"#) { match, ns in
            let label = ns.substring(with: match.range(at: 1))
            let referenceID = normalizeReferenceKey(ns.substring(with: match.range(at: 2)))
            guard let definition = linkDefinitions[referenceID] else {
                return ns.substring(with: match.range(at: 0))
            }
            return "<a href=\"\(escapeHTML(definition.url))\">\(label)</a>"
        }

        working = replacingMatches(in: working, pattern: #"(?<!!)\[([^\]]+)\]\[\]"#) { match, ns in
            let label = ns.substring(with: match.range(at: 1))
            let referenceID = normalizeReferenceKey(label)
            guard let definition = linkDefinitions[referenceID] else {
                return ns.substring(with: match.range(at: 0))
            }
            return "<a href=\"\(escapeHTML(definition.url))\">\(label)</a>"
        }

        working = replacingMatches(in: working, pattern: #"\*\*\*([^*]+?)\*\*\*"#) { match, ns in
            "<strong><em>\(ns.substring(with: match.range(at: 1)))</em></strong>"
        }
        working = replacingMatches(in: working, pattern: #"___([^_]+?)___"#) { match, ns in
            "<strong><em>\(ns.substring(with: match.range(at: 1)))</em></strong>"
        }
        working = replacingMatches(in: working, pattern: #"\*\*([^*]+?)\*\*"#) { match, ns in
            "<strong>\(ns.substring(with: match.range(at: 1)))</strong>"
        }
        working = replacingMatches(in: working, pattern: #"__([^_]+?)__"#) { match, ns in
            "<strong>\(ns.substring(with: match.range(at: 1)))</strong>"
        }
        working = replacingMatches(in: working, pattern: #"~~([^~]+?)~~"#) { match, ns in
            "<del>\(ns.substring(with: match.range(at: 1)))</del>"
        }
        working = replacingMatches(in: working, pattern: #"(?<!\*)\*([^*]+?)\*(?!\*)"#) { match, ns in
            "<em>\(ns.substring(with: match.range(at: 1)))</em>"
        }
        working = replacingMatches(in: working, pattern: #"(?<!_)_([^_]+?)_(?!_)"#) { match, ns in
            "<em>\(ns.substring(with: match.range(at: 1)))</em>"
        }

        working = replacingMatches(in: working, pattern: #":([a-z0-9_+\-]+):"#, options: [.caseInsensitive]) { match, ns in
            let shortcode = ns.substring(with: match.range(at: 1)).lowercased()
            if let emoji = emojiCharacter(for: shortcode) {
                return emoji
            }
            return ns.substring(with: match.range(at: 0))
        }

        working = replacingMatches(
            in: working,
            pattern: #"(?<!["'=\(])((?:https?://)[A-Za-z0-9\-\._~:/?#\[\]@!$&*+,;=%]+)"#
        ) { match, ns in
            let rawURL = ns.substring(with: match.range(at: 1))
            let parts = splitTrailingURLPunctuation(rawURL)
            let anchor = "<a href=\"\(escapeHTML(parts.url))\">\(escapeHTML(parts.url))</a>"
            return anchor + escapeHTML(parts.trailing)
        }

        working = replacingMatches(
            in: working,
            pattern: #"(^|\s)(@[A-Za-z0-9_]{1,64})"#,
            options: [.anchorsMatchLines]
        ) { match, ns in
            let leading = ns.substring(with: match.range(at: 1))
            let mention = ns.substring(with: match.range(at: 2))
            return "\(leading)<span class=\"mention\">\(mention)</span>"
        }

        working = replacingMatches(
            in: working,
            pattern: #"(^|\s)(#[A-Za-z0-9_][A-Za-z0-9_\-]{0,63})"#,
            options: [.anchorsMatchLines]
        ) { match, ns in
            let leading = ns.substring(with: match.range(at: 1))
            let hashtag = ns.substring(with: match.range(at: 2))
            return "\(leading)<span class=\"hashtag\">\(hashtag)</span>"
        }

        for (index, snippet) in preservedSnippets.enumerated() {
            working = working.replacingOccurrences(of: "@@CWTOKENSNIP\(index)@@", with: snippet)
        }

        for (index, snippet) in rawHTMLTags.enumerated() {
            working = working.replacingOccurrences(of: "@@CWTOKENHTML\(index)@@", with: snippet)
        }
        for (index, snippet) in mathSnippets.enumerated() {
            working = working.replacingOccurrences(of: "@@CWTOKENMATH\(index)@@", with: snippet)
        }
        for (index, snippet) in codeSnippets.enumerated() {
            working = working.replacingOccurrences(of: "@@CWTOKENCODE\(index)@@", with: snippet)
        }
        for (index, literal) in escapedLiterals.enumerated() {
            working = working.replacingOccurrences(of: "@@CWTOKENESC\(index)@@", with: literal)
        }

        return working
    }

    private static func replacingMatches(
        in input: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        transform: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return input
        }

        let nsInput = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))
        guard !matches.isEmpty else { return input }

        var output = ""
        var cursor = 0

        for match in matches {
            let matchStart = match.range.location
            if matchStart > cursor {
                output += nsInput.substring(with: NSRange(location: cursor, length: matchStart - cursor))
            }
            output += transform(match, nsInput)
            cursor = match.range.location + match.range.length
        }

        if cursor < nsInput.length {
            output += nsInput.substring(with: NSRange(location: cursor, length: nsInput.length - cursor))
        }

        return output
    }

    private static func captureGroups(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else {
            return nil
        }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return "" }
            return nsText.substring(with: range)
        }
    }

    private static func replaceFirst(in text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private static func indentationWidth(_ leadingWhitespace: String) -> Int {
        leadingWhitespace.reduce(into: 0) { width, character in
            if character == "\t" {
                width += 4
            } else {
                width += 1
            }
        }
    }

    private static func cleanURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstPart = trimmed.split(separator: " ").first {
            return String(firstPart)
        }
        return trimmed
    }

    private static func extractDefinitions(
        from lines: [String]
    ) -> (
        contentLines: [String],
        linkDefinitions: [String: LinkReferenceDefinition],
        footnoteDefinitions: [String: String]
    ) {
        var contentLines: [String] = []
        var linkDefinitions: [String: LinkReferenceDefinition] = [:]
        var footnoteDefinitions: [String: String] = [:]

        var index = 0
        while index < lines.count {
            let line = lines[index]

            if let linkGroups = captureGroups(
                in: line,
                pattern: #"^\s*\[([^\]]+)\]:\s*(\S+)(?:\s+(?:"([^"]*)"|'([^']*)'|\(([^)]*)\)))?\s*$"#
            ), linkGroups.count > 2 {
                let key = normalizeReferenceKey(linkGroups[1])
                let url = cleanURL(linkGroups[2])
                let possibleTitles = Array(linkGroups.dropFirst(3))
                let title = possibleTitles.first { !$0.isEmpty }?.trimmingCharacters(in: .whitespacesAndNewlines)
                linkDefinitions[key] = LinkReferenceDefinition(url: url, title: title?.isEmpty == true ? nil : title)
                index += 1
                continue
            }

            if let footnoteGroups = captureGroups(in: line, pattern: #"^\s*\[\^([^\]]+)\]:\s*(.+?)\s*$"#),
               footnoteGroups.count > 2 {
                let key = normalizeReferenceKey(footnoteGroups[1])
                var bodyLines: [String] = [footnoteGroups[2]]
                index += 1

                while index < lines.count {
                    let continuation = lines[index]
                    if continuation.range(of: #"^(?:\t| {2,}).+\S"#, options: .regularExpression) != nil {
                        bodyLines.append(continuation.trimmingCharacters(in: .whitespaces))
                        index += 1
                        continue
                    }
                    break
                }

                footnoteDefinitions[key] = bodyLines.joined(separator: "\n")
                continue
            }

            contentLines.append(line)
            index += 1
        }

        return (contentLines, linkDefinitions, footnoteDefinitions)
    }

    private static func normalizeReferenceKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func safeAnchorID(for raw: String) -> String {
        let normalized = normalizeReferenceKey(raw)
        let replaced = normalized.map { character in
            character.isLetter || character.isNumber ? character : "-"
        }
        var anchor = String(replaced)
        anchor = anchor.replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression)
        anchor = anchor.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return anchor.isEmpty ? "note" : anchor
    }

    private static func parseDefinitionListLine(_ line: String) -> String? {
        guard let groups = captureGroups(in: line, pattern: #"^\s*:\s+(.+?)\s*$"#),
              groups.count > 1 else {
            return nil
        }
        return groups[1]
    }

    private static func isDefinitionListTermLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if parseDefinitionListLine(line) != nil { return false }
        if trimmed.hasPrefix("#") || trimmed.hasPrefix(">") || trimmed == "$$" || trimmed.hasPrefix("```") {
            return false
        }
        if trimmed.lowercased().hasPrefix("<details") { return false }
        if captureGroups(in: line, pattern: #"^([ \t]*)([-+*])\s+(.+)$"#) != nil { return false }
        if captureGroups(in: line, pattern: #"^([ \t]*)(\d+)\.\s+(.+)$"#) != nil { return false }
        if line.range(of: #"^\s*(?:-{3,}|\*{3,}|_{3,})\s*$"#, options: .regularExpression) != nil { return false }
        return true
    }

    private static func splitTrailingURLPunctuation(_ rawURL: String) -> (url: String, trailing: String) {
        guard !rawURL.isEmpty else { return ("", "") }
        var url = rawURL
        var trailing = ""

        while let last = url.last {
            if ".,!?:;".contains(last) {
                trailing.insert(last, at: trailing.startIndex)
                url.removeLast()
                continue
            }
            if last == ")" {
                let openCount = url.filter { $0 == "(" }.count
                let closeCount = url.filter { $0 == ")" }.count
                if closeCount > openCount {
                    trailing.insert(last, at: trailing.startIndex)
                    url.removeLast()
                    continue
                }
            }
            break
        }

        if url.isEmpty {
            return (rawURL, "")
        }
        return (url, trailing)
    }

    private static let emojiShortcodeMap: [String: String] = [
        "smile": "😄",
        "rocket": "🚀",
        "warning": "⚠️",
        "check": "✅",
        "x": "❌",
        "fire": "🔥",
        "star": "⭐",
        "sparkles": "✨",
        "thumbsup": "👍",
        "thumbsdown": "👎"
    ]

    private static func emojiCharacter(for shortcode: String) -> String? {
        emojiShortcodeMap[shortcode]
    }

    private static let allowedInlineHTMLTags: Set<String> = [
        "a", "abbr", "b", "blockquote", "br", "code", "del", "details", "em", "i", "ins",
        "kbd", "mark", "p", "pre", "s", "small", "span", "strong", "sub", "summary",
        "sup", "u"
    ]

    private static func htmlTagName(in tag: String) -> String? {
        guard let groups = captureGroups(in: tag, pattern: #"^</?\s*([A-Za-z][A-Za-z0-9:-]*)"#),
              groups.count > 1 else {
            return nil
        }
        return groups[1]
    }

    private static func parseSingleLineDisplayMath(_ line: String) -> String? {
        guard let groups = captureGroups(in: line, pattern: #"^\s*\$\$(.+?)\$\$\s*$"#),
              groups.count > 1 else {
            return nil
        }
        return groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTaskListLine(_ line: String) -> TaskListItem? {
        guard let groups = captureGroups(in: line, pattern: #"^\s*(?:[-+*]\s+)?\[( |x|X)\]\s+(.+?)\s*$"#),
              groups.count > 2 else {
            return nil
        }
        let marker = groups[1].lowercased()
        let content = groups[2]
        return TaskListItem(checked: marker == "x", content: content)
    }

    private static func parseTableRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }

        var working = trimmed
        if working.hasPrefix("|") {
            working.removeFirst()
        }
        if working.hasSuffix("|") {
            working.removeLast()
        }

        let cells = splitTableCells(in: working).map { cell in
            cell.trimmingCharacters(in: .whitespaces)
        }
        guard !cells.isEmpty else { return nil }
        return cells
    }

    private static func parseTableDivider(_ line: String, expectedColumnCount: Int) -> [TableAlignment?]? {
        let rawCells = parseTableRow(line)
        guard let rawCells else { return nil }

        let dividerCells = normalizeTableCells(rawCells, expectedColumnCount: expectedColumnCount)
        var alignments: [TableAlignment?] = []
        alignments.reserveCapacity(expectedColumnCount)

        for rawCell in dividerCells {
            let marker = rawCell.replacingOccurrences(of: " ", with: "")
            guard marker.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil else {
                return nil
            }

            let startsWithColon = marker.hasPrefix(":")
            let endsWithColon = marker.hasSuffix(":")
            if startsWithColon && endsWithColon {
                alignments.append(.center)
            } else if endsWithColon {
                alignments.append(.right)
            } else if startsWithColon {
                alignments.append(.left)
            } else {
                alignments.append(nil)
            }
        }

        return alignments
    }

    private static func normalizeTableCells(_ cells: [String], expectedColumnCount: Int) -> [String] {
        guard expectedColumnCount > 0 else { return [] }

        if cells.count == expectedColumnCount {
            return cells
        }

        if cells.count > expectedColumnCount {
            return Array(cells.prefix(expectedColumnCount))
        }

        var normalized = cells
        normalized.append(contentsOf: repeatElement("", count: expectedColumnCount - cells.count))
        return normalized
    }

    private static func tableAlignmentAttribute(_ alignment: TableAlignment?) -> String {
        guard let alignment else { return "" }
        return " style=\"text-align:\(alignment.cssValue);\""
    }

    private static func splitTableCells(in row: String) -> [String] {
        var cells: [String] = []
        cells.reserveCapacity(4)

        var current = ""
        var isEscaped = false

        for character in row {
            if character == "|" && !isEscaped {
                cells.append(current)
                current = ""
                continue
            }

            current.append(character)
            if character == "\\" {
                isEscaped.toggle()
            } else {
                isEscaped = false
            }
        }

        cells.append(current)
        return cells
    }
}

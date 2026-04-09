import SwiftUI
import WebKit
import AppKit

private let previewHoverMessageHandlerName = "ecrivissePreviewHover"
private let previewTaskToggleMessageHandlerName = "ecrivissePreviewTaskToggle"
private let previewNavigateMessageHandlerName = "ecrivissePreviewNavigate"

struct MarkdownWebPreviewView: NSViewRepresentable {
    let markdown: String
    let previewFont: PreviewFontOption
    let cursorColorHex: String
    let editorFollowRatio: Double
    let editorFollowEventID: Int
    var onHorizontalSwipe: (CGFloat) -> Void
    var onTaskToggle: (_ index: Int, _ checked: Bool) -> Void
    var onNavigateToSourceLine: (_ line: Int) -> Void

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
        userContentController.add(weakHandler, name: previewTaskToggleMessageHandlerName)
        userContentController.add(weakHandler, name: previewNavigateMessageHandlerName)
        config.userContentController = userContentController

        let webView = SwipeAwareWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.onTaskToggle = onTaskToggle
        context.coordinator.onNavigateToSourceLine = onNavigateToSourceLine
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
        webView.loadHTMLString(
            MarkdownWebRenderer.htmlDocument(
                from: markdown,
                previewFont: previewFont,
                cursorColorHex: cursorColorHex
            ),
            baseURL: nil
        )
        context.coordinator.markInitiallyRendered(
            markdown: markdown,
            previewFont: previewFont,
            cursorColorHex: cursorColorHex,
            editorFollowRatio: editorFollowRatio,
            editorFollowEventID: editorFollowEventID
        )
        return webView
    }

    func updateNSView(_ nsView: SwipeAwareWebView, context: Context) {
        nsView.navigationDelegate = context.coordinator
        nsView.onHorizontalSwipe = onHorizontalSwipe
        context.coordinator.onTaskToggle = onTaskToggle
        context.coordinator.onNavigateToSourceLine = onNavigateToSourceLine
        nsView.shouldHandleHorizontalSwipe = { [weak coordinator = context.coordinator] in
            !(coordinator?.isHoveringScrollableCodeBlock ?? false)
        }
        configureOverlayScrollbars(for: nsView)
        context.coordinator.render(
            markdown: markdown,
            previewFont: previewFont,
            cursorColorHex: cursorColorHex,
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
        private var lastCursorColorHex: String = "#FF4D40"
        private var pendingEditorFollow: (eventID: Int, ratio: Double)?
        private var lastAppliedEditorFollowEventID: Int = -1
        var isHoveringScrollableCodeBlock: Bool = false
        var onTaskToggle: ((Int, Bool) -> Void)?
        var onNavigateToSourceLine: ((Int) -> Void)?

        func markInitiallyRendered(
            markdown: String,
            previewFont: PreviewFontOption,
            cursorColorHex: String,
            editorFollowRatio: Double,
            editorFollowEventID: Int
        ) {
            lastMarkdown = markdown
            lastPreviewFont = previewFont
            lastCursorColorHex = cursorColorHex
            queueEditorFollow(ratio: editorFollowRatio, eventID: editorFollowEventID)
        }

        func render(
            markdown: String,
            previewFont: PreviewFontOption,
            cursorColorHex: String,
            editorFollowRatio: Double,
            editorFollowEventID: Int,
            in webView: WKWebView
        ) {
            queueEditorFollow(ratio: editorFollowRatio, eventID: editorFollowEventID)

            if previewFont != lastPreviewFont || cursorColorHex != lastCursorColorHex {
                lastPreviewFont = previewFont
                lastCursorColorHex = cursorColorHex
                lastMarkdown = markdown
                webView.loadHTMLString(
                    MarkdownWebRenderer.htmlDocument(
                        from: markdown,
                        previewFont: previewFont,
                        cursorColorHex: cursorColorHex
                    ),
                    baseURL: nil
                )
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
            let script = """
            (() => {
              if (typeof window.ecrivisseUpdateBody !== "function") { return "missing-update-body"; }
              try {
                window.ecrivisseUpdateBody(\(encodedBodyHTML), \(ratioLiteral), \(shouldFollowLiteral));
                return "ok";
              } catch (error) {
                return "error:" + String(error);
              }
            })();
            """

            webView.evaluateJavaScript(script) { [weak self, weak webView] _, error in
                guard let self, webView != nil else { return }
                guard error == nil else { return }
                if let pendingFollowEventID {
                    self.consumeEditorFollow(eventID: pendingFollowEventID)
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == previewHoverMessageHandlerName {
                if let value = message.body as? Bool {
                    isHoveringScrollableCodeBlock = value
                    return
                }
                if let value = message.body as? NSNumber {
                    isHoveringScrollableCodeBlock = value.boolValue
                    return
                }
                isHoveringScrollableCodeBlock = false
                return
            }

            if message.name == previewNavigateMessageHandlerName {
                if let payload = message.body as? [String: Any],
                   let lineValue = payload["line"] as? NSNumber {
                    onNavigateToSourceLine?(lineValue.intValue)
                    return
                }
                if let payload = message.body as? NSDictionary,
                   let lineValue = payload["line"] as? NSNumber {
                    onNavigateToSourceLine?(lineValue.intValue)
                }
                return
            }

            guard message.name == previewTaskToggleMessageHandlerName else { return }

            if let payload = message.body as? [String: Any],
               let indexValue = payload["index"] as? NSNumber,
               let checkedValue = payload["checked"] as? NSNumber {
                onTaskToggle?(indexValue.intValue, checkedValue.boolValue)
                return
            }
            if let payload = message.body as? NSDictionary,
               let indexValue = payload["index"] as? NSNumber,
               let checkedValue = payload["checked"] as? NSNumber {
                onTaskToggle?(indexValue.intValue, checkedValue.boolValue)
            }
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
      const taskHandler = window.webkit?.messageHandlers?.\(previewTaskToggleMessageHandlerName);
      const navigateHandler = window.webkit?.messageHandlers?.\(previewNavigateMessageHandlerName);

      const isInHorizontallyScrollableCode = (element) => {
        const pre = element?.closest?.("pre");
        if (!pre) { return false; }
        return (pre.scrollWidth - pre.clientWidth) > 1;
      };

      var lastValue = null;
      const publish = (value) => {
        if (lastValue === value) { return; }
        lastValue = value;
        handler.postMessage(value);
      };

      const updateFromEvent = (event) => {
        publish(isInHorizontallyScrollableCode(event.target));
      };

      if (handler) {
        document.addEventListener("mouseover", updateFromEvent, { passive: true });
        document.addEventListener("mousemove", updateFromEvent, { passive: true });
        document.addEventListener("mouseleave", () => publish(false), { passive: true });
        publish(false);
      }

      if (taskHandler) {
        document.addEventListener("change", (event) => {
          const target = event.target;
          if (!(target instanceof HTMLInputElement)) { return; }
          if (target.type !== "checkbox") { return; }
          if (!target.closest("ul.task-list")) { return; }
          const rawIndex = target.getAttribute("data-cw-task-index");
          if (rawIndex == null) { return; }
          const index = Number(rawIndex);
          if (!Number.isFinite(index)) { return; }
          taskHandler.postMessage({ index, checked: !!target.checked });
        }, { passive: true });
      }

      if (navigateHandler) {
        document.addEventListener("click", (event) => {
          const target = event.target;
          if (!(target instanceof Element)) { return; }
          if (target.closest("a")) { return; }
          if (target.closest("input[type='checkbox']")) { return; }
          const sourceNode = target.closest("[data-cw-line]");
          if (!sourceNode) { return; }
          const rawLine = sourceNode.getAttribute("data-cw-line");
          if (rawLine == null) { return; }
          const line = Number(rawLine);
          if (!Number.isFinite(line)) { return; }
          navigateHandler.postMessage({ line });
        }, { passive: true });
      }
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

    private static let taxTermsRegex: NSRegularExpression = {
        let terms = [
            "tax", "taxes", "taxation",
            "impuesto", "impuestos", "tributo", "tributos",
            "impot", "impôt", "impôts", "taxe", "taxes",
            "steuer", "steuern", "abgabe",
            "tassa", "tasse", "imposta", "imposte",
            "imposto", "impostos", "taxa", "taxas",
            "belasting", "belastingen",
            "налог", "налоги", "налогообложение",
            "податок", "податки",
            "podatek", "podatki",
            "daň", "daně", "dane",
            "adó", "adók",
            "vergi", "vergiler", "vergisi",
            "φόρος", "φόροι",
            "impozit", "impozite",
            "данък", "данъци",
            "porez", "porezi",
            "davek", "davki",
            "mokestis", "mokesčiai",
            "nodoklis", "nodokļi",
            "maks", "maksud",
            "skatt", "skatter", "skat", "skattur", "skattar",
            "vero", "verot",
            "세금", "조세",
            "税", "税金", "租税", "税收",
            "稅", "稅金", "稅收",
            "ภาษี",
            "कर", "करों",
            "কর",
            "வரி",
            "పన్ను",
            "ತೆರಿಗೆ",
            "നികുതി",
            "ਟੈਕਸ", "ਕਰ",
            "thuế",
            "pajak",
            "cukai",
            "buwis",
            "ضريبة", "ضرائب",
            "مالیات",
            "ٹیکس",
            "מס", "מיסים",
            "kodi",
            "intela",
            "irhafu",
            "owa-ori", "owo-ori",
            "გადასახადი",
            "հարկ"
        ]
        let escaped = terms.map { NSRegularExpression.escapedPattern(for: $0) }
        let pattern = "(?<![\\p{L}\\p{N}_])(?:" + escaped.joined(separator: "|") + ")(?![\\p{L}\\p{N}_])"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private struct TOCHeadingEntry {
        var level: Int
        var anchorID: String
        var titleHTML: String
    }

    static func htmlDocument(
        from markdown: String,
        previewFont: PreviewFontOption = .systemSans,
        cursorColorHex: String = "#FF4D40"
    ) -> String {
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
              --code-fg: #20242b;
              --link: #3b6ea9;
              --code-keyword: #9652d6;
              --code-string: #13885f;
              --code-number: #0f6cc0;
              --code-comment: #7b8088;
              --code-title: #9256d0;
              --code-attr: #9b3f77;
              --cursor-accent: \(cursorColorHex);
            }
            @media (prefers-color-scheme: dark) {
              :root {
                --bg: #111214;
                --fg: #e8e9ed;
                --muted: #a0a4ad;
                --rule: #2b2f36;
                --code-bg: #1a1d22;
                --code-fg: #e8edf3;
                --link: #8eb7eb;
                --code-keyword: #c996ff;
                --code-string: #7dd7ac;
                --code-number: #7bc3ff;
                --code-comment: #8f95a0;
                --code-title: #d2a5ff;
                --code-attr: #f3a4cf;
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
              margin-top: 0.28em;
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
            .cw-toc {
              border: 1px solid var(--rule);
              border-radius: 10px;
              padding: 0.8em 0.95em;
              margin: 0.95em 0 1.1em;
              background: color-mix(in oklab, var(--code-bg) 38%, var(--bg));
            }
            .cw-toc-title {
              font-size: 0.93em;
              font-weight: 700;
              color: var(--muted);
              margin-bottom: 0.52em;
              letter-spacing: 0.02em;
              text-transform: uppercase;
            }
            .cw-toc-list {
              list-style: none;
              padding-left: 0;
              margin: 0;
            }
            .cw-toc-item {
              margin: 0.2em 0;
            }
            .cw-toc-level-1 { padding-left: 0; }
            .cw-toc-level-2 { padding-left: 0.95em; }
            .cw-toc-level-3 { padding-left: 1.7em; }
            .cw-toc-level-4 { padding-left: 2.45em; }
            .cw-toc-level-5 { padding-left: 3.2em; }
            .cw-toc-level-6 { padding-left: 3.95em; }
            .cw-toc-empty {
              color: var(--muted);
              margin: 0;
            }
            .cw-tax-term {
              color: var(--cursor-accent);
              font-weight: 600;
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
              color: var(--code-fg);
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
            .hljs, .cw-hljs-fallback {
              color: var(--code-fg);
              background: transparent;
            }
            code.inline-hljs, code.inline-cw-hljs {
              display: inline;
            }
            .hljs-keyword, .hljs-built_in, .hljs-literal, .hljs-selector-tag {
              color: var(--code-keyword);
            }
            .hljs-title, .hljs-title.class_, .hljs-title.function_ {
              color: var(--code-title);
            }
            .hljs-string, .hljs-regexp, .hljs-template-tag, .hljs-template-variable {
              color: var(--code-string);
            }
            .hljs-number, .hljs-symbol, .hljs-bullet {
              color: var(--code-number);
            }
            .hljs-comment, .hljs-quote {
              color: var(--code-comment);
            }
            .hljs-attr, .hljs-attribute, .hljs-property {
              color: var(--code-attr);
            }
            .cw-token-keyword {
              color: var(--code-keyword);
              font-weight: 600;
            }
            .cw-token-type {
              color: var(--code-title);
            }
            .cw-token-string {
              color: var(--code-string);
            }
            .cw-token-number {
              color: var(--code-number);
            }
            .cw-token-comment {
              color: var(--code-comment);
              font-style: italic;
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
            .latex-cmd-output {
              margin: 1em 0;
              border: 1px solid var(--rule);
              background: var(--code-bg);
              border-radius: 10px;
              padding: 0.75em 0.9em;
            }
            .latex-cmd-output p {
              margin: 0;
              white-space: pre-wrap;
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
            window.ecrivisseApplySyntaxHighlighting = (root) => {
              // Syntax highlighting is pre-rendered from Swift.
              return;
            };

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

              const finalize = () => {
                window.ecrivisseApplySyntaxHighlighting(main);
                restoreScroll();
              };

              if (window.MathJax?.typesetPromise) {
                try {
                  window.MathJax.typesetClear?.([main]);
                } catch (_) {}
                window.MathJax.typesetPromise([main]).then(finalize).catch(finalize);
                return;
              }

              finalize();
            };

            window.addEventListener("load", () => {
              const main = document.querySelector("main.wrap");
              if (!main) { return; }
              window.ecrivisseApplySyntaxHighlighting(main);
            });
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
        let contentLineIndices = extraction.contentLineIndices
        let linkDefinitions = extraction.linkDefinitions
        let footnoteDefinitions = extraction.footnoteDefinitions

        var htmlParts: [String] = []
        var paragraphBuffer: [String] = []
        var paragraphStartSourceLine: Int?
        var listStack: [ListContext] = []
        var footnoteOrder: [String] = []
        var footnoteIndexByID: [String: Int] = [:]
        var tocHeadings: [TOCHeadingEntry] = []
        var tocAnchorCounts: [String: Int] = [:]
        var tocPlaceholderTokens: [String] = []
        var taskItemIndex = 0
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
            let lineAttribute = paragraphStartSourceLine.map { " data-cw-line=\"\($0)\"" } ?? ""
            htmlParts.append("<p\(lineAttribute)>\(inline)</p>")
            paragraphBuffer.removeAll(keepingCapacity: true)
            paragraphStartSourceLine = nil
        }

        func appendListItem(type: ListType, indent: Int, text: String, sourceLine: Int) {
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

            htmlParts.append("<li data-cw-line=\"\(sourceLine)\">\(parseInlineContent(text))")
            listStack[listStack.count - 1].hasOpenListItem = true
        }

        func renderTaskListItemHTML(_ item: TaskListItem, index: Int, sourceLine: Int) -> String {
            let checkedAttribute = item.checked ? " checked" : ""
            return "<li data-cw-line=\"\(sourceLine)\"><input type=\"checkbox\" data-cw-task-index=\"\(index)\"\(checkedAttribute) /><span class=\"task-text\">\(parseInlineContent(item.content))</span></li>"
        }

        while index < lines.count {
            let line = lines[index]
            let sourceLine = index < contentLineIndices.count ? contentLineIndices[index] : index
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if line.range(of: #"^\s*\{\{\s*toc\s*\}\}\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                flushParagraphIfNeeded()
                closeAllLists()
                let token = "@@CWTOC\(tocPlaceholderTokens.count)@@"
                tocPlaceholderTokens.append(token)
                htmlParts.append("<div class=\"cw-toc-slot\" data-cw-line=\"\(sourceLine)\">\(token)</div>")
                index += 1
                continue
            }

            if let fence = captureGroups(in: line, pattern: #"^\s*```([A-Za-z0-9_-]+)?(?:\s+\{([^}]*)\})?\s*$"#) {
                flushParagraphIfNeeded()
                closeAllLists()

                let language = (fence.count > 1 ? fence[1] : "").trimmingCharacters(in: .whitespacesAndNewlines)
                let fenceOptions = (fence.count > 2 ? fence[2] : "").trimmingCharacters(in: .whitespacesAndNewlines)
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
                let rawCode = codeLines.joined(separator: "\n")
                if language.lowercased() == "latex",
                   shouldRenderLaTeXCommandBlock(fenceOptions: fenceOptions),
                   let renderedLaTeX = renderLaTeXCommandBlockHTML(from: rawCode) {
                    htmlParts.append("<div class=\"latex-cmd-output\" data-cw-line=\"\(sourceLine)\"><p>\(renderedLaTeX)</p></div>")
                } else {
                    let highlightedCode = fallbackSyntaxHighlightedCodeHTML(rawCode)
                    let classAttribute = language.isEmpty
                        ? " class=\"cw-hljs-fallback\""
                        : " class=\"language-\(escapeHTML(language)) cw-hljs-fallback\""
                    htmlParts.append("<pre data-cw-line=\"\(sourceLine)\"><code data-cw-prehighlighted=\"1\"\(classAttribute)>\(highlightedCode)</code></pre>")
                }
                if index < lines.count {
                    index += 1
                }
                continue
            }

            if let singleLineMath = parseSingleLineDisplayMath(line) {
                flushParagraphIfNeeded()
                closeAllLists()
                htmlParts.append("<div class=\"math-block\" data-cw-line=\"\(sourceLine)\">\\[\(escapeHTML(singleLineMath))\\]</div>")
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
                htmlParts.append("<div class=\"math-block\" data-cw-line=\"\(sourceLine)\">\\[\(escapeHTML(expression))\\]</div>")
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
                htmlParts.append("<hr data-cw-line=\"\(sourceLine)\"/>")
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

                htmlParts.append("<dl data-cw-line=\"\(sourceLine)\">")
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

                htmlParts.append("<table data-cw-line=\"\(sourceLine)\"><thead><tr>")
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
                let anchorBase = safeAnchorID(for: plainText(fromHTML: content))
                let anchorID = uniqueAnchorID(base: anchorBase, counts: &tocAnchorCounts)
                tocHeadings.append(TOCHeadingEntry(level: level, anchorID: anchorID, titleHTML: content))
                htmlParts.append("<h\(level) id=\"\(anchorID)\" data-cw-line=\"\(sourceLine)\">\(content)</h\(level)>")
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

                htmlParts.append("<blockquote data-cw-line=\"\(sourceLine)\"><p>\(quoteLines.joined(separator: "<br/>"))</p></blockquote>")
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

                htmlParts.append("<ul class=\"task-list\" data-cw-line=\"\(sourceLine)\">")
                for (itemOffset, item) in items.enumerated() {
                    let itemSourceIndex = index + itemOffset
                    let itemSourceLine = itemSourceIndex < contentLineIndices.count ? contentLineIndices[itemSourceIndex] : sourceLine
                    htmlParts.append(renderTaskListItemHTML(item, index: taskItemIndex, sourceLine: itemSourceLine))
                    taskItemIndex += 1
                }
                htmlParts.append("</ul>")

                index = rowIndex
                continue
            }

            if let unordered = captureGroups(in: line, pattern: #"^([ \t]*)([-+*])\s+(.+)$"#) {
                flushParagraphIfNeeded()
                let indent = indentationWidth(unordered[1])
                appendListItem(type: .unordered, indent: indent, text: unordered[3], sourceLine: sourceLine)
                index += 1
                continue
            }

            if let ordered = captureGroups(in: line, pattern: #"^([ \t]*)(\d+)\.\s+(.+)$"#) {
                flushParagraphIfNeeded()
                let indent = indentationWidth(ordered[1])
                appendListItem(type: .ordered, indent: indent, text: ordered[3], sourceLine: sourceLine)
                index += 1
                continue
            }

            closeAllLists()
            if paragraphBuffer.isEmpty {
                paragraphStartSourceLine = sourceLine
            }
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

        var outputHTML = htmlParts.joined(separator: "\n")
        if !tocPlaceholderTokens.isEmpty {
            let tocHTML = makeTOCHTML(from: tocHeadings)
            for token in tocPlaceholderTokens {
                outputHTML = outputHTML.replacingOccurrences(of: token, with: tocHTML)
            }
        }

        return outputHTML
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func fallbackSyntaxHighlightedCodeHTML(_ source: String) -> String {
        var working = source
        var preservedSnippets: [String] = []

        func preserve(_ html: String) -> String {
            let token = "@@CWCODEHL\(preservedSnippets.count)@@"
            preservedSnippets.append(html)
            return token
        }

        working = replacingMatches(in: working, pattern: #"/\*[\s\S]*?\*/"#) { match, ns in
            let tokenText = ns.substring(with: match.range(at: 0))
            return preserve("<span class=\"cw-token-comment\">\(escapeHTML(tokenText))</span>")
        }
        working = replacingMatches(in: working, pattern: #"//[^\n]*"#) { match, ns in
            let tokenText = ns.substring(with: match.range(at: 0))
            return preserve("<span class=\"cw-token-comment\">\(escapeHTML(tokenText))</span>")
        }
        working = replacingMatches(in: working, pattern: #"#[^\n]*"#) { match, ns in
            let tokenText = ns.substring(with: match.range(at: 0))
            return preserve("<span class=\"cw-token-comment\">\(escapeHTML(tokenText))</span>")
        }

        working = replacingMatches(
            in: working,
            pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#
        ) { match, ns in
            let tokenText = ns.substring(with: match.range(at: 0))
            return preserve("<span class=\"cw-token-string\">\(escapeHTML(tokenText))</span>")
        }

        working = replacingMatches(in: working, pattern: #"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#) { match, ns in
            let tokenText = ns.substring(with: match.range(at: 0))
            return preserve("<span class=\"cw-token-number\">\(escapeHTML(tokenText))</span>")
        }

        working = replacingMatches(
            in: working,
            pattern: #"\b(?:and|as|assert|async|await|break|case|catch|class|const|continue|def|default|defer|do|else|enum|export|extends|false|final|finally|for|from|func|function|guard|if|import|in|interface|is|let|match|module|new|nil|null|or|package|pass|private|protected|protocol|public|raise|repeat|return|self|static|struct|super|switch|this|throw|throws|trait|true|try|type|typeof|var|void|when|where|while|with|yield)\b"#
        ) { match, ns in
            let tokenText = ns.substring(with: match.range(at: 0))
            return preserve("<span class=\"cw-token-keyword\">\(escapeHTML(tokenText))</span>")
        }

        working = replacingMatches(
            in: working,
            pattern: #"\b(?:Any|Array|Bool|Dictionary|Double|Float|Int|Map|Optional|Promise|Result|Set|String|Void|None|True|False)\b"#
        ) { match, ns in
            let tokenText = ns.substring(with: match.range(at: 0))
            return preserve("<span class=\"cw-token-type\">\(escapeHTML(tokenText))</span>")
        }

        working = escapeHTML(working)

        for (index, snippet) in preservedSnippets.enumerated() {
            working = working.replacingOccurrences(of: "@@CWCODEHL\(index)@@", with: snippet)
        }
        return working
    }

    private static func shouldRenderLaTeXCommandBlock(fenceOptions: String) -> Bool {
        guard !fenceOptions.isEmpty else { return false }
        let normalized = fenceOptions.lowercased()
        return normalized.range(of: #"\bcmd\s*=\s*true\b"#, options: .regularExpression) != nil
    }

    private static func renderLaTeXCommandBlockHTML(from source: String) -> String? {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        if let groups = captureGroups(
            in: normalized,
            pattern: #"\\begin\{document\}([\s\S]*?)\\end\{document\}"#
        ), groups.count > 1 {
            let inner = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !inner.isEmpty else { return nil }
            return escapeHTML(inner).replacingOccurrences(of: "\n", with: "<br/>")
        }

        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return escapeHTML(trimmed).replacingOccurrences(of: "\n", with: "<br/>")
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
            let highlightedCode = fallbackSyntaxHighlightedCodeHTML(codeText)
            codeSnippets.append("<code data-cw-prehighlighted=\"1\" class=\"cw-hljs-fallback inline-cw-hljs\">\(highlightedCode)</code>")
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
        contentLineIndices: [Int],
        linkDefinitions: [String: LinkReferenceDefinition],
        footnoteDefinitions: [String: String]
    ) {
        var contentLines: [String] = []
        var contentLineIndices: [Int] = []
        var linkDefinitions: [String: LinkReferenceDefinition] = [:]
        var footnoteDefinitions: [String: String] = [:]

        var index = 0
        while index < lines.count {
            let line = lines[index]

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

            contentLines.append(line)
            contentLineIndices.append(index)
            index += 1
        }

        return (contentLines, contentLineIndices, linkDefinitions, footnoteDefinitions)
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

    private static func highlightTaxTerms(in html: String) -> String {
        guard !html.isEmpty else { return html }

        let nonHighlightTagNames: Set<String> = ["code", "pre", "script", "style"]
        var nonHighlightDepth = 0
        var output = ""
        var cursor = html.startIndex

        while cursor < html.endIndex {
            if html[cursor] == "<" {
                guard let closingIndex = html[cursor...].firstIndex(of: ">") else {
                    output += String(html[cursor...])
                    break
                }

                let afterTag = html.index(after: closingIndex)
                let tag = String(html[cursor..<afterTag])
                output += tag

                if let tagName = htmlTagName(in: tag)?.lowercased(),
                   nonHighlightTagNames.contains(tagName) {
                    let trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                    let isClosingTag = trimmedTag.hasPrefix("</")
                    let isSelfClosingTag = trimmedTag.hasSuffix("/>")

                    if isClosingTag {
                        nonHighlightDepth = max(0, nonHighlightDepth - 1)
                    } else if !isSelfClosingTag {
                        nonHighlightDepth += 1
                    }
                }

                cursor = afterTag
                continue
            }

            let nextTagIndex = html[cursor...].firstIndex(of: "<") ?? html.endIndex
            let segment = String(html[cursor..<nextTagIndex])
            if nonHighlightDepth > 0 {
                output += segment
            } else {
                output += highlightTaxTermsInPlainSegment(segment)
            }
            cursor = nextTagIndex
        }

        return output
    }

    private static func highlightTaxTermsInPlainSegment(_ segment: String) -> String {
        guard !segment.isEmpty else { return segment }
        let nsSegment = segment as NSString
        let fullRange = NSRange(location: 0, length: nsSegment.length)
        let matches = taxTermsRegex.matches(in: segment, options: [], range: fullRange)
        guard !matches.isEmpty else { return segment }

        let mutable = NSMutableString(string: segment)
        for match in matches.reversed() {
            let range = match.range(at: 0)
            guard range.location != NSNotFound, range.length > 0 else { continue }
            let matched = nsSegment.substring(with: range)
            let replacement = "<span class=\"cw-tax-term\">\(matched)</span>"
            mutable.replaceCharacters(in: range, with: replacement)
        }
        return mutable as String
    }

    private static func uniqueAnchorID(base: String, counts: inout [String: Int]) -> String {
        let normalizedBase = base.isEmpty ? "section" : base
        let current = counts[normalizedBase, default: 0]
        counts[normalizedBase] = current + 1
        if current == 0 {
            return normalizedBase
        }
        return "\(normalizedBase)-\(current + 1)"
    }

    private static func plainText(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeTOCHTML(from headings: [TOCHeadingEntry]) -> String {
        let filteredHeadings = headings.filter { !$0.titleHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !filteredHeadings.isEmpty else {
            return "<nav class=\"cw-toc\" aria-label=\"Table of contents\"><div class=\"cw-toc-title\">Table of Contents</div><p class=\"cw-toc-empty\">No headings found.</p></nav>"
        }

        var html: [String] = []
        html.append("<nav class=\"cw-toc\" aria-label=\"Table of contents\">")
        html.append("<div class=\"cw-toc-title\">Table of Contents</div>")
        html.append("<ol class=\"cw-toc-list\">")
        for heading in filteredHeadings {
            let level = min(max(heading.level, 1), 6)
            html.append("<li class=\"cw-toc-item cw-toc-level-\(level)\"><a href=\"#\(heading.anchorID)\">\(heading.titleHTML)</a></li>")
        }
        html.append("</ol>")
        html.append("</nav>")
        return html.joined()
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

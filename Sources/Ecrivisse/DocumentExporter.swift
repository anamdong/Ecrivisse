import Foundation
import AppKit
import CoreText
import WebKit
import PDFKit

enum DocumentExporterError: LocalizedError {
    case markdownParseFailed
    case pdfContextCreationFailed
    case previewLoadFailed
    case previewContentSizeUnavailable
    case pdfDocumentCreationFailed

    var errorDescription: String? {
        switch self {
        case .markdownParseFailed:
            return "Markdown could not be parsed for export."
        case .pdfContextCreationFailed:
            return "PDF context could not be created."
        case .previewLoadFailed:
            return "Preview could not be loaded for export."
        case .previewContentSizeUnavailable:
            return "Preview content size could not be measured."
        case .pdfDocumentCreationFailed:
            return "Printed PDF document could not be prepared."
        }
    }
}

enum DocumentExporter {
    private static let previewViewportWidth: CGFloat = 980
    private static let previewViewportHeight: CGFloat = 1200

    static func attributedMarkdown(for markdown: String) throws -> NSAttributedString {
        try makeAttributedMarkdown(markdown: markdown)
    }

    static func exportHTML(markdown: String, to url: URL) throws {
        let html = MarkdownWebRenderer.htmlDocument(from: markdown)
        guard let data = html.data(using: .utf8) else {
            throw DocumentExporterError.markdownParseFailed
        }
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    static func exportPDF(markdown: String, to url: URL) async throws {
        let data = try await previewPDFData(markdown: markdown)
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    static func printPreview(markdown: String) async throws {
        let data = try await previewPDFData(markdown: markdown)
        guard let document = PDFDocument(data: data) else {
            throw DocumentExporterError.pdfDocumentCreationFailed
        }

        guard let operation = document.printOperation(
            for: NSPrintInfo.shared,
            scalingMode: PDFPrintScalingMode.pageScaleToFit,
            autoRotate: true
        ) else {
            throw DocumentExporterError.pdfDocumentCreationFailed
        }
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    @available(macOS 13.0, *)
    static func exportDOCX(markdown: String, to url: URL) throws {
        let attributed = try attributedMarkdown(for: markdown)
        let range = NSRange(location: 0, length: attributed.length)
        let data = try attributed.data(
            from: range,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.officeOpenXML
            ]
        )
        try data.write(to: url, options: .atomic)
    }

    private static func makeAttributedMarkdown(markdown: String) throws -> NSAttributedString {
        let parsedMarkdown: AttributedString
        do {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            parsedMarkdown = try AttributedString(markdown: markdown, options: options)
        } catch {
            throw DocumentExporterError.markdownParseFailed
        }

        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(parsedMarkdown))
        let fullRange = NSRange(location: 0, length: mutable.length)
        if fullRange.length > 0 {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 6
            paragraphStyle.paragraphSpacing = 8
            paragraphStyle.lineBreakMode = .byWordWrapping
            mutable.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

            mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                if value == nil {
                    mutable.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: range)
                }
            }
            mutable.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
                if value == nil {
                    mutable.addAttribute(.foregroundColor, value: NSColor.black, range: range)
                }
            }
        }

        return mutable
    }

    private static func makePDFData(from attributed: NSAttributedString) throws -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let textRect = pageRect.insetBy(dx: 64, dy: 72)

        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else {
            throw DocumentExporterError.pdfContextCreationFailed
        }

        var mediaBox = pageRect
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw DocumentExporterError.pdfContextCreationFailed
        }

        if attributed.length == 0 {
            context.beginPDFPage(nil)
            context.endPDFPage()
            context.closePDF()
            return mutableData as Data
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        var currentRange = CFRange(location: 0, length: 0)

        while currentRange.location < attributed.length {
            context.beginPDFPage(nil)
            context.saveGState()
            context.textMatrix = .identity

            let path = CGMutablePath()
            path.addRect(textRect)
            let frame = CTFramesetterCreateFrame(framesetter, currentRange, path, nil)
            CTFrameDraw(frame, context)

            let visibleRange = CTFrameGetVisibleStringRange(frame)
            context.restoreGState()
            context.endPDFPage()

            guard visibleRange.length > 0 else { break }
            currentRange.location += visibleRange.length
        }

        context.closePDF()
        return mutableData as Data
    }

    @MainActor
    private static func makeLoadedPreviewWebView(markdown: String) async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: previewViewportWidth, height: previewViewportHeight),
            configuration: config
        )
        webView.setValue(false, forKey: "drawsBackground")

        let loader = PreviewLoadObserver()
        webView.navigationDelegate = loader
        webView.loadHTMLString(MarkdownWebRenderer.htmlDocument(from: markdown), baseURL: nil)
        try await loader.waitUntilLoaded()
        return webView
    }

    @MainActor
    private static func previewPDFData(markdown: String) async throws -> Data {
        let webView = try await makeLoadedPreviewWebView(markdown: markdown)
        let contentHeight = try await measurePreviewContentHeight(in: webView)
        let exportHeight = max(previewViewportHeight, contentHeight)

        let config = WKPDFConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: previewViewportWidth, height: exportHeight)
        return try await createPDFData(from: webView, configuration: config)
    }

    @MainActor
    private static func measurePreviewContentHeight(in webView: WKWebView) async throws -> CGFloat {
        let script = """
        Math.max(
          document.body.scrollHeight || 0,
          document.documentElement.scrollHeight || 0,
          document.body.offsetHeight || 0,
          document.documentElement.offsetHeight || 0
        );
        """

        let result = try await webView.evaluateJavaScript(script)
        if let number = result as? NSNumber {
            return CGFloat(number.doubleValue)
        }
        if let doubleValue = result as? Double {
            return CGFloat(doubleValue)
        }
        throw DocumentExporterError.previewContentSizeUnavailable
    }

    @MainActor
    private static func createPDFData(from webView: WKWebView, configuration: WKPDFConfiguration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: configuration) { result in
                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
private final class PreviewLoadObserver: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func waitUntilLoaded() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(returning: ())
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

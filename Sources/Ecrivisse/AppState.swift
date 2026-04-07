import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppState: NSObject, ObservableObject, NSWindowDelegate {
    @Published var text: String = ""
    @Published var isPreviewPanelVisible: Bool = false
    @Published var focusMode: FocusMode = .off
    @Published var editorFontSize: CGFloat = 17
    @Published var useDarkMode: Bool = false
    @Published var summarizeDocumentRequestID: Int = 0
    @Published var documentURL: URL? {
        didSet { refreshWindowDocumentMetadata() }
    }
    @Published var isDirty: Bool = false {
        didSet { refreshWindowDocumentMetadata() }
    }
    @Published var errorMessage: String?

    private weak var configuredWindow: NSWindow?
    let minimumEditorFontSize: CGFloat = 12
    let maximumEditorFontSize: CGFloat = 30
    private let defaultDocumentTitle = "Untitled.md"
    private let minimumWindowFrameSize = NSSize(width: 660, height: 500)
    private let minimumWindowContentSize = NSSize(width: 620, height: 420)
    private var isProgrammaticCloseInProgress = false

    var canExportDOCX: Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }

    func userEdited(text newValue: String) {
        if text != newValue {
            text = newValue
        }
        isDirty = true
    }

    func togglePreviewPanel() {
        isPreviewPanelVisible.toggle()
    }

    func showPreviewPanel() {
        isPreviewPanelVisible = true
    }

    func hidePreviewPanel() {
        isPreviewPanelVisible = false
    }

    func cycleFocusMode() {
        focusMode = focusMode.next()
    }

    func increaseEditorFontSize() {
        setEditorFontSize(editorFontSize + 1)
    }

    func decreaseEditorFontSize() {
        setEditorFontSize(editorFontSize - 1)
    }

    func setEditorFontSize(_ newValue: CGFloat) {
        editorFontSize = min(max(newValue, minimumEditorFontSize), maximumEditorFontSize)
    }

    func toggleDarkMode() {
        useDarkMode.toggle()
        if let configuredWindow {
            applyAppearance(to: configuredWindow)
        }
    }

    func requestDocumentSummaryUsingAI() {
        summarizeDocumentRequestID &+= 1
    }

    var characterCount: Int {
        text.count
    }

    var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    func configure(window: NSWindow?) {
        guard let window else { return }

        if configuredWindow !== window {
            configuredWindow = window

            window.styleMask.insert(.titled)
            window.styleMask.insert(.closable)
            window.styleMask.insert(.miniaturizable)
            window.styleMask.insert(.resizable)
            window.styleMask.insert(.fullSizeContentView)
            window.minSize = minimumWindowFrameSize
            window.contentMinSize = minimumWindowContentSize
            window.delegate = self
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = true
            window.toolbar = nil
            window.tabbingMode = .disallowed
            window.isMovableByWindowBackground = true
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenAllowsTiling)
            window.backgroundColor = .textBackgroundColor
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }

            let buttons: [NSWindow.ButtonType] = [
                .closeButton,
                .miniaturizeButton,
                .zoomButton
            ]
            for button in buttons {
                guard let control = window.standardWindowButton(button) else { continue }
                control.isHidden = false
                control.isEnabled = true
                control.alphaValue = 1
            }
            if let closeButton = window.standardWindowButton(.closeButton) {
                closeButton.target = self
                closeButton.action = #selector(closeButtonPressed(_:))
            }
            clampWindowSizeIfNeeded(window)
        }

        applyAppearance(to: window)
        refreshWindowDocumentMetadata()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === configuredWindow else { return true }
        if isProgrammaticCloseInProgress {
            return true
        }
        return confirmCloseWithSaveIfNeeded()
    }

    func requestCloseWindow() {
        guard let window = configuredWindow else { return }
        guard confirmCloseWithSaveIfNeeded() else { return }

        isProgrammaticCloseInProgress = true
        window.close()
        isProgrammaticCloseInProgress = false
    }

    @objc
    private func closeButtonPressed(_ sender: Any?) {
        requestCloseWindow()
    }

    private func confirmCloseWithSaveIfNeeded() -> Bool {
        guard isDirty else { return true }
        let displayName = documentURL?.lastPathComponent ?? defaultDocumentTitle
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save changes to \"\(displayName)\"?"
        alert.informativeText = "Your changes will be lost if you close this window without saving."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            if documentURL != nil {
                saveDocument()
            } else {
                saveDocumentAs()
            }
            return !isDirty
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func applyAppearance(to window: NSWindow) {
        window.appearance = NSAppearance(named: useDarkMode ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
    }

    private func clampWindowSizeIfNeeded(_ window: NSWindow) {
        let adjustedFrameWidth = max(window.frame.width, minimumWindowFrameSize.width)
        let adjustedFrameHeight = max(window.frame.height, minimumWindowFrameSize.height)
        guard abs(window.frame.width - adjustedFrameWidth) > 0.5 || abs(window.frame.height - adjustedFrameHeight) > 0.5 else {
            return
        }

        var adjustedFrame = window.frame
        adjustedFrame.size = NSSize(width: adjustedFrameWidth, height: adjustedFrameHeight)
        window.setFrame(adjustedFrame, display: true)
    }

    private func refreshWindowDocumentMetadata() {
        guard let window = configuredWindow else { return }

        window.title = documentURL?.lastPathComponent ?? defaultDocumentTitle
        window.representedURL = documentURL
        window.isDocumentEdited = isDirty

        if let documentIconButton = window.standardWindowButton(.documentIconButton) {
            documentIconButton.isHidden = documentURL == nil
            documentIconButton.isEnabled = documentURL != nil
        }
    }

    func newDocument() {
        guard confirmDiscardIfNeeded() else { return }
        text = ""
        documentURL = nil
        isDirty = false
    }

    func openDocument() {
        guard confirmDiscardIfNeeded() else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = openableContentTypes()
        panel.prompt = "Open"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try openDocument(at: url, shouldConfirmDiscard: false)
        } catch {
            present(error: error)
        }
    }

    func openDocument(at url: URL) {
        do {
            try openDocument(at: url, shouldConfirmDiscard: true)
        } catch {
            present(error: error)
        }
    }

    func saveDocument() {
        if let documentURL {
            writeDocument(to: documentURL)
        } else {
            saveDocumentAs()
        }
    }

    func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = savableContentTypes()
        panel.nameFieldStringValue = suggestedSaveName()
        panel.prompt = "Save"

        if let currentURL = documentURL {
            panel.directoryURL = currentURL.deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeDocument(to: url)
    }

    func exportPDF() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = exportName(fileExtension: "pdf")
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let markdown = text
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await DocumentExporter.exportPDF(markdown: markdown, to: url)
            } catch {
                self.present(error: error)
            }
        }
    }

    func exportHTML() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = exportName(fileExtension: "html")
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try DocumentExporter.exportHTML(markdown: text, to: url)
        } catch {
            present(error: error)
        }
    }

    func exportDOCX() {
        guard #available(macOS 13.0, *) else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        if let docxType = UTType(filenameExtension: "docx") {
            panel.allowedContentTypes = [docxType]
        }
        panel.nameFieldStringValue = exportName(fileExtension: "docx")
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try DocumentExporter.exportDOCX(markdown: text, to: url)
        } catch {
            present(error: error)
        }
    }

    func printDocument() {
        let markdown = text
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await DocumentExporter.printPreview(markdown: markdown)
            } catch {
                self.present(error: error)
            }
        }
    }

    private func writeDocument(to url: URL) {
        do {
            guard let data = text.data(using: .utf8) else {
                throw AppStateError.utf8EncodingFailed
            }
            try data.write(to: url, options: .atomic)
            documentURL = url
            isDirty = false
        } catch {
            present(error: error)
        }
    }

    private func suggestedSaveName() -> String {
        if let documentURL {
            return documentURL.lastPathComponent
        }
        return "Untitled.md"
    }

    private func exportName(fileExtension: String) -> String {
        let base = documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return "\(base).\(fileExtension)"
    }

    private func present(error: Error) {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            errorMessage = description
            return
        }
        errorMessage = error.localizedDescription
    }

    private func confirmDiscardIfNeeded() -> Bool {
        guard isDirty else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "The current document has unsaved edits."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func readText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let fileExtension = url.pathExtension.lowercased()

        if fileExtension == "rtf",
           let attributed = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            return attributed.string
        }

        if (fileExtension == "html" || fileExtension == "htm"),
           let attributed = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.html],
               documentAttributes: nil
           ) {
            return attributed.string
        }

        if let value = String(data: data, encoding: .utf8) {
            return value
        }
        if let value = String(data: data, encoding: .utf16) {
            return value
        }
        if let value = String(data: data, encoding: .unicode) {
            return value
        }
        throw AppStateError.unreadableTextEncoding
    }

    private func openDocument(at url: URL, shouldConfirmDiscard: Bool) throws {
        if shouldConfirmDiscard {
            guard confirmDiscardIfNeeded() else { return }
        }
        text = try Self.readText(from: url)
        documentURL = url
        isDirty = false
    }

    private func openableContentTypes() -> [UTType] {
        var types: [UTType] = [.plainText, .text]
        let extensions = [
            "md", "markdown", "txt", "text", "rtf",
            "html", "htm", "xml", "json", "csv", "tsv",
            "log", "yaml", "yml"
        ]
        for fileExtension in extensions {
            if let type = UTType(filenameExtension: fileExtension) {
                types.append(type)
            }
        }
        return types
    }

    private func savableContentTypes() -> [UTType] {
        var types: [UTType] = []
        if let md = UTType(filenameExtension: "md") {
            types.append(md)
        }
        types.append(.plainText)
        return types
    }
}

enum AppStateError: LocalizedError {
    case utf8EncodingFailed
    case unreadableTextEncoding

    var errorDescription: String? {
        switch self {
        case .utf8EncodingFailed:
            return "The document could not be encoded as UTF-8."
        case .unreadableTextEncoding:
            return "The selected file is not a supported plain-text encoding."
        }
    }
}

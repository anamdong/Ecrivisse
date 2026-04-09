import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppState: NSObject, ObservableObject, NSWindowDelegate {
    static let defaultEditorCursorNSColor: NSColor = NSColor(
        calibratedRed: 1.0,
        green: 0.302,
        blue: 0.251,
        alpha: 1.0
    ) // #ff4d40
    static let defaultEditorCursorColor: Color = Color(nsColor: defaultEditorCursorNSColor)
    private static let useDarkModeDefaultsKey = "ecrivisse.useDarkMode"

    @Published var text: String = ""
    @Published var isPreviewPanelVisible: Bool = false
    @Published var focusMode: FocusMode = .off
    @Published var editorFontSize: CGFloat = 17
    @Published var useDarkMode: Bool = UserDefaults.standard.object(forKey: AppState.useDarkModeDefaultsKey) as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(useDarkMode, forKey: Self.useDarkModeDefaultsKey)
        }
    }
    @Published var previewFontOption: PreviewFontOption = .serif
    @Published var floatingToolbarPosition: FloatingToolbarPosition = .bottom
    @Published private var editorCursorColorHexStorage: String = AppState.defaultEditorCursorColorHex
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
    private let minimumWindowFrameSize = NSSize(width: 860, height: 560)
    private let minimumWindowContentSize = NSSize(width: 820, height: 500)
    private var isProgrammaticCloseInProgress = false
    private var shouldRevealWhenWindowConfigures = false
    private static let taskListMarkerRegex = try! NSRegularExpression(
        pattern: #"(?m)^([ \t]*[-+*][ \t]+\[)([ xX])(\][ \t]*)"#,
        options: []
    )
    private static let supportedOpenFileExtensions: [String] = [
        "md", "markdown", "txt", "text", "rtf",
        "html", "htm", "xml", "json", "csv", "tsv",
        "log", "yaml", "yml"
    ]
    private static let supportedOpenFileExtensionSet: Set<String> = Set(supportedOpenFileExtensions)

    static var supportedSidebarFileExtensions: Set<String> {
        supportedOpenFileExtensionSet
    }

    static var defaultEditorCursorColorHex: String {
        cssHexString(from: defaultEditorCursorNSColor)
    }

    var editorCursorColorHex: String {
        editorCursorColorHexStorage
    }

    var editorCursorNSColor: NSColor {
        Self.nsColor(from: editorCursorColorHexStorage)
    }

    var editorCursorColor: Color {
        Color(nsColor: editorCursorNSColor)
    }

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

    func setTaskListItemChecked(at index: Int, checked: Bool) {
        guard index >= 0 else { return }

        if let textView = activeWriterTextView(),
           textView.setTaskListItemChecked(at: index, checked: checked) {
            let updatedText = textView.string
            if text != updatedText {
                text = updatedText
            }
            isDirty = true
            return
        }

        let updated = Self.markdownBySettingTaskItem(in: text, index: index, checked: checked)
        guard updated != text else { return }
        text = updated
        isDirty = true
    }

    func scrollEditorToSourceLine(_ line: Int) {
        guard line >= 0 else { return }
        guard let textView = activeWriterTextView() else { return }
        textView.scrollToSourceLine(line)
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

    func setEditorCursorColor(_ color: Color) {
        setEditorCursorNSColor(NSColor(color))
    }

    func setEditorCursorNSColor(_ color: NSColor) {
        editorCursorColorHexStorage = Self.cssHexString(from: color)
    }

    func resetEditorCursorColorToDefault() {
        editorCursorColorHexStorage = Self.defaultEditorCursorColorHex
    }

    func applyEditorAction(_ action: MarkdownEditorAction) {
        guard let textView = activeWriterTextView() else { return }
        textView.applyMarkdownAction(action)
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
            window.tabbingMode = .preferred
            window.tabbingIdentifier = "ecrivisse-document"
            window.isMovableByWindowBackground = true
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenAllowsTiling)
            window.backgroundColor = windowChromeBackgroundColor
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
        if shouldRevealWhenWindowConfigures || ExternalFileOpenRouter.shared.hasPendingFileURLs {
            shouldRevealWhenWindowConfigures = false
            reveal(window: window)
        }
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
        window.backgroundColor = windowChromeBackgroundColor
    }

    private var windowChromeBackgroundColor: NSColor {
        if useDarkMode {
            return .textBackgroundColor
        }
        return NSColor(calibratedWhite: 0.95, alpha: 1.0)
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

    func windowForTabOperations() -> NSWindow? {
        configuredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    func requestNewTab() {
        NSWindow.allowsAutomaticWindowTabbing = true
        guard let sourceWindow = windowForTabOperations() else {
            _ = NSApp.sendAction(NSSelectorFromString("newWindow:"), to: nil, from: nil)
            return
        }
        sourceWindow.tabbingMode = .preferred
        sourceWindow.tabbingIdentifier = "ecrivisse-document"

        let existingWindowIDs = Set(NSApp.windows.map(ObjectIdentifier.init))
        if !NSApp.sendAction(NSSelectorFromString("newWindowForTab:"), to: nil, from: nil) {
            _ = NSApp.sendAction(NSSelectorFromString("newWindow:"), to: nil, from: nil)
        }

        attachCreatedWindowAsTab(
            sourceWindow: sourceWindow,
            existingWindowIDs: existingWindowIDs
        )
    }

    private func attachCreatedWindowAsTab(
        sourceWindow: NSWindow,
        existingWindowIDs: Set<ObjectIdentifier>,
        retryCount: Int = 0
    ) {
        let candidateWindows = NSApp.windows.filter { window in
            window !== sourceWindow &&
            !existingWindowIDs.contains(ObjectIdentifier(window)) &&
            window.canBecomeMain &&
            !window.isExcludedFromWindowsMenu
        }

        if let targetWindow = candidateWindows.first {
            targetWindow.tabbingMode = .preferred
            targetWindow.tabbingIdentifier = "ecrivisse-document"

            if targetWindow.tabGroup !== sourceWindow.tabGroup {
                sourceWindow.addTabbedWindow(targetWindow, ordered: .above)
            }

            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            targetWindow.makeKeyAndOrderFront(nil)
            return
        }

        guard retryCount < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.attachCreatedWindowAsTab(
                sourceWindow: sourceWindow,
                existingWindowIDs: existingWindowIDs,
                retryCount: retryCount + 1
            )
        }
    }

    func revealConfiguredWindow() {
        guard let configuredWindow else {
            shouldRevealWhenWindowConfigures = true
            return
        }
        shouldRevealWhenWindowConfigures = false
        reveal(window: configuredWindow)
    }

    private func reveal(window: NSWindow) {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
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
        _ = openDocument(at: url, shouldConfirmDiscard: false)
    }

    @discardableResult
    func openDocument(at url: URL) -> Bool {
        openDocument(at: url, shouldConfirmDiscard: shouldPromptToDiscardCurrentDocument())
    }

    @discardableResult
    private func openDocument(at url: URL, shouldConfirmDiscard: Bool) -> Bool {
        do {
            try loadDocument(at: url, shouldConfirmDiscard: shouldConfirmDiscard)
            return true
        } catch {
            present(error: error)
            return false
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
        let previewFont = previewFontOption
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await DocumentExporter.exportPDF(markdown: markdown, to: url, previewFont: previewFont)
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
            try DocumentExporter.exportHTML(markdown: text, to: url, previewFont: previewFontOption)
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
        let previewFont = previewFontOption
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await DocumentExporter.printPreview(markdown: markdown, previewFont: previewFont)
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
        guard shouldPromptToDiscardCurrentDocument() else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "The current document has unsaved edits."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func shouldPromptToDiscardCurrentDocument() -> Bool {
        guard isDirty else { return false }

        if documentURL != nil {
            return true
        }

        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private static func markdownBySettingTaskItem(in source: String, index: Int, checked: Bool) -> String {
        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)
        let matches = taskListMarkerRegex.matches(in: source, options: [], range: fullRange)
        guard index < matches.count else { return source }

        let target = matches[index]
        guard target.numberOfRanges > 2 else { return source }
        let stateRange = target.range(at: 2)
        guard stateRange.location != NSNotFound, stateRange.length > 0 else { return source }

        let replacement = checked ? "x" : " "
        let existing = nsSource.substring(with: stateRange)
        if existing == replacement {
            return source
        }

        let mutable = NSMutableString(string: source)
        mutable.replaceCharacters(in: stateRange, with: replacement)
        return mutable as String
    }

    private func activeWriterTextView() -> WriterTextView? {
        if let firstResponder = configuredWindow?.firstResponder as? WriterTextView {
            return firstResponder
        }

        let candidateWindow = configuredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let firstResponder = candidateWindow?.firstResponder as? WriterTextView {
            return firstResponder
        }

        return findWriterTextView(in: candidateWindow?.contentView)
    }

    private func findWriterTextView(in view: NSView?) -> WriterTextView? {
        guard let view else { return nil }
        if let writerTextView = view as? WriterTextView {
            return writerTextView
        }
        for child in view.subviews {
            if let match = findWriterTextView(in: child) {
                return match
            }
        }
        return nil
    }

    private func loadDocument(at url: URL, shouldConfirmDiscard: Bool) throws {
        if shouldConfirmDiscard {
            guard confirmDiscardIfNeeded() else { return }
        }
        text = try Self.readText(from: url)
        documentURL = url
        isDirty = false
    }

    private func openableContentTypes() -> [UTType] {
        var types: [UTType] = [.plainText, .text]
        for fileExtension in Self.supportedOpenFileExtensions {
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

    private static func normalizedNSColor(from color: NSColor) -> NSColor {
        if let extended = color.usingColorSpace(.extendedSRGB) {
            return NSColor(
                calibratedRed: extended.redComponent,
                green: extended.greenComponent,
                blue: extended.blueComponent,
                alpha: extended.alphaComponent
            )
        }

        if let rgb = color.usingColorSpace(.deviceRGB) {
            return rgb
        }
        if let srgb = color.usingColorSpace(.sRGB),
           let rgb = srgb.usingColorSpace(.deviceRGB) {
            return rgb
        }
        if let converted = NSColor(cgColor: color.cgColor)?.usingColorSpace(.deviceRGB) {
            return converted
        }
        return defaultEditorCursorNSColor
    }

    private static func nsColor(from hex: String) -> NSColor {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
            return defaultEditorCursorNSColor
        }

        let red = CGFloat((value >> 16) & 0xFF) / 255.0
        let green = CGFloat((value >> 8) & 0xFF) / 255.0
        let blue = CGFloat(value & 0xFF) / 255.0
        return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1.0)
    }

    private static func cssHexString(from color: NSColor) -> String {
        let nsColor = normalizedNSColor(from: color)

        let red = Int((max(0, min(1, nsColor.redComponent)) * 255).rounded())
        let green = Int((max(0, min(1, nsColor.greenComponent)) * 255).rounded())
        let blue = Int((max(0, min(1, nsColor.blueComponent)) * 255).rounded())

        return String(format: "#%02X%02X%02X", red, green, blue)
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

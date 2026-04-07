import SwiftUI
import AppKit

struct WriterEditorView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var focusMode: FocusMode
    var summarizeDocumentRequestID: Int
    var onHorizontalSwipe: (CGFloat) -> Void
    var onAIError: (String) -> Void
    var onUserEdit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 2
        layoutManager.addTextContainer(textContainer)

        let textView = WriterTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize), textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.autoresizingMask = [.width]
        textView.editorFontSize = fontSize
        textView.onAIError = { [weak coordinator = context.coordinator] message in
            coordinator?.handleAIError(message)
        }
        textView.onCompositionCommit = { [weak coordinator = context.coordinator] in
            coordinator?.flushComposedText()
        }
        textView.onHorizontalSwipe = { [weak coordinator = context.coordinator] normalizedDeltaX in
            coordinator?.handleHorizontalSwipe(normalizedDeltaX)
        }
        textView.string = text
        textView.focusMode = focusMode
        textView.scheduleStyling(reason: .fullRefresh)

        scrollView.documentView = textView
        context.coordinator.attach(textView: textView, scrollView: scrollView)

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        guard let textView = context.coordinator.textView else { return }
        textView.editorFontSize = fontSize
        textView.focusMode = focusMode
        textView.onAIError = { [weak coordinator = context.coordinator] message in
            coordinator?.handleAIError(message)
        }
        textView.onCompositionCommit = { [weak coordinator = context.coordinator] in
            coordinator?.flushComposedText()
        }
        textView.onHorizontalSwipe = { [weak coordinator = context.coordinator] normalizedDeltaX in
            coordinator?.handleHorizontalSwipe(normalizedDeltaX)
        }

        if textView.hasMarkedText() {
            return
        }

        if textView.string != text {
            context.coordinator.isApplyingExternalChange = true
            let currentSelection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            let location = min(currentSelection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.scheduleStyling(reason: .fullRefresh)
            context.coordinator.isApplyingExternalChange = false
        }

        textView.handleSummarizeDocumentRequestIfNeeded(requestID: summarizeDocumentRequestID)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WriterEditorView
        weak var textView: WriterTextView?
        var isApplyingExternalChange = false
        private var boundsObserver: NSObjectProtocol?

        init(parent: WriterEditorView) {
            self.parent = parent
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func attach(textView: WriterTextView, scrollView: NSScrollView) {
            self.textView = textView
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak textView] _ in
                textView?.scheduleStyling(reason: .visibleRangeChanged)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            guard !isApplyingExternalChange else { return }
            if textView.hasMarkedText() {
                return
            }
            let value = textView.string
            parent.text = value
            parent.onUserEdit(value)
            textView.scheduleStyling(reason: .textChanged)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if textView?.hasMarkedText() == true {
                return
            }
            textView?.scheduleStyling(reason: .selectionChanged)
        }

        func handleHorizontalSwipe(_ normalizedDeltaX: CGFloat) {
            parent.onHorizontalSwipe(normalizedDeltaX)
        }

        func handleAIError(_ message: String) {
            parent.onAIError(message)
        }

        func flushComposedText() {
            guard let textView else { return }
            guard !isApplyingExternalChange else { return }
            let value = textView.string
            parent.text = value
            parent.onUserEdit(value)
            textView.scheduleStyling(reason: .textChanged)
        }
    }
}

final class WriterTextView: NSTextView {
    enum StylingReason {
        case textChanged
        case selectionChanged
        case visibleRangeChanged
        case focusModeChanged
        case fullRefresh
        case aiAnimationTick
    }

    struct StylingInput {
        let text: String
        let selection: NSRange
        let focusMode: FocusMode
        let isDarkMode: Bool
    }

    struct StylePlan {
        let textLength: Int
        let focusRange: NSRange?
        let isDarkMode: Bool
    }

    var focusMode: FocusMode = .off {
        didSet {
            guard oldValue != focusMode else { return }
            scheduleStyling(reason: .focusModeChanged)
        }
    }

    var editorFontSize: CGFloat = 17 {
        didSet {
            let clampedValue = Self.clampedFontSize(editorFontSize)
            if clampedValue != editorFontSize {
                editorFontSize = clampedValue
                return
            }
            guard abs(oldValue - editorFontSize) > 0.001 else { return }
            font = Self.editorFont(size: editorFontSize)
            refreshTypingAttributes()
            scheduleStyling(reason: .fullRefresh)
        }
    }

    var onCompositionCommit: (() -> Void)?
    var onHorizontalSwipe: ((CGFloat) -> Void)?
    var onAIError: ((String) -> Void)?

    private static let cursorColorLight = NSColor(calibratedRed: 1.0, green: 0.302, blue: 0.251, alpha: 0.98) // #ff4d40
    private static let cursorColorDark = NSColor(calibratedRed: 1.0, green: 0.302, blue: 0.251, alpha: 0.98) // #ff4d40
    private static let baseParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 8
        style.paragraphSpacing = 12
        style.lineBreakMode = .byWordWrapping
        return style
    }()

    private let stylingQueue = DispatchQueue(label: "ecrivisse.styling", qos: .userInitiated)
    private var pendingWork: DispatchWorkItem?
    private var styleGeneration: Int = 0
    private var applyingStyle = false
    private var isUpdatingColumnLayout = false
    private var hasDeferredStyleForComposition = false
    private var horizontalSwipeAccumulator: CGFloat = 0
    private var didEmitHorizontalSwipe = false
    private var lastHandledSummarizeDocumentRequestID: Int = -1
    private var isRunningAITask = false
    private var aiGeneratedRanges: [NSRange] = []
    private var aiGradientPhase: CGFloat = 0
    private var aiGradientTimer: Timer?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configureEditor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureEditor()
    }

    deinit {
        pendingWork?.cancel()
        aiGradientTimer?.invalidate()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateColumnLayout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateCursorColor()
        scheduleStyling(reason: .fullRefresh)
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionCommit?()
        if hasDeferredStyleForComposition {
            hasDeferredStyleForComposition = false
            scheduleStyling(reason: .fullRefresh)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "b":
                applyMarkdownEmphasis(marker: "**")
                return
            case "i":
                applyMarkdownEmphasis(marker: "*")
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        handleHorizontalSwipeEvent(event)
        super.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu(title: "Context")
        let selection = Self.clamp(range: selectedRange(), upperBound: (string as NSString).length)
        guard selection.length > 0 else { return menu }

        menu.addItem(.separator())
        let summarizeItem = NSMenuItem(
            title: isRunningAITask ? "Summarizing…" : "Summarize using AI",
            action: #selector(summarizeSelectionUsingAIFromMenu(_:)),
            keyEquivalent: ""
        )
        summarizeItem.target = self
        summarizeItem.isEnabled = !isRunningAITask
        menu.addItem(summarizeItem)
        return menu
    }

    func handleSummarizeDocumentRequestIfNeeded(requestID: Int) {
        guard requestID > 0 else { return }
        guard requestID != lastHandledSummarizeDocumentRequestID else { return }
        lastHandledSummarizeDocumentRequestID = requestID
        summarizeCurrentDocumentUsingAI()
    }

    func scheduleStyling(reason: StylingReason) {
        guard !applyingStyle else { return }
        if hasMarkedText() {
            hasDeferredStyleForComposition = true
            pendingWork?.cancel()
            return
        }

        styleGeneration += 1
        let generation = styleGeneration
        let input = captureStylingInput()
        pendingWork?.cancel()

        let delay: TimeInterval
        switch reason {
        case .focusModeChanged, .fullRefresh, .aiAnimationTick:
            delay = 0
        case .selectionChanged, .visibleRangeChanged:
            delay = 0.03
        case .textChanged:
            delay = 0.09
        }

        let work = DispatchWorkItem { [weak self] in
            let plan = Self.makeStylePlan(from: input)
            DispatchQueue.main.async {
                guard let self else { return }
                guard generation == self.styleGeneration else { return }
                self.apply(plan: plan)
            }
        }
        pendingWork = work
        stylingQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func configureEditor() {
        allowsUndo = true
        isEditable = true
        isSelectable = true
        isRichText = false
        importsGraphics = false
        usesFindBar = true

        isAutomaticDashSubstitutionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isGrammarCheckingEnabled = false
        isContinuousSpellCheckingEnabled = false

        drawsBackground = false
        backgroundColor = .clear
        textColor = .labelColor
        updateCursorColor()
        font = Self.editorFont(size: editorFontSize)

        isHorizontallyResizable = false
        isVerticallyResizable = true
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        textContainer?.lineFragmentPadding = 2
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false

        updateColumnLayout()
        refreshTypingAttributes()
    }

    private func updateColumnLayout() {
        guard !isUpdatingColumnLayout else { return }
        guard let textContainer else { return }

        let targetColumnWidth: CGFloat = 760
        let horizontalInset = max(28, (bounds.width - targetColumnWidth) / 2)
        let desiredInset = NSSize(width: horizontalInset, height: 72)

        let usableWidth = max(240, bounds.width - (horizontalInset * 2))
        let desiredContainerSize = NSSize(width: usableWidth, height: .greatestFiniteMagnitude)

        let epsilon: CGFloat = 0.5
        let insetChanged =
            abs(textContainerInset.width - desiredInset.width) > epsilon ||
            abs(textContainerInset.height - desiredInset.height) > epsilon
        let sizeChanged =
            abs(textContainer.containerSize.width - desiredContainerSize.width) > epsilon ||
            abs(textContainer.containerSize.height - desiredContainerSize.height) > epsilon

        guard insetChanged || sizeChanged else { return }

        isUpdatingColumnLayout = true
        defer { isUpdatingColumnLayout = false }

        if insetChanged {
            textContainerInset = desiredInset
        }
        if sizeChanged {
            textContainer.containerSize = desiredContainerSize
        }
    }

    private func refreshTypingAttributes() {
        typingAttributes = Self.baseAttributes(foreground: .labelColor, fontSize: editorFontSize)
    }

    private func updateCursorColor() {
        let isDarkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        insertionPointColor = isDarkMode ? Self.cursorColorDark : Self.cursorColorLight
    }

    private func captureStylingInput() -> StylingInput {
        let content = string
        let totalLength = (content as NSString).length
        let selection = Self.clamp(range: selectedRange(), upperBound: totalLength)
        let isDarkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        return StylingInput(
            text: content,
            selection: selection,
            focusMode: focusMode,
            isDarkMode: isDarkMode
        )
    }

    private static func makeStylePlan(from input: StylingInput) -> StylePlan {
        let nsText = input.text as NSString
        return StylePlan(
            textLength: nsText.length,
            focusRange: focusedRange(for: input.focusMode, selection: input.selection, text: nsText),
            isDarkMode: input.isDarkMode
        )
    }

    private func apply(plan: StylePlan) {
        guard let textStorage else { return }
        if hasMarkedText() {
            hasDeferredStyleForComposition = true
            return
        }
        guard textStorage.length == plan.textLength else {
            scheduleStyling(reason: .fullRefresh)
            return
        }

        applyingStyle = true

        let fullRange = NSRange(location: 0, length: textStorage.length)
        let baseColor = NSColor.labelColor
        let dimColor = baseColor.withAlphaComponent(0.34)

        textStorage.beginEditing()
        if let focusRange = plan.focusRange, focusRange.length > 0 {
            textStorage.setAttributes(
                Self.baseAttributes(foreground: dimColor, fontSize: editorFontSize),
                range: fullRange
            )
            if NSMaxRange(focusRange) <= textStorage.length {
                textStorage.addAttributes(
                    Self.baseAttributes(foreground: baseColor, fontSize: editorFontSize),
                    range: focusRange
                )
            }
        } else {
            textStorage.setAttributes(
                Self.baseAttributes(foreground: baseColor, fontSize: editorFontSize),
                range: fullRange
            )
        }

        applyAIGradientIfNeeded(to: textStorage, darkMode: plan.isDarkMode)
        textStorage.endEditing()

        refreshTypingAttributes()
        applyingStyle = false
    }

    private static func focusedRange(for mode: FocusMode, selection: NSRange, text: NSString) -> NSRange? {
        guard text.length > 0 else { return nil }
        let selection = clamp(range: selection, upperBound: text.length)
        let location = min(selection.location, max(0, text.length - 1))
        let seed = NSRange(location: location, length: 0)

        switch mode {
        case .off:
            return nil
        case .sentence:
            return sentenceRange(in: text, around: location)
        case .paragraph:
            return text.paragraphRange(for: seed)
        }
    }

    private static func sentenceRange(in text: NSString, around location: Int) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let probe = min(max(0, location), text.length - 1)
        let fullRange = NSRange(location: 0, length: text.length)

        let tagger = NSLinguisticTagger(tagSchemes: [.tokenType], options: 0)
        tagger.string = text as String

        var foundRange: NSRange?
        tagger.enumerateTags(
            in: fullRange,
            unit: .sentence,
            scheme: .tokenType,
            options: [.omitWhitespace]
        ) { _, sentenceRange, stop in
            let upper = sentenceRange.location + sentenceRange.length
            if (probe >= sentenceRange.location && probe < upper) || probe == upper {
                foundRange = sentenceRange
                stop.pointee = true
            }
        }

        return foundRange ?? text.paragraphRange(for: NSRange(location: probe, length: 0))
    }

    private static func clamp(range: NSRange, upperBound: Int) -> NSRange {
        guard upperBound >= 0 else {
            return NSRange(location: 0, length: 0)
        }

        let location = max(0, min(range.location, upperBound))
        let unclampedUpperBound = range.location + max(0, range.length)
        let upperRangeBound = max(location, min(unclampedUpperBound, upperBound))
        return NSRange(location: location, length: max(0, upperRangeBound - location))
    }

    private static func editorFont(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: clampedFontSize(size), weight: .regular)
    }

    private static func clampedFontSize(_ value: CGFloat) -> CGFloat {
        min(max(value, 12), 30)
    }

    private static func baseAttributes(
        foreground: NSColor,
        fontSize: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: editorFont(size: fontSize),
            .paragraphStyle: baseParagraphStyle,
            .foregroundColor: foreground
        ]
    }

    private func applyMarkdownEmphasis(marker: String) {
        guard isEditable else { return }

        let nsText = string as NSString
        let totalLength = nsText.length
        let selection = Self.clamp(range: selectedRange(), upperBound: totalLength)
        let markerLength = (marker as NSString).length

        let replacement: String
        if selection.length > 0 {
            let selectedText = nsText.substring(with: selection)
            replacement = "\(marker)\(selectedText)\(marker)"
        } else {
            replacement = "\(marker)\(marker)"
        }

        guard shouldChangeText(in: selection, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: selection, with: replacement)
        didChangeText()

        setSelectedRange(
            NSRange(
                location: selection.location + markerLength,
                length: selection.length
            )
        )
        scheduleStyling(reason: .textChanged)
    }

    @objc private func summarizeSelectionUsingAIFromMenu(_ sender: Any?) {
        summarizeSelectedTextUsingAI()
    }

    private func summarizeSelectedTextUsingAI() {
        let currentText = string as NSString
        let initialRange = Self.clamp(range: selectedRange(), upperBound: currentText.length)
        guard initialRange.length > 0 else { return }
        let initialSelectedText = currentText.substring(with: initialRange)

        runAITask(
            work: { try await AIAssistant.shared.summarizeSelection(initialSelectedText) },
            onSuccess: { [weak self] summary in
                guard let self else { return }
                let nsCurrent = self.string as NSString
                var replacementRange = initialRange
                if NSMaxRange(replacementRange) <= nsCurrent.length {
                    let slice = nsCurrent.substring(with: replacementRange)
                    if slice != initialSelectedText {
                        replacementRange = Self.clamp(range: self.selectedRange(), upperBound: nsCurrent.length)
                    }
                } else {
                    replacementRange = Self.clamp(range: self.selectedRange(), upperBound: nsCurrent.length)
                }
                self.applyAIGeneratedReplacement(in: replacementRange, with: summary)
            }
        )
    }

    private func summarizeCurrentDocumentUsingAI() {
        let source = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            onAIError?(AIAssistantError.emptyInput.localizedDescription)
            return
        }

        runAITask(
            work: { try await AIAssistant.shared.summarizeDocument(source) },
            onSuccess: { [weak self] summary in
                self?.appendAIDocumentSummary(summary)
            }
        )
    }

    private func appendAIDocumentSummary(_ summary: String) {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else { return }

        let nsText = string as NSString
        let insertionRange = NSRange(location: nsText.length, length: 0)

        let separator: String
        if nsText.length == 0 {
            separator = ""
        } else if string.hasSuffix("\n\n") {
            separator = ""
        } else if string.hasSuffix("\n") {
            separator = "\n"
        } else {
            separator = "\n\n"
        }

        let block = "\(separator)#ai summary\n\(trimmedSummary)\n"
        applyAIGeneratedReplacement(in: insertionRange, with: block)
        scrollRangeToVisible(NSRange(location: insertionRange.location, length: (block as NSString).length))
    }

    private func runAITask(
        work: @escaping () async throws -> String,
        onSuccess: @escaping (String) -> Void
    ) {
        guard !isRunningAITask else { return }
        isRunningAITask = true

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await work()
                await MainActor.run {
                    self.isRunningAITask = false
                    onSuccess(result)
                }
            } catch {
                await MainActor.run {
                    self.isRunningAITask = false
                    if let localized = error as? LocalizedError, let description = localized.errorDescription {
                        self.onAIError?(description)
                    } else {
                        self.onAIError?(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func applyAIGeneratedReplacement(in range: NSRange, with replacement: String) {
        let safeRange = Self.clamp(range: range, upperBound: (string as NSString).length)
        guard shouldChangeText(in: safeRange, replacementString: replacement) else { return }

        textStorage?.replaceCharacters(in: safeRange, with: replacement)
        didChangeText()

        let insertedLength = (replacement as NSString).length
        if insertedLength > 0 {
            registerAIGeneratedRange(NSRange(location: safeRange.location, length: insertedLength))
        }

        let newCursorLocation = safeRange.location + insertedLength
        setSelectedRange(NSRange(location: newCursorLocation, length: 0))
        scheduleStyling(reason: .textChanged)
    }

    private func registerAIGeneratedRange(_ newRange: NSRange) {
        guard newRange.length > 0 else { return }
        aiGeneratedRanges.append(newRange)
        aiGeneratedRanges = Self.normalizedRanges(aiGeneratedRanges, upperBound: (string as NSString).length)
        ensureAIGradientTimer()
    }

    private func ensureAIGradientTimer() {
        guard aiGradientTimer == nil else { return }
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.tickAIGradient()
        }
        RunLoop.main.add(timer, forMode: .common)
        aiGradientTimer = timer
    }

    private func tickAIGradient() {
        guard !aiGeneratedRanges.isEmpty else {
            aiGradientTimer?.invalidate()
            aiGradientTimer = nil
            return
        }
        aiGradientPhase += 0.33
        scheduleStyling(reason: .aiAnimationTick)
    }

    private func applyAIGradientIfNeeded(to textStorage: NSTextStorage, darkMode: Bool) {
        aiGeneratedRanges = Self.normalizedRanges(aiGeneratedRanges, upperBound: textStorage.length)
        guard !aiGeneratedRanges.isEmpty else { return }

        var paintedCharacterCount = 0
        let maxAnimatedCharacters = 2800
        for range in aiGeneratedRanges {
            guard range.length > 0 else { continue }
            for offset in 0..<range.length {
                if paintedCharacterCount >= maxAnimatedCharacters { return }
                let location = range.location + offset
                guard location < textStorage.length else { continue }
                let characterRange = NSRange(location: location, length: 1)
                let color = aiGradientColor(characterIndex: location, darkMode: darkMode)
                textStorage.addAttribute(.foregroundColor, value: color, range: characterRange)
                paintedCharacterCount += 1
            }
        }
    }

    private func aiGradientColor(characterIndex: Int, darkMode: Bool) -> NSColor {
        let wave = (sin((CGFloat(characterIndex) * 0.18) + aiGradientPhase) + 1) * 0.5
        let start = darkMode
            ? NSColor(calibratedRed: 0.54, green: 0.79, blue: 1.00, alpha: 0.98)
            : NSColor(calibratedRed: 0.18, green: 0.50, blue: 0.94, alpha: 0.98)
        let end = darkMode
            ? NSColor(calibratedRed: 0.90, green: 0.62, blue: 1.00, alpha: 0.98)
            : NSColor(calibratedRed: 0.66, green: 0.31, blue: 0.92, alpha: 0.98)
        return Self.blendColor(start, end, factor: wave)
    }

    private static func blendColor(_ first: NSColor, _ second: NSColor, factor: CGFloat) -> NSColor {
        let f = min(max(factor, 0), 1)
        let c1 = first.usingColorSpace(.deviceRGB) ?? first
        let c2 = second.usingColorSpace(.deviceRGB) ?? second
        return NSColor(
            calibratedRed: c1.redComponent + (c2.redComponent - c1.redComponent) * f,
            green: c1.greenComponent + (c2.greenComponent - c1.greenComponent) * f,
            blue: c1.blueComponent + (c2.blueComponent - c1.blueComponent) * f,
            alpha: c1.alphaComponent + (c2.alphaComponent - c1.alphaComponent) * f
        )
    }

    private static func normalizedRanges(_ ranges: [NSRange], upperBound: Int) -> [NSRange] {
        let clamped = ranges
            .map { clamp(range: $0, upperBound: upperBound) }
            .filter { $0.length > 0 }
            .sorted { lhs, rhs in lhs.location < rhs.location }

        guard !clamped.isEmpty else { return [] }

        var merged: [NSRange] = [clamped[0]]
        for candidate in clamped.dropFirst() {
            var tail = merged.removeLast()
            let tailEnd = NSMaxRange(tail)
            if candidate.location <= tailEnd {
                let mergedEnd = max(tailEnd, NSMaxRange(candidate))
                tail.length = mergedEnd - tail.location
                merged.append(tail)
            } else {
                merged.append(tail)
                merged.append(candidate)
            }
        }
        return merged
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

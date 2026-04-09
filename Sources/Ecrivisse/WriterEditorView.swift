import SwiftUI
import AppKit

struct WriterEditorView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var focusMode: FocusMode
    var cursorColor: NSColor
    var summarizeDocumentRequestID: Int
    var onHorizontalSwipe: (CGFloat) -> Void
    var onAIError: (String) -> Void
    var onUserEdit: (String) -> Void
    var onEditingLocationChange: (_ caretLocation: Int, _ textLength: Int) -> Void

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
        textView.customCursorColor = cursorColor
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
        textView.customCursorColor = cursorColor
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
            context.coordinator.emitEditingLocation()
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
            ) { [weak self, weak textView] _ in
                textView?.scheduleStyling(reason: .visibleRangeChanged)
                self?.emitEditingLocation()
            }
            DispatchQueue.main.async { [weak self] in
                self?.emitEditingLocation()
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
            if textView.window?.firstResponder === textView {
                emitEditingLocation()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if textView?.hasMarkedText() == true {
                return
            }
            emitEditingLocation()
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
            if textView.window?.firstResponder === textView {
                emitEditingLocation()
            }
        }

        func emitEditingLocation() {
            guard let textView else { return }
            let snapshot = textView.editingLocationSnapshot()
            parent.onEditingLocationChange(snapshot.location, snapshot.textLength)
        }
    }
}

final class WriterTextView: NSTextView {
    private struct ListContinuation {
        let insertionPrefix: String
        let markerLength: Int
        let isContentEmpty: Bool
    }

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
            applyFontSizeChangeImmediately()
        }
    }

    var onCompositionCommit: (() -> Void)?
    var onHorizontalSwipe: ((CGFloat) -> Void)?
    var onAIError: ((String) -> Void)?
    var customCursorColor: NSColor = WriterTextView.defaultCursorColor {
        didSet {
            guard !oldValue.isEqual(customCursorColor) else { return }
            updateCursorColor()
            scheduleStyling(reason: .fullRefresh)
        }
    }

    private static let defaultCursorColor = NSColor(calibratedRed: 1.0, green: 0.302, blue: 0.251, alpha: 0.98) // #ff4d40
    private static let baseParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 8
        style.paragraphSpacing = 12
        style.lineBreakMode = .byWordWrapping
        return style
    }()
    private static let taskListRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-+*])\s+\[(?: |x|X)\]\s*(.*)$"#,
        options: []
    )
    private static let unorderedListRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-+*])\s+(.*)$"#,
        options: []
    )
    private static let orderedListRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)(\d+)\.\s+(.*)$"#,
        options: []
    )
    private static let taskListMarkerStateRegex = try! NSRegularExpression(
        pattern: #"(?m)^([ \t]*[-+*][ \t]+\[)([ xX])(\][ \t]*)"#,
        options: []
    )
    private static let easterEggTermsRegex: NSRegularExpression = {
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
            "հարկ",
            "crawfish", "crawfishes",
            "crayfish", "crayfishes",
            "crawdad", "crawdads",
            "crawdaddy", "crawdaddies",
            "mudbug", "mudbugs",
            "yabby", "yabbies",
            "écrevisse", "écrevisses", "ecrevisse", "ecrevisses",
            "cangrejo de río", "cangrejos de río",
            "langostino de río", "langostinos de río",
            "gambero di fiume", "gamberi di fiume",
            "flusskrebs", "flusskrebse",
            "kerevit", "kerevitler",
            "karavida", "καραβίδα", "καραβίδες",
            "tôm hùm đất",
            "udang karang air tawar",
            "กุ้งเครย์ฟิช", "เครย์ฟิช",
            "ザリガニ", "アメリカザリガニ",
            "가재",
            "小龙虾", "小龍蝦", "螯虾", "螯蝦", "淡水龙虾", "淡水龍蝦",
            "речной рак", "речные раки",
            "rak rzeczny", "raki rzeczne",
            "річковий рак"
        ]
        let escaped = terms.map { NSRegularExpression.escapedPattern(for: $0) }
        let pattern = "(?<![\\p{L}\\p{N}_])(?:" + escaped.joined(separator: "|") + ")(?![\\p{L}\\p{N}_])"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
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
    private let easterEggHighlightFadeDuration: TimeInterval = 1.5
    private var easterEggHighlightFadeStart: Date?
    private var easterEggActiveMatchRange: NSRange?
    private var easterEggHighlightTimer: Timer?

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
        easterEggHighlightTimer?.invalidate()
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
        if modifiers.isEmpty, isReturnKeyEvent(event), handleListContinuationOnReturnKey() {
            return
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
        if reason == .textChanged {
            noteEasterEggHighlightPulse()
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

    private func applyFontSizeChangeImmediately() {
        font = Self.editorFont(size: editorFontSize)

        if let textStorage {
            let fullRange = NSRange(location: 0, length: textStorage.length)
            if fullRange.length > 0 {
                textStorage.beginEditing()
                textStorage.addAttribute(.font, value: Self.editorFont(size: editorFontSize), range: fullRange)
                textStorage.addAttribute(.paragraphStyle, value: Self.baseParagraphStyle, range: fullRange)
                textStorage.endEditing()
            }
        }

        refreshTypingAttributes()
        needsDisplay = true

        if focusMode != .off || !aiGeneratedRanges.isEmpty {
            scheduleStyling(reason: .selectionChanged)
        }
    }

    private func refreshTypingAttributes() {
        typingAttributes = Self.baseAttributes(foreground: .labelColor, fontSize: editorFontSize)
    }

    private func updateCursorColor() {
        insertionPointColor = customCursorColor
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

        let easterEggFadeTargetColor: NSColor = plan.isDarkMode ? .white : baseColor
        applyAIGradientIfNeeded(to: textStorage, darkMode: plan.isDarkMode)
        applyEasterEggTermHighlightsIfNeeded(to: textStorage, fadeTargetColor: easterEggFadeTargetColor)
        textStorage.endEditing()

        refreshTypingAttributes()
        applyingStyle = false
    }

    private func applyEasterEggTermHighlightsIfNeeded(to textStorage: NSTextStorage, fadeTargetColor: NSColor) {
        guard let fadeStart = easterEggHighlightFadeStart else { return }
        guard let activeRange = easterEggActiveMatchRange else { return }

        let text = textStorage.string
        guard !text.isEmpty else { return }

        let elapsed = Date().timeIntervalSince(fadeStart)
        let clampedProgress = min(max(elapsed / easterEggHighlightFadeDuration, 0), 1)
        guard clampedProgress < 1 else {
            easterEggHighlightFadeStart = nil
            easterEggActiveMatchRange = nil
            stopEasterEggHighlightTimerIfNeeded()
            return
        }

        let nsText = text as NSString
        let safeRange = Self.clamp(range: activeRange, upperBound: nsText.length)
        guard safeRange.length > 0 else {
            easterEggHighlightFadeStart = nil
            easterEggActiveMatchRange = nil
            stopEasterEggHighlightTimerIfNeeded()
            return
        }

        let candidate = nsText.substring(with: safeRange)
        let candidateRange = NSRange(location: 0, length: (candidate as NSString).length)
        guard let anchored = Self.easterEggTermsRegex.firstMatch(
            in: candidate,
            options: [.anchored],
            range: candidateRange
        ) else {
            easterEggHighlightFadeStart = nil
            easterEggActiveMatchRange = nil
            stopEasterEggHighlightTimerIfNeeded()
            return
        }
        guard anchored.range(at: 0).location == 0, anchored.range(at: 0).length == candidateRange.length else {
            easterEggHighlightFadeStart = nil
            easterEggActiveMatchRange = nil
            stopEasterEggHighlightTimerIfNeeded()
            return
        }

        let fadedColor = Self.blendColor(customCursorColor, fadeTargetColor, factor: CGFloat(clampedProgress))
        textStorage.addAttribute(.foregroundColor, value: fadedColor, range: safeRange)
    }

    private func noteEasterEggHighlightPulse() {
        let text = string
        let textLength = (text as NSString).length
        let caret = Self.clamp(range: selectedRange(), upperBound: textLength).location
        guard let activeMatch = Self.easterEggMatchRange(in: text, caretLocation: caret) else {
            if easterEggHighlightFadeStart != nil, easterEggActiveMatchRange != nil {
                ensureEasterEggHighlightTimer()
            }
            return
        }

        easterEggActiveMatchRange = activeMatch
        easterEggHighlightFadeStart = Date()
        ensureEasterEggHighlightTimer()
    }

    private static func easterEggMatchRange(in text: String, caretLocation: Int) -> NSRange? {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let safeCaret = max(0, min(caretLocation, nsText.length))
        let matches = easterEggTermsRegex.matches(in: text, options: [], range: fullRange)

        for match in matches {
            let range = match.range(at: 0)
            guard range.location != NSNotFound, range.length > 0 else { continue }
            if safeCaret >= range.location && safeCaret <= NSMaxRange(range) {
                return range
            }
        }
        return nil
    }

    private func ensureEasterEggHighlightTimer() {
        guard easterEggHighlightTimer == nil else { return }
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            self?.tickEasterEggHighlightFade()
        }
        RunLoop.main.add(timer, forMode: .common)
        easterEggHighlightTimer = timer
    }

    private func stopEasterEggHighlightTimerIfNeeded() {
        easterEggHighlightTimer?.invalidate()
        easterEggHighlightTimer = nil
    }

    private func tickEasterEggHighlightFade() {
        guard let fadeStart = easterEggHighlightFadeStart else {
            stopEasterEggHighlightTimerIfNeeded()
            return
        }

        if Date().timeIntervalSince(fadeStart) >= easterEggHighlightFadeDuration {
            easterEggHighlightFadeStart = nil
            easterEggActiveMatchRange = nil
            stopEasterEggHighlightTimerIfNeeded()
            scheduleStyling(reason: .fullRefresh)
            return
        }

        scheduleStyling(reason: .aiAnimationTick)
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

    func editingLocationSnapshot() -> (location: Int, textLength: Int) {
        let totalLength = (string as NSString).length
        let selection = Self.clamp(range: selectedRange(), upperBound: totalLength)
        return (selection.location, totalLength)
    }

    func scrollToSourceLine(_ line: Int) {
        let nsText = string as NSString
        let targetLine = max(0, line)
        let location = Self.locationForLine(targetLine, in: nsText)
        let targetRange = NSRange(location: location, length: 0)

        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        setSelectedRange(targetRange)
        scrollRangeToVisible(targetRange)
        scheduleStyling(reason: .selectionChanged)
    }

    private static func locationForLine(_ line: Int, in text: NSString) -> Int {
        if line <= 0 || text.length == 0 {
            return 0
        }

        var currentLine = 0
        var location = 0
        while currentLine < line && location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let nextLocation = NSMaxRange(lineRange)
            if nextLocation <= location {
                break
            }
            location = nextLocation
            currentLine += 1
        }
        return min(location, text.length)
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

    private func isReturnKeyEvent(_ event: NSEvent) -> Bool {
        if event.keyCode == 36 || event.keyCode == 76 {
            return true
        }
        guard let characters = event.charactersIgnoringModifiers else {
            return false
        }
        return characters == "\r" || characters == "\n"
    }

    private func handleListContinuationOnReturnKey() -> Bool {
        guard isEditable else { return false }
        guard !hasMarkedText() else { return false }

        let nsText = string as NSString
        let totalLength = nsText.length
        let selection = Self.clamp(range: selectedRange(), upperBound: totalLength)
        guard selection.length == 0 else { return false }

        if totalLength == 0 {
            return false
        }

        let probeLocation: Int
        if selection.location >= totalLength {
            probeLocation = max(totalLength - 1, 0)
        } else {
            probeLocation = selection.location
        }

        let lineRange = nsText.lineRange(for: NSRange(location: probeLocation, length: 0))
        let rawLine = nsText.substring(with: lineRange)
        let line = rawLine.replacingOccurrences(of: #"\r?\n$"#, with: "", options: .regularExpression)
        guard let continuation = Self.listContinuation(for: line) else {
            return false
        }

        let lineLength = (line as NSString).length
        let caretInLine = min(max(selection.location - lineRange.location, 0), lineLength)

        if continuation.isContentEmpty,
           caretInLine >= continuation.markerLength {
            let markerRange = NSRange(location: lineRange.location, length: continuation.markerLength)
            guard shouldChangeText(in: markerRange, replacementString: "") else { return true }
            textStorage?.replaceCharacters(in: markerRange, with: "")
            didChangeText()
            let newLocation = max(lineRange.location, selection.location - continuation.markerLength)
            setSelectedRange(NSRange(location: newLocation, length: 0))
            scheduleStyling(reason: .textChanged)
            return true
        }

        let insertion = "\n" + continuation.insertionPrefix
        guard shouldChangeText(in: selection, replacementString: insertion) else { return true }
        textStorage?.replaceCharacters(in: selection, with: insertion)
        didChangeText()
        let newLocation = selection.location + (insertion as NSString).length
        setSelectedRange(NSRange(location: newLocation, length: 0))
        scheduleStyling(reason: .textChanged)
        return true
    }

    private static func listContinuation(for line: String) -> ListContinuation? {
        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)

        if let match = taskListRegex.firstMatch(in: line, options: [], range: fullRange),
           match.numberOfRanges >= 4,
           match.range(at: 1).location != NSNotFound,
           match.range(at: 2).location != NSNotFound,
           match.range(at: 3).location != NSNotFound {
            let indent = nsLine.substring(with: match.range(at: 1))
            let bullet = nsLine.substring(with: match.range(at: 2))
            let content = nsLine.substring(with: match.range(at: 3))
            return ListContinuation(
                insertionPrefix: "\(indent)\(bullet) [ ] ",
                markerLength: match.range(at: 3).location,
                isContentEmpty: content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }

        if let match = orderedListRegex.firstMatch(in: line, options: [], range: fullRange),
           match.numberOfRanges >= 4,
           match.range(at: 1).location != NSNotFound,
           match.range(at: 2).location != NSNotFound,
           match.range(at: 3).location != NSNotFound {
            let indent = nsLine.substring(with: match.range(at: 1))
            let numberString = nsLine.substring(with: match.range(at: 2))
            let content = nsLine.substring(with: match.range(at: 3))
            let currentNumber = Int(numberString) ?? 1
            return ListContinuation(
                insertionPrefix: "\(indent)\(currentNumber + 1). ",
                markerLength: match.range(at: 3).location,
                isContentEmpty: content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }

        if let match = unorderedListRegex.firstMatch(in: line, options: [], range: fullRange),
           match.numberOfRanges >= 4,
           match.range(at: 1).location != NSNotFound,
           match.range(at: 2).location != NSNotFound,
           match.range(at: 3).location != NSNotFound {
            let indent = nsLine.substring(with: match.range(at: 1))
            let bullet = nsLine.substring(with: match.range(at: 2))
            let content = nsLine.substring(with: match.range(at: 3))
            return ListContinuation(
                insertionPrefix: "\(indent)\(bullet) ",
                markerLength: match.range(at: 3).location,
                isContentEmpty: content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }

        return nil
    }

    func applyMarkdownAction(_ action: MarkdownEditorAction) {
        guard isEditable else { return }
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        if hasMarkedText() {
            unmarkText()
        }

        switch action {
        case let .heading(level):
            applyHeading(level: level)
        case .bold:
            applyMarkdownEmphasis(marker: "**")
        case .italic:
            applyMarkdownEmphasis(marker: "*")
        case .boldItalic:
            applyMarkdownEmphasis(marker: "***")
        case .strikethrough:
            applyMarkdownEmphasis(marker: "~~")
        case .inlineCode:
            wrapSelection(prefix: "`", suffix: "`", placeholder: "code")
        case .escapeCharacters:
            applyEscapedCharacters()
        case .unorderedList:
            applyUnorderedList()
        case .orderedList:
            applyOrderedList()
        case .checklist:
            applyChecklist()
        case .link:
            insertMarkdownLink()
        case .codeBlock:
            insertCodeBlock()
        case .blockquote:
            applyBlockquote()
        case .footnote:
            insertFootnote()
        case .toc:
            insertTableOfContentsMarker()
        case let .table(rows, columns):
            insertTable(rows: rows, columns: columns)
        }
    }

    @discardableResult
    func setTaskListItemChecked(at index: Int, checked: Bool) -> Bool {
        guard index >= 0 else { return false }
        guard !hasMarkedText() else { return false }

        let source = string
        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)
        let matches = Self.taskListMarkerStateRegex.matches(in: source, options: [], range: fullRange)
        guard index < matches.count else { return false }

        let target = matches[index]
        guard target.numberOfRanges > 2 else { return false }
        let stateRange = target.range(at: 2)
        guard stateRange.location != NSNotFound, stateRange.length > 0 else { return false }

        let replacement = checked ? "x" : " "
        if nsSource.substring(with: stateRange) == replacement {
            return false
        }

        guard shouldChangeText(in: stateRange, replacementString: replacement) else {
            return false
        }
        textStorage?.replaceCharacters(in: stateRange, with: replacement)
        didChangeText()
        scheduleStyling(reason: .textChanged)
        return true
    }

    private func wrapSelection(prefix: String, suffix: String, placeholder: String = "") {
        let nsText = string as NSString
        let totalLength = nsText.length
        let selection = Self.clamp(range: selectedRange(), upperBound: totalLength)
        let prefixLength = (prefix as NSString).length

        let replacement: String
        let newSelection: NSRange
        if selection.length > 0 {
            let selectedText = nsText.substring(with: selection)
            replacement = "\(prefix)\(selectedText)\(suffix)"
            newSelection = NSRange(location: selection.location + prefixLength, length: selection.length)
        } else {
            replacement = "\(prefix)\(placeholder)\(suffix)"
            newSelection = NSRange(location: selection.location + prefixLength, length: (placeholder as NSString).length)
        }

        guard shouldChangeText(in: selection, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: selection, with: replacement)
        didChangeText()
        setSelectedRange(newSelection)
        scheduleStyling(reason: .textChanged)
    }

    private func applyHeading(level: Int) {
        let clampedLevel = min(max(level, 1), 6)
        let prefix = String(repeating: "#", count: clampedLevel) + " "
        transformSelectedLines { line, _ in
            let stripped = line.replacingOccurrences(
                of: #"^\s{0,3}#{1,6}\s*"#,
                with: "",
                options: .regularExpression
            )
            return prefix + stripped.trimmingCharacters(in: .whitespaces)
        }
    }

    private func applyUnorderedList() {
        transformSelectedLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            let stripped = line.replacingOccurrences(
                of: #"^\s*(?:[-*+]\s+|\d+\.\s+)"#,
                with: "",
                options: .regularExpression
            )
            return "- " + stripped.trimmingCharacters(in: .whitespaces)
        }
    }

    private func applyOrderedList() {
        var itemIndex = 1
        transformSelectedLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            let stripped = line.replacingOccurrences(
                of: #"^\s*(?:[-*+]\s+|\d+\.\s+)"#,
                with: "",
                options: .regularExpression
            )
            defer { itemIndex += 1 }
            return "\(itemIndex). " + stripped.trimmingCharacters(in: .whitespaces)
        }
    }

    private func applyChecklist() {
        transformSelectedLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }

            let indentationMatch = line.range(of: #"^[ \t]*"#, options: .regularExpression)
            let indentation = indentationMatch.map { String(line[$0]) } ?? ""
            let stripped = line.replacingOccurrences(
                of: #"^\s*(?:[-+*]\s+\[(?: |x|X)\]\s+|[-+*]\s+|\d+\.\s+)"#,
                with: "",
                options: .regularExpression
            )
            return "\(indentation)- [ ] " + stripped.trimmingCharacters(in: .whitespaces)
        }
    }

    private func applyBlockquote() {
        transformSelectedLines { line, _ in
            let stripped = line.replacingOccurrences(
                of: #"^\s*>\s?"#,
                with: "",
                options: .regularExpression
            )
            if stripped.trimmingCharacters(in: .whitespaces).isEmpty {
                return line
            }
            return "> " + stripped
        }
    }

    private func applyEscapedCharacters() {
        let nsText = string as NSString
        let totalLength = nsText.length
        let selection = Self.clamp(range: selectedRange(), upperBound: totalLength)
        let escapeSet: Set<Character> = Set("\\`*_{}[]()#+-.!~>|")

        guard selection.length > 0 else {
            let replacement = "\\"
            guard shouldChangeText(in: selection, replacementString: replacement) else { return }
            textStorage?.replaceCharacters(in: selection, with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            scheduleStyling(reason: .textChanged)
            return
        }

        let selectedText = nsText.substring(with: selection)
        var escaped = ""
        escaped.reserveCapacity(selectedText.count * 2)
        for character in selectedText {
            if escapeSet.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }

        guard shouldChangeText(in: selection, replacementString: escaped) else { return }
        textStorage?.replaceCharacters(in: selection, with: escaped)
        didChangeText()
        setSelectedRange(NSRange(location: selection.location, length: (escaped as NSString).length))
        scheduleStyling(reason: .textChanged)
    }

    private func insertMarkdownLink() {
        let nsText = string as NSString
        let totalLength = nsText.length
        let selection = Self.clamp(range: selectedRange(), upperBound: totalLength)

        let defaultURL = "https://example.com"
        if selection.length > 0 {
            let selectedText = nsText.substring(with: selection)
            let replacement = "[\(selectedText)](\(defaultURL))"
            guard shouldChangeText(in: selection, replacementString: replacement) else { return }
            textStorage?.replaceCharacters(in: selection, with: replacement)
            didChangeText()
            let urlLocation = selection.location + (selectedText as NSString).length + 3
            setSelectedRange(NSRange(location: urlLocation, length: (defaultURL as NSString).length))
            scheduleStyling(reason: .textChanged)
            return
        }

        let replacement = "[link text](\(defaultURL))"
        guard shouldChangeText(in: selection, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: selection, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: selection.location + 1, length: ("link text" as NSString).length))
        scheduleStyling(reason: .textChanged)
    }

    private func insertCodeBlock() {
        let nsText = string as NSString
        let totalLength = nsText.length
        let selection = Self.clamp(range: selectedRange(), upperBound: totalLength)
        let selectedText = selection.length > 0 ? nsText.substring(with: selection) : ""

        let replacement: String
        let cursorRange: NSRange
        if selection.length > 0 {
            replacement = "```\n\(selectedText)\n```"
            cursorRange = NSRange(location: selection.location + 4, length: (selectedText as NSString).length)
        } else {
            replacement = "```\n\n```"
            cursorRange = NSRange(location: selection.location + 4, length: 0)
        }

        guard shouldChangeText(in: selection, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: selection, with: replacement)
        didChangeText()
        setSelectedRange(cursorRange)
        scheduleStyling(reason: .textChanged)
    }

    private func insertFootnote() {
        let nsText = string as NSString
        let totalLength = nsText.length
        let selection = Self.clamp(range: selectedRange(), upperBound: totalLength)
        let footnoteID = nextFootnoteID()
        let marker = "[^\(footnoteID)]"

        if selection.length > 0 {
            let selected = nsText.substring(with: selection)
            let replacement = selected + marker
            guard shouldChangeText(in: selection, replacementString: replacement) else { return }
            textStorage?.replaceCharacters(in: selection, with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: selection.location + (replacement as NSString).length, length: 0))
        } else {
            guard shouldChangeText(in: selection, replacementString: marker) else { return }
            textStorage?.replaceCharacters(in: selection, with: marker)
            didChangeText()
            setSelectedRange(NSRange(location: selection.location + (marker as NSString).length, length: 0))
        }

        let definitionPrefix = "[^\(footnoteID)]: "
        let current = string
        if !current.contains(definitionPrefix) {
            let appendNeedsNewline = !current.hasSuffix("\n")
            let definitionBlock = appendNeedsNewline ? "\n\n\(definitionPrefix)" : "\n\(definitionPrefix)"
            let insertLocation = (string as NSString).length
            let appendRange = NSRange(location: insertLocation, length: 0)
            guard shouldChangeText(in: appendRange, replacementString: definitionBlock) else {
                scheduleStyling(reason: .textChanged)
                return
            }
            textStorage?.replaceCharacters(in: appendRange, with: definitionBlock)
            didChangeText()
            setSelectedRange(
                NSRange(
                    location: insertLocation + (definitionBlock as NSString).length,
                    length: 0
                )
            )
        }

        scheduleStyling(reason: .textChanged)
    }

    private func insertTableOfContentsMarker() {
        let marker = "{{TOC}}"
        let nsText = string as NSString
        let selection = Self.clamp(range: selectedRange(), upperBound: nsText.length)

        let beforeIsLineBreak: Bool
        if selection.location == 0 {
            beforeIsLineBreak = true
        } else {
            beforeIsLineBreak = nsText.substring(with: NSRange(location: selection.location - 1, length: 1)) == "\n"
        }

        let afterLocation = selection.location + selection.length
        let afterIsLineBreak: Bool
        if afterLocation >= nsText.length {
            afterIsLineBreak = true
        } else {
            afterIsLineBreak = nsText.substring(with: NSRange(location: afterLocation, length: 1)) == "\n"
        }

        let prefix = beforeIsLineBreak ? "" : "\n"
        let suffix = afterIsLineBreak ? "" : "\n"
        let replacement = prefix + marker + suffix

        guard shouldChangeText(in: selection, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: selection, with: replacement)
        didChangeText()

        let cursorLocation = selection.location + (prefix as NSString).length + (marker as NSString).length
        setSelectedRange(NSRange(location: cursorLocation, length: 0))
        scheduleStyling(reason: .textChanged)
    }

    private func insertTable(rows: Int, columns: Int) {
        let safeRows = min(max(rows, 1), 20)
        let safeColumns = min(max(columns, 1), 20)

        let headerCells = (1...safeColumns).map { "Column \($0)" }
        let dividerCells = Array(repeating: "---", count: safeColumns)
        let bodyCells = Array(repeating: " ", count: safeColumns)

        var lines: [String] = []
        lines.append("| " + headerCells.joined(separator: " | ") + " |")
        lines.append("| " + dividerCells.joined(separator: " | ") + " |")
        for _ in 0..<safeRows {
            lines.append("| " + bodyCells.joined(separator: " | ") + " |")
        }

        let block = lines.joined(separator: "\n")
        let nsText = string as NSString
        let selection = Self.clamp(range: selectedRange(), upperBound: nsText.length)

        let needsLeadingSpacing: Bool
        if selection.location == 0 {
            needsLeadingSpacing = false
        } else {
            let previousChar = nsText.substring(with: NSRange(location: selection.location - 1, length: 1))
            needsLeadingSpacing = previousChar != "\n"
        }

        let prefix = needsLeadingSpacing ? "\n\n" : ""
        let suffix = "\n"
        let replacement = prefix + block + suffix
        guard shouldChangeText(in: selection, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: selection, with: replacement)
        didChangeText()

        let headerLength = (lines[0] as NSString).length
        let dividerLength = (lines[1] as NSString).length
        let cursorLocation = selection.location + (prefix as NSString).length + headerLength + 1 + dividerLength + 1 + 2
        setSelectedRange(NSRange(location: cursorLocation, length: 0))
        scheduleStyling(reason: .textChanged)
    }

    private func nextFootnoteID() -> Int {
        let pattern = #"\[\^(\d+)\]"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        let matches = regex?.matches(in: string, options: [], range: fullRange) ?? []

        var maxID = 0
        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let numberRange = match.range(at: 1)
            guard numberRange.location != NSNotFound else { continue }
            let token = (string as NSString).substring(with: numberRange)
            if let value = Int(token) {
                maxID = max(maxID, value)
            }
        }
        return maxID + 1
    }

    private func transformSelectedLines(_ transform: (String, Int) -> String) {
        let nsText = string as NSString
        let totalLength = nsText.length

        let sourceSelection = Self.clamp(range: selectedRange(), upperBound: totalLength)
        let lineQueryRange: NSRange
        if totalLength == 0 {
            lineQueryRange = NSRange(location: 0, length: 0)
        } else {
            let safeLocation = min(sourceSelection.location, max(totalLength - 1, 0))
            lineQueryRange = NSRange(location: safeLocation, length: sourceSelection.length)
        }
        let lineRange = totalLength == 0 ? NSRange(location: 0, length: 0) : nsText.lineRange(for: lineQueryRange)

        let block = lineRange.length > 0 ? nsText.substring(with: lineRange) : ""
        let lines = (lineRange.length > 0 ? block : "").components(separatedBy: "\n")
        let hasTrailingNewline = block.hasSuffix("\n")

        let transformed = lines.enumerated().map { index, line -> String in
            let isTrailingSentinel = hasTrailingNewline && index == lines.count - 1 && line.isEmpty
            if isTrailingSentinel {
                return line
            }
            return transform(line, index)
        }
        let replacement = transformed.joined(separator: "\n")

        guard shouldChangeText(in: lineRange, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: lineRange, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
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

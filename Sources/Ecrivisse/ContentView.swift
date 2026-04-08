import SwiftUI
import AppKit

struct ContentView: View {
    let initialExternalFilePath: String?

    @StateObject private var appState = AppState()
    @ObservedObject private var externalFileOpenRouter = ExternalFileOpenRouter.shared
    @State private var isPreviewButtonHovered = false
    @State private var isTablePickerPresented = false
    @State private var tablePickerColumns = 3
    @State private var tablePickerRows = 3
    @State private var hasHandledInitialExternalFilePath = false
    @State private var previewFollowRatio: Double = 0
    @State private var previewFollowEventID: Int = 0
    @State private var lastCommittedPreviewFollowRatio: Double = -1
    @State private var isFontControlHovered = false
    @State private var isPreviewFontControlHovered = false
    @State private var isThemeControlHovered = false
    @State private var isFloatingToolbarHovered = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    private let tablePickerMaxColumns = 10
    private let tablePickerMaxRows = 8

    private var previewButtonTrailingPadding: CGFloat {
        appState.isPreviewPanelVisible ? 42 : 26
    }

    private var editorBackgroundColor: Color {
        if colorScheme == .dark {
            return Color(nsColor: .textBackgroundColor)
        }
        return Color(nsColor: NSColor(calibratedWhite: 0.95, alpha: 1.0))
    }

    private var bottomCapsuleFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04)
    }

    private func bottomCapsuleFill(hovered: Bool) -> Color {
        if hovered {
            return colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.075)
        }
        return bottomCapsuleFill
    }

    private func bottomCapsuleBorder(hovered: Bool) -> Color {
        if hovered {
            return colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.16)
        }
        return colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }

    private var floatingToolbarFill: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private var floatingToolbarBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10)
    }

    private var floatingToolbarFillInteractive: Color {
        // Keep the toolbar panel fully opaque even during hover.
        return floatingToolbarFill
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ZStack {
                        editorBackgroundColor
                            .ignoresSafeArea()

                        WriterEditorView(
                            text: $appState.text,
                            fontSize: appState.editorFontSize,
                            focusMode: appState.focusMode,
                            summarizeDocumentRequestID: appState.summarizeDocumentRequestID,
                            onHorizontalSwipe: handlePreviewSwipe(_:),
                            onAIError: { appState.errorMessage = $0 }
                        ) { editedText in
                            appState.userEdited(text: editedText)
                        } onEditingLocationChange: { location, textLength in
                            handleEditingLocationChange(location: location, textLength: textLength)
                        }
                    }

                    if appState.isPreviewPanelVisible {
                        Divider()
                            .opacity(0.5)
                        MarkdownWebPreviewView(
                            markdown: appState.text,
                            previewFont: appState.previewFontOption,
                            editorFollowRatio: previewFollowRatio,
                            editorFollowEventID: previewFollowEventID,
                            onHorizontalSwipe: handlePreviewSwipe(_:)
                        )
                            .frame(minWidth: 340, idealWidth: 460, maxWidth: 760, maxHeight: .infinity)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                HStack(spacing: 10) {
                    Text("Écrivisse")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        HoverPressActionButton(cornerRadius: 7, compact: true, preferRoundedRect: true, drawSurface: false) {
                            appState.decreaseEditorFontSize()
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .disabled(appState.editorFontSize <= appState.minimumEditorFontSize)
                        .opacity(appState.editorFontSize <= appState.minimumEditorFontSize ? 0.35 : 1.0)

                        Text("\(Int(appState.editorFontSize.rounded())) pt")
                            .frame(minWidth: 50, alignment: .center)
                            .font(.system(size: 11, weight: .medium, design: .rounded))

                        HoverPressActionButton(cornerRadius: 7, compact: true, preferRoundedRect: true, drawSurface: false) {
                            appState.increaseEditorFontSize()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .disabled(appState.editorFontSize >= appState.maximumEditorFontSize)
                        .opacity(appState.editorFontSize >= appState.maximumEditorFontSize ? 0.35 : 1.0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(bottomCapsuleFill(hovered: isFontControlHovered))
                    )
                    .overlay(
                        Capsule()
                            .stroke(bottomCapsuleBorder(hovered: isFontControlHovered), lineWidth: 0.8)
                    )
                    .onHover { hovered in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            isFontControlHovered = hovered
                        }
                    }

                    Menu {
                        ForEach(PreviewFontOption.allCases) { option in
                            Button {
                                appState.previewFontOption = option
                            } label: {
                                if appState.previewFontOption == option {
                                    Label(option.title, systemImage: "checkmark")
                                } else {
                                    Text(option.title)
                                }
                            }
                        }
                    } label: {
                        Label("Preview \(appState.previewFontOption.title)", systemImage: "textformat.alt")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .frame(minWidth: 116, minHeight: 30)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(bottomCapsuleFill(hovered: isPreviewFontControlHovered))
                    )
                    .overlay(
                        Capsule()
                            .stroke(bottomCapsuleBorder(hovered: isPreviewFontControlHovered), lineWidth: 0.8)
                    )
                    .onHover { hovered in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            isPreviewFontControlHovered = hovered
                        }
                    }

                    HoverPressActionButton(cornerRadius: 999, compact: true, drawSurface: false) {
                        appState.toggleDarkMode()
                    } label: {
                        Label(
                            appState.useDarkMode ? "Dark" : "Light",
                            systemImage: appState.useDarkMode ? "moon.fill" : "sun.max.fill"
                        )
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .labelStyle(.titleAndIcon)
                        .frame(minWidth: 82, minHeight: 30)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                    .onHover { hovered in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            isThemeControlHovered = hovered
                        }
                    }

                    Text("\(appState.wordCount) words  ·  \(appState.characterCount) characters")
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    Rectangle()
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                )
                .overlay(alignment: .top) {
                    Divider().opacity(0.45)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: appState.isPreviewPanelVisible)

            Button(action: { appState.togglePreviewPanel() }) {
                Text(appState.isPreviewPanelVisible ? "Hide Preview" : "Preview")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(
                                isPreviewButtonHovered
                                ? (colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08))
                                : (colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.04))
                            )
                    )
                    .overlay(
                        Capsule()
                            .stroke(
                                colorScheme == .dark
                                ? Color.white.opacity(isPreviewButtonHovered ? 0.32 : 0.16)
                                : Color.black.opacity(isPreviewButtonHovered ? 0.18 : 0.08),
                                lineWidth: 1
                            )
                    )
                    .foregroundStyle(Color.primary)
            }
            .buttonStyle(.plain)
            .onHover { isHovered in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isPreviewButtonHovered = isHovered
                }
            }
            .padding(.top, 10)
            .padding(.trailing, previewButtonTrailingPadding)
            .zIndex(5)
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 1)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                floatingMarkdownToolbar
                Spacer(minLength: 0)
            }
            .padding(.bottom, 92)
        }
        .background(
            WindowAccessor { window in
                appState.configure(window: window)
            }
        )
        .preferredColorScheme(appState.useDarkMode ? .dark : .light)
        .focusedSceneValue(\.activeAppState, appState)
        .onAppear {
            handleInitialSceneExternalFileIfNeeded()
            handlePendingExternalFiles()
        }
        .onReceive(externalFileOpenRouter.$eventID) { _ in
            handlePendingExternalFiles()
        }
        .onOpenURL { url in
            externalFileOpenRouter.enqueue(urls: [url])
            handlePendingExternalFiles()
        }
        .alert(
            "Operation Failed",
            isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        appState.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    private var floatingMarkdownToolbar: some View {
        toolbarPanel
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 20)
    }

    private var toolbarPanel: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") {
                        appState.applyEditorAction(.heading(level))
                    }
                }
            } label: {
                Label("Header", systemImage: "textformat.size")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)

            Divider()
                .frame(height: 16)

            floatingToolbarButton(label: "B") {
                appState.applyEditorAction(.bold)
            }
            floatingToolbarButton(label: "I") {
                appState.applyEditorAction(.italic)
            }
            floatingToolbarButton(label: "BI") {
                appState.applyEditorAction(.boldItalic)
            }
            floatingToolbarButton(symbol: "strikethrough") {
                appState.applyEditorAction(.strikethrough)
            }
            floatingToolbarButton(symbol: "chevron.left.forwardslash.chevron.right") {
                appState.applyEditorAction(.inlineCode)
            }
            floatingToolbarButton(label: "\\") {
                appState.applyEditorAction(.escapeCharacters)
            }

            Divider()
                .frame(height: 16)

            floatingToolbarButton(symbol: "list.bullet") {
                appState.applyEditorAction(.unorderedList)
            }
            floatingToolbarButton(symbol: "list.number") {
                appState.applyEditorAction(.orderedList)
            }
            floatingToolbarButton(symbol: "link") {
                appState.applyEditorAction(.link)
            }
            floatingToolbarButton(symbol: "chevron.left.square.chevron.right") {
                appState.applyEditorAction(.codeBlock)
            }
            floatingToolbarButton(symbol: "text.quote") {
                appState.applyEditorAction(.blockquote)
            }
            floatingToolbarButton(label: "Fn") {
                appState.applyEditorAction(.footnote)
            }

            HoverPressActionButton(cornerRadius: 7) {
                isTablePickerPresented.toggle()
            } label: {
                Image(systemName: "tablecells")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .popover(isPresented: $isTablePickerPresented, arrowEdge: .top) {
                tablePickerView
                    .padding(12)
                    .frame(width: 278)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(floatingToolbarFillInteractive)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    isFloatingToolbarHovered
                    ? (colorScheme == .dark ? Color.white.opacity(0.30) : Color.black.opacity(0.16))
                    : floatingToolbarBorder,
                    lineWidth: 1
                )
        )
        .shadow(
            color: colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.06),
            radius: 2.6,
            x: 0,
            y: 0
        )
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.12)) {
                isFloatingToolbarHovered = hovered
            }
        }
    }

    private var tablePickerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Insert Table")
                .font(.system(size: 13, weight: .semibold, design: .rounded))

            Text("\(tablePickerColumns) × \(tablePickerRows)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                ForEach(1...tablePickerMaxRows, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(1...tablePickerMaxColumns, id: \.self) { column in
                            Button {
                                tablePickerColumns = column
                                tablePickerRows = row
                                appState.applyEditorAction(.table(rows: row, columns: column))
                                isTablePickerPresented = false
                            } label: {
                                Rectangle()
                                    .fill(
                                        row <= tablePickerRows && column <= tablePickerColumns
                                        ? Color.accentColor.opacity(0.35)
                                        : Color.clear
                                    )
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        Rectangle()
                                            .stroke(Color.secondary.opacity(0.6), lineWidth: 0.8)
                                    )
                            }
                            .buttonStyle(.plain)
                            .onHover { hovered in
                                if hovered {
                                    tablePickerColumns = column
                                    tablePickerRows = row
                                }
                            }
                        }
                    }
                }
            }

            Button("Insert Table…") {
                appState.applyEditorAction(.table(rows: tablePickerRows, columns: tablePickerColumns))
                isTablePickerPresented = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }

    private func floatingToolbarButton(symbol: String, action: @escaping () -> Void) -> some View {
        HoverPressActionButton(cornerRadius: 7, compact: true, preferRoundedRect: true, hoverStrength: 1.0, pressStrength: 1.0, allowScale: true, lineWidth: 0.85) {
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
    }

    private func floatingToolbarButton(label: String, action: @escaping () -> Void) -> some View {
        HoverPressActionButton(cornerRadius: 7, compact: true, preferRoundedRect: true, hoverStrength: 1.0, pressStrength: 1.0, allowScale: true, lineWidth: 0.85) {
            action()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(minWidth: 30, minHeight: 28)
                .contentShape(Rectangle())
        }
    }

    private func handlePreviewSwipe(_ normalizedDeltaX: CGFloat) {
        if normalizedDeltaX < 0 {
            appState.hidePreviewPanel()
        } else if normalizedDeltaX > 0 {
            appState.showPreviewPanel()
        }
    }

    private func handleEditingLocationChange(location: Int, textLength: Int) {
        let safeLength = max(textLength, 1)
        let clampedLocation = min(max(location, 0), safeLength)
        var ratio = Double(clampedLocation) / Double(safeLength)
        if ratio < 0.03 {
            ratio = 0
        } else if ratio > 0.97 {
            ratio = 1
        }

        if lastCommittedPreviewFollowRatio >= 0,
           abs(lastCommittedPreviewFollowRatio - ratio) < 0.012 {
            return
        }

        lastCommittedPreviewFollowRatio = ratio
        previewFollowRatio = ratio
        previewFollowEventID &+= 1
    }

    private func handlePendingExternalFiles() {
        let urls = externalFileOpenRouter.drainPendingFileURLs()
        guard !urls.isEmpty else { return }

        dispatchExternalFilesToWindows(urls)
    }

    private func handleInitialSceneExternalFileIfNeeded() {
        guard !hasHandledInitialExternalFilePath else { return }
        hasHandledInitialExternalFilePath = true

        guard let path = initialExternalFilePath, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if appState.openDocument(at: url) {
            appState.revealConfiguredWindow()
        }
    }

    private func dispatchExternalFilesToWindows(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        var remainingURLs = urls.map(\.standardizedFileURL)

        if canReuseCurrentWindowForExternalOpen,
           let first = remainingURLs.first,
           appState.openDocument(at: first) {
            remainingURLs.removeFirst()
            appState.revealConfiguredWindow()
        }

        for url in remainingURLs {
            let path = url.path
            if !path.isEmpty {
                openWindow(value: ExternalWindowRequest(path: path))
            }
        }
    }

    private var canReuseCurrentWindowForExternalOpen: Bool {
        if appState.documentURL != nil { return false }
        if appState.isDirty { return false }
        return appState.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct HoverPressActionButton<Label: View>: View {
    let cornerRadius: CGFloat
    let compact: Bool
    let preferRoundedRect: Bool
    let hoverStrength: CGFloat
    let pressStrength: CGFloat
    let allowScale: Bool
    let lineWidth: CGFloat
    let drawSurface: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    init(
        cornerRadius: CGFloat,
        compact: Bool = false,
        preferRoundedRect: Bool = false,
        hoverStrength: CGFloat = 0.9,
        pressStrength: CGFloat = 1.0,
        allowScale: Bool = true,
        lineWidth: CGFloat = 0.8,
        drawSurface: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.cornerRadius = cornerRadius
        self.compact = compact
        self.preferRoundedRect = preferRoundedRect
        self.hoverStrength = hoverStrength
        self.pressStrength = pressStrength
        self.allowScale = allowScale
        self.lineWidth = lineWidth
        self.drawSurface = drawSurface
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
        }
        .buttonStyle(
            HoverPressSurfaceButtonStyle(
                colorScheme: colorScheme,
                isHovered: isHovered,
                cornerRadius: cornerRadius,
                compact: compact,
                preferRoundedRect: preferRoundedRect,
                hoverStrength: hoverStrength,
                pressStrength: pressStrength,
                allowScale: allowScale,
                lineWidth: lineWidth,
                drawSurface: drawSurface
            )
        )
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.10)) {
                isHovered = hovered
            }
        }
    }
}

private struct HoverPressSurfaceButtonStyle: ButtonStyle {
    let colorScheme: ColorScheme
    let isHovered: Bool
    let cornerRadius: CGFloat
    let compact: Bool
    let preferRoundedRect: Bool
    let hoverStrength: CGFloat
    let pressStrength: CGFloat
    let allowScale: Bool
    let lineWidth: CGFloat
    let drawSurface: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let fill = backgroundFill(isHovered: isHovered, isPressed: pressed)
        let hoverScale: CGFloat = allowScale && isHovered && !pressed ? 1.045 : 1.0
        let pressScale: CGFloat = allowScale && pressed ? 0.965 : 1.0
        let composedScale = hoverScale * pressScale
        let verticalLift: CGFloat = isHovered && !pressed ? -0.7 : 0
        let hoverShadowColor: Color =
            colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.12)

        return configuration.label
            .background(
                Group {
                    if drawSurface {
                        if preferRoundedRect {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(fill)
                        } else {
                            Capsule()
                                .fill(fill)
                        }
                    } else {
                        Color.clear
                    }
                }
            )
            .opacity(pressed ? (compact ? 0.88 : 0.92) : 1.0)
            .scaleEffect(composedScale)
            .offset(y: verticalLift)
            .shadow(
                color: isHovered && !pressed ? hoverShadowColor : .clear,
                radius: isHovered && !pressed ? 2.2 : 0,
                x: 0,
                y: isHovered && !pressed ? 1.2 : 0
            )
            .animation(.easeOut(duration: 0.09), value: pressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func backgroundFill(isHovered: Bool, isPressed: Bool) -> Color {
        let hoverBoost = max(0, min(hoverStrength, 1.8))
        let pressBoost = max(0, min(pressStrength, 1.8))
        let hoveredAmount = isHovered ? hoverBoost : 0
        let pressedAmount = isPressed ? pressBoost : 0

        if colorScheme == .dark {
            let alpha = 0.05 + (hoveredAmount * 0.08) + (pressedAmount * 0.06)
            return Color.white.opacity(min(alpha, 0.26))
        }

        let alpha = 0.01 + (hoveredAmount * 0.06) + (pressedAmount * 0.06)
        return Color.black.opacity(min(alpha, 0.18))
    }

}

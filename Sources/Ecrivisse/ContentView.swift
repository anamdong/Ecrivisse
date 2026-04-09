import SwiftUI
import AppKit

struct ContentView: View {
    private struct SidebarFile: Identifiable {
        let url: URL
        let relativePath: String

        var id: URL { url }
    }

    private struct SidebarFolder: Identifiable {
        let url: URL
        var files: [SidebarFile]

        var id: URL { url }
    }

    private struct CursorPaletteOption: Identifiable {
        let id: String
        let title: String
        let color: NSColor
    }

    private static let importedFolderPathsDefaultsKey = "ecrivisse.importedFolderPaths"
    private static let cursorPaletteOptions: [CursorPaletteOption] = [
        CursorPaletteOption(id: "red", title: "Red", color: NSColor(calibratedRed: 1.00, green: 0.30, blue: 0.25, alpha: 1.0)),
        CursorPaletteOption(id: "blue", title: "Blue", color: NSColor(calibratedRed: 0.20, green: 0.49, blue: 1.00, alpha: 1.0)),
        CursorPaletteOption(id: "green", title: "Green", color: NSColor(calibratedRed: 0.13, green: 0.78, blue: 0.39, alpha: 1.0)),
        CursorPaletteOption(id: "gray", title: "Gray", color: NSColor(calibratedRed: 0.56, green: 0.59, blue: 0.63, alpha: 1.0)),
        CursorPaletteOption(id: "purple", title: "Purple", color: NSColor(calibratedRed: 0.54, green: 0.38, blue: 0.96, alpha: 1.0)),
        CursorPaletteOption(id: "pink", title: "Pink", color: NSColor(calibratedRed: 0.95, green: 0.31, blue: 0.62, alpha: 1.0)),
        CursorPaletteOption(id: "teal", title: "Teal", color: NSColor(calibratedRed: 0.08, green: 0.75, blue: 0.73, alpha: 1.0)),
        CursorPaletteOption(id: "orange", title: "Orange", color: NSColor(calibratedRed: 1.00, green: 0.56, blue: 0.25, alpha: 1.0))
    ]

    let initialExternalFileRequest: ExternalWindowRequest?

    @StateObject private var appState = AppState()
    @ObservedObject private var externalFileOpenRouter = ExternalFileOpenRouter.shared
    @State private var isFolderSidebarVisible = false
    @State private var importedFolders: [SidebarFolder] = []
    @State private var selectedSidebarFolderURL: URL?
    @State private var isSettingsPresented = false
    @State private var isPreviewButtonHovered = false
    @State private var isFolderButtonHovered = false
    @State private var isTablePickerPresented = false
    @State private var tablePickerColumns = 3
    @State private var tablePickerRows = 3
    @State private var hasHandledInitialExternalFileRequest = false
    @State private var previewFollowRatio: Double = 0
    @State private var previewFollowEventID: Int = 0
    @State private var isFontControlHovered = false
    @State private var isPreviewFontControlHovered = false
    @State private var isThemeControlHovered = false
    @State private var isFloatingToolbarHovered = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    private let tablePickerMaxColumns = 10
    private let tablePickerMaxRows = 8
    private let sidebarWidth: CGFloat = 260
    private let folderRefreshTimer = Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()

    private var previewButtonTrailingPadding: CGFloat {
        appState.isPreviewPanelVisible ? 42 : 26
    }

    private var folderButtonLeadingPadding: CGFloat {
        previewButtonTrailingPadding
    }

    private var sidebarContentLeadingPadding: CGFloat {
        folderButtonLeadingPadding
    }

    private var floatingToolbarOverlayAlignment: Alignment {
        switch appState.floatingToolbarPosition {
        case .top:
            return .top
        case .bottom:
            return .bottom
        }
    }

    private var floatingToolbarTopEdgePadding: CGFloat {
        16
    }

    private var floatingToolbarBottomEdgePadding: CGFloat {
        58
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
            editorBackgroundColor
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if isFolderSidebarVisible {
                        folderSidebar
                        Divider()
                            .opacity(0.55)
                    }

                    ZStack {
                        editorBackgroundColor
                            .ignoresSafeArea()

                        WriterEditorView(
                            text: $appState.text,
                            fontSize: appState.editorFontSize,
                            focusMode: appState.focusMode,
                            cursorColor: appState.editorCursorNSColor,
                            summarizeDocumentRequestID: appState.summarizeDocumentRequestID,
                            onHorizontalSwipe: handlePreviewSwipe(_:),
                            onAIError: { appState.errorMessage = $0 }
                        ) { editedText in
                            appState.userEdited(text: editedText)
                        } onEditingLocationChange: { location, textLength in
                            handleEditingLocationChange(location: location, textLength: textLength)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if appState.isPreviewPanelVisible {
                        Divider()
                            .opacity(0.5)
                        MarkdownWebPreviewView(
                            markdown: appState.text,
                            previewFont: appState.previewFontOption,
                            cursorColorHex: appState.editorCursorColorHex,
                            editorFollowRatio: previewFollowRatio,
                            editorFollowEventID: previewFollowEventID,
                            onHorizontalSwipe: handlePreviewSwipe(_:),
                            onTaskToggle: { taskIndex, checked in
                                appState.setTaskListItemChecked(at: taskIndex, checked: checked)
                            },
                            onNavigateToSourceLine: { sourceLine in
                                appState.scrollEditorToSourceLine(sourceLine)
                            }
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
                        HoverPressActionButton(
                            cornerRadius: 7,
                            compact: true,
                            preferRoundedRect: true,
                            drawSurface: false
                        ) {
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

                        HoverPressActionButton(
                            cornerRadius: 7,
                            compact: true,
                            preferRoundedRect: true,
                            drawSurface: false
                        ) {
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

                    HoverPressActionButton(
                        cornerRadius: 999,
                        compact: true,
                        drawSurface: false
                    ) {
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

                    HoverPressActionButton(
                        cornerRadius: 8,
                        compact: true,
                        preferRoundedRect: true,
                        drawSurface: false
                    ) {
                        isSettingsPresented = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .foregroundStyle(.secondary)

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
                                ? (colorScheme == .dark
                                    ? Color(nsColor: NSColor(calibratedWhite: 0.24, alpha: 1.0))
                                    : Color(nsColor: NSColor(calibratedWhite: 0.90, alpha: 1.0)))
                                : (colorScheme == .dark
                                    ? Color(nsColor: NSColor(calibratedWhite: 0.20, alpha: 1.0))
                                    : Color(nsColor: NSColor(calibratedWhite: 0.94, alpha: 1.0)))
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
        .overlay(alignment: floatingToolbarOverlayAlignment) {
            floatingToolbarOverlay
        }
        .overlay(alignment: .topLeading) {
            folderSidebarToggleFloatingButton
        }
        .background(
            WindowAccessor { window in
                appState.configure(window: window)
            }
        )
        .preferredColorScheme(appState.useDarkMode ? .dark : .light)
        .focusedSceneValue(\.activeAppState, appState)
        .onAppear {
            loadPersistedImportedFolders()
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
        .onReceive(folderRefreshTimer) { _ in
            refreshImportedFoldersFromDiskIfNeeded()
        }
        .sheet(isPresented: $isSettingsPresented) {
            settingsSheet
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

    private var folderSidebarToggleFloatingButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) {
                isFolderSidebarVisible.toggle()
            }
        }) {
            Label(
                isFolderSidebarVisible ? "Hide Folders" : "Folders",
                systemImage: "sidebar.left"
            )
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(
                        isFolderButtonHovered
                        ? (colorScheme == .dark
                            ? Color(nsColor: NSColor(calibratedWhite: 0.24, alpha: 1.0))
                            : Color(nsColor: NSColor(calibratedWhite: 0.90, alpha: 1.0)))
                        : (colorScheme == .dark
                            ? Color(nsColor: NSColor(calibratedWhite: 0.20, alpha: 1.0))
                            : Color(nsColor: NSColor(calibratedWhite: 0.94, alpha: 1.0)))
                    )
            )
            .overlay(
                Capsule()
                    .stroke(
                        colorScheme == .dark
                        ? Color.white.opacity(isFolderButtonHovered ? 0.32 : 0.16)
                        : Color.black.opacity(isFolderButtonHovered ? 0.18 : 0.08),
                        lineWidth: 1
                    )
            )
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.12)) {
                isFolderButtonHovered = isHovered
            }
        }
        .padding(.top, 10)
        .padding(.leading, folderButtonLeadingPadding)
        .zIndex(5)
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 1)
    }

    @ViewBuilder
    private var floatingToolbarOverlay: some View {
        switch appState.floatingToolbarPosition {
        case .top:
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                floatingMarkdownToolbar
                Spacer(minLength: 0)
            }
            .padding(.top, floatingToolbarTopEdgePadding)
        case .bottom:
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                floatingMarkdownToolbar
                Spacer(minLength: 0)
            }
            .padding(.bottom, floatingToolbarBottomEdgePadding)
        }
    }

    private var floatingMarkdownToolbar: some View {
        toolbarPanel
            .padding(.horizontal, 20)
    }

    private var folderSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                HoverPressActionButton(
                    cornerRadius: 7,
                    compact: true,
                    preferRoundedRect: true,
                    drawSurface: false
                ) {
                    addFolderFromFinder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.secondary)

                HoverPressActionButton(
                    cornerRadius: 7,
                    compact: true,
                    preferRoundedRect: true,
                    drawSurface: false
                ) {
                    createNewDocumentInActiveFolder()
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.secondary)
                .disabled(activeSidebarFolderURL == nil)
                .opacity(activeSidebarFolderURL == nil ? 0.35 : 1.0)
            }
            .padding(.leading, sidebarContentLeadingPadding)
            .padding(.trailing, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if importedFolders.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No folders added")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Use the folder button to add a folder from Finder.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.9))
                }
                .padding(.leading, sidebarContentLeadingPadding)
                .padding(.trailing, 12)
                .padding(.top, 10)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(importedFolders) { folder in
                            folderSection(folder)
                        }
                    }
                    .padding(.leading, sidebarContentLeadingPadding)
                    .padding(.trailing, 10)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            Color(nsColor: colorScheme == .dark
                  ? NSColor(calibratedWhite: 0.115, alpha: 1.0)
                  : NSColor(calibratedWhite: 0.965, alpha: 1.0))
        )
    }

    private func folderSection(_ folder: SidebarFolder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(folder.url.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                HoverPressActionButton(
                    cornerRadius: 7,
                    compact: true,
                    preferRoundedRect: true,
                    drawSurface: false,
                    helpText: "Remove Folder"
                ) {
                    removeImportedFolder(folder.url)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)

            if folder.files.isEmpty {
                Text("No supported text files found")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .padding(.top, 2)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(folder.files) { file in
                        Button {
                            selectedSidebarFolderURL = folder.url.standardizedFileURL
                            _ = appState.openDocument(at: file.url)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.plaintext")
                                    .font(.system(size: 10, weight: .regular))
                                    .foregroundStyle(.secondary)
                                Text(file.relativePath)
                                    .font(.system(size: 11, weight: .regular))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(
                                        isSidebarFileSelected(file.url)
                                        ? (colorScheme == .dark
                                            ? Color.white.opacity(0.14)
                                            : Color.black.opacity(0.08))
                                        : Color.clear
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Open") {
                                selectedSidebarFolderURL = folder.url.standardizedFileURL
                                _ = appState.openDocument(at: file.url)
                            }
                            Button("Open in New Tab") {
                                openSidebarFileInNewTab(file.url)
                            }
                            Button("Open in New Window") {
                                openWindow(value: ExternalWindowRequest(path: file.url.path))
                            }
                            Divider()
                            Button("Rename…") {
                                renameSidebarFile(file.url)
                            }
                            Button("Delete", role: .destructive) {
                                deleteSidebarFile(file.url)
                            }
                        }
                    }
                }
            }
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Preview") {
                    Picker("Font", selection: $appState.previewFontOption) {
                        ForEach(PreviewFontOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                }

                Section("Editor") {
                    Text("Cursor Color")
                    LazyVGrid(columns: [
                        GridItem(.flexible(minimum: 98), spacing: 8),
                        GridItem(.flexible(minimum: 98), spacing: 8),
                        GridItem(.flexible(minimum: 98), spacing: 8)
                    ], alignment: .leading, spacing: 8) {
                        ForEach(Self.cursorPaletteOptions) { option in
                            Button {
                                appState.setEditorCursorNSColor(option.color)
                            } label: {
                                HStack(spacing: 7) {
                                    Circle()
                                        .fill(Color(nsColor: option.color))
                                        .frame(width: 10, height: 10)
                                    Text(option.title)
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(
                                            appState.editorCursorColorHex == cursorHex(for: option.color)
                                            ? (colorScheme == .dark ? Color.white.opacity(0.17) : Color.black.opacity(0.10))
                                            : (colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.03))
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Spacer(minLength: 0)
                        Button("Set to Default") {
                            appState.resetEditorCursorColorToDefault()
                        }
                        .disabled(appState.editorCursorColorHex == AppState.defaultEditorCursorColorHex)
                    }
                }

                Section("Floating Menu") {
                    Picker("Position", selection: $appState.floatingToolbarPosition) {
                        ForEach(FloatingToolbarPosition.allCases) { position in
                            Text(position.title).tag(position)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(16)
            .frame(width: 430)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isSettingsPresented = false
                    }
                }
            }
        }
    }

    private var toolbarPanel: some View {
        Group {
            HStack(spacing: 6) {
                headingMenuButton

                Divider()
                    .frame(height: 16)

                floatingToolbarButton(label: "B", help: "Bold") {
                    appState.applyEditorAction(.bold)
                }
                floatingToolbarButton(label: "I", help: "Italic") {
                    appState.applyEditorAction(.italic)
                }
                floatingToolbarButton(label: "BI", help: "Bold Italic") {
                    appState.applyEditorAction(.boldItalic)
                }
                floatingToolbarButton(symbol: "strikethrough", help: "Strikethrough") {
                    appState.applyEditorAction(.strikethrough)
                }
                floatingToolbarButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Inline Code") {
                    appState.applyEditorAction(.inlineCode)
                }
                floatingToolbarButton(label: "\\", help: "Escape Characters") {
                    appState.applyEditorAction(.escapeCharacters)
                }

                Divider()
                    .frame(height: 16)

                floatingToolbarButton(symbol: "list.bullet", help: "Bulleted List") {
                    appState.applyEditorAction(.unorderedList)
                }
                floatingToolbarButton(symbol: "list.number", help: "Numbered List") {
                    appState.applyEditorAction(.orderedList)
                }
                floatingToolbarButton(symbol: "checkmark.square", help: "Checklist") {
                    appState.applyEditorAction(.checklist)
                }
                floatingToolbarButton(symbol: "link", help: "Insert Link") {
                    appState.applyEditorAction(.link)
                }
                floatingToolbarButton(symbol: "terminal", help: "Code Block") {
                    appState.applyEditorAction(.codeBlock)
                }
                floatingToolbarButton(symbol: "text.quote", help: "Blockquote") {
                    appState.applyEditorAction(.blockquote)
                }
                floatingToolbarButton(label: "Fn", help: "Footnote") {
                    appState.applyEditorAction(.footnote)
                }
                floatingToolbarButton(label: "TOC", help: "Insert Table of Contents") {
                    appState.applyEditorAction(.toc)
                }

                tableInsertButton
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

    private var headingMenuButton: some View {
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
    }

    private var tableInsertButton: some View {
        HoverPressActionButton(cornerRadius: 7, helpText: "Insert Table") {
            isTablePickerPresented.toggle()
        } label: {
            Image(systemName: "tablecells")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .popover(isPresented: $isTablePickerPresented, arrowEdge: tablePopoverArrowEdge) {
            tablePickerView
                .padding(12)
                .frame(width: 278)
        }
    }

    private var tablePopoverArrowEdge: Edge {
        .top
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

    private func floatingToolbarButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        HoverPressActionButton(
            cornerRadius: 7,
            compact: true,
            preferRoundedRect: true,
            hoverStrength: 1.0,
            pressStrength: 1.0,
            allowScale: true,
            lineWidth: 0.85,
            helpText: help
        ) {
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
    }

    private func floatingToolbarButton(label: String, help: String, action: @escaping () -> Void) -> some View {
        HoverPressActionButton(
            cornerRadius: 7,
            compact: true,
            preferRoundedRect: true,
            hoverStrength: 1.0,
            pressStrength: 1.0,
            allowScale: true,
            lineWidth: 0.85,
            helpText: help
        ) {
            action()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(minWidth: 30, minHeight: 28)
                .contentShape(Rectangle())
        }
    }

    private func addFolderFromFinder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"

        guard panel.runModal() == .OK else { return }

        var updatedFolders = importedFolders
        let selectedURLs = panel.urls.map(\.standardizedFileURL)
        if let firstSelected = selectedURLs.first {
            selectedSidebarFolderURL = firstSelected
        }
        for selectedURL in selectedURLs {
            let files = discoverSupportedFiles(in: selectedURL)
            if let existingIndex = updatedFolders.firstIndex(where: { $0.url == selectedURL }) {
                updatedFolders[existingIndex].files = files
            } else {
                updatedFolders.append(SidebarFolder(url: selectedURL, files: files))
            }
        }

        updatedFolders.sort {
            $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
        }
        importedFolders = updatedFolders
        persistImportedFolders()
        isFolderSidebarVisible = true
    }

    private var activeSidebarFolderURL: URL? {
        if let selectedSidebarFolderURL {
            let selected = selectedSidebarFolderURL.standardizedFileURL
            if importedFolders.contains(where: { $0.url.standardizedFileURL == selected }) {
                return selected
            }
        }

        if let currentDocumentURL = appState.documentURL?.standardizedFileURL {
            let containingFolders = importedFolders
                .map { $0.url.standardizedFileURL }
                .filter { folderURL in
                    if currentDocumentURL == folderURL { return true }
                    let folderPrefix = folderURL.path.hasSuffix("/")
                        ? folderURL.path
                        : folderURL.path + "/"
                    return currentDocumentURL.path.hasPrefix(folderPrefix)
                }
                .sorted { $0.path.count > $1.path.count }
            if let deepestMatch = containingFolders.first {
                return deepestMatch
            }
        }

        return importedFolders.first?.url.standardizedFileURL
    }

    private func createNewDocumentInActiveFolder() {
        guard let folderURL = activeSidebarFolderURL else { return }
        let standardizedFolder = folderURL.standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedFolder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        let newFileURL = nextUntitledDocumentURL(in: standardizedFolder)
        do {
            try Data().write(to: newFileURL, options: .atomic)
            selectedSidebarFolderURL = standardizedFolder
            refreshImportedFoldersFromDiskIfNeeded()
            _ = appState.openDocument(at: newFileURL)
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func nextUntitledDocumentURL(in folderURL: URL) -> URL {
        let fileManager = FileManager.default
        var candidate = folderURL.appendingPathComponent("Untitled.md")
        var index = 2

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folderURL.appendingPathComponent("Untitled \(index).md")
            index += 1
        }
        return candidate
    }

    private func renameSidebarFile(_ fileURL: URL) {
        let sourceURL = fileURL.standardizedFileURL

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Rename File"
        alert.informativeText = "Enter a new name for \"\(sourceURL.lastPathComponent)\"."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(string: sourceURL.lastPathComponent)
        textField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var proposedName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposedName.isEmpty else { return }
        guard !proposedName.contains("/"), !proposedName.contains(":") else {
            appState.errorMessage = "The file name contains unsupported characters."
            return
        }

        if !proposedName.contains("."), !sourceURL.pathExtension.isEmpty {
            proposedName += ".\(sourceURL.pathExtension)"
        }

        let destinationURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(proposedName)
            .standardizedFileURL

        guard destinationURL != sourceURL else { return }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            appState.errorMessage = "A file named \"\(proposedName)\" already exists."
            return
        }

        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            selectedSidebarFolderURL = sourceURL.deletingLastPathComponent().standardizedFileURL
            if appState.documentURL?.standardizedFileURL == sourceURL {
                appState.documentURL = destinationURL
            }
            refreshImportedFoldersFromDiskIfNeeded()
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func deleteSidebarFile(_ fileURL: URL) {
        let targetURL = fileURL.standardizedFileURL

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \"\(targetURL.lastPathComponent)\" to Trash?"
        alert.informativeText = "You can recover it later from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: targetURL, resultingItemURL: &trashedURL)
        } catch {
            do {
                try FileManager.default.removeItem(at: targetURL)
            } catch {
                appState.errorMessage = error.localizedDescription
                return
            }
        }

        if appState.documentURL?.standardizedFileURL == targetURL {
            appState.documentURL = nil
            appState.isDirty = true
        }

        selectedSidebarFolderURL = targetURL.deletingLastPathComponent().standardizedFileURL
        refreshImportedFoldersFromDiskIfNeeded()
    }

    private func removeImportedFolder(_ folderURL: URL) {
        importedFolders.removeAll { $0.url == folderURL.standardizedFileURL }
        persistImportedFolders()
    }

    private func loadPersistedImportedFolders() {
        let storedPaths = UserDefaults.standard.stringArray(forKey: Self.importedFolderPathsDefaultsKey) ?? []
        guard !storedPaths.isEmpty else { return }

        var restoredFolders: [SidebarFolder] = []
        var persistedValidPaths: [String] = []
        let fileManager = FileManager.default

        for rawPath in storedPaths {
            let folderURL = URL(fileURLWithPath: rawPath).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            persistedValidPaths.append(folderURL.path)
            restoredFolders.append(
                SidebarFolder(
                    url: folderURL,
                    files: discoverSupportedFiles(in: folderURL)
                )
            )
        }

        if !restoredFolders.isEmpty {
            restoredFolders.sort {
                $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
            }
            importedFolders = restoredFolders
        }

        UserDefaults.standard.set(persistedValidPaths, forKey: Self.importedFolderPathsDefaultsKey)
    }

    private func persistImportedFolders() {
        let paths = importedFolders.map { $0.url.standardizedFileURL.path }
        UserDefaults.standard.set(paths, forKey: Self.importedFolderPathsDefaultsKey)
    }

    private func refreshImportedFoldersFromDiskIfNeeded() {
        guard !importedFolders.isEmpty else { return }

        let fileManager = FileManager.default
        let previousFolders = importedFolders
        let previousPaths = previousFolders.map { $0.url.standardizedFileURL.path }

        var refreshedFolders: [SidebarFolder] = []
        var validPaths: [String] = []
        var hasFolderContentChanges = false

        for folder in previousFolders {
            let folderURL = folder.url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                hasFolderContentChanges = true
                continue
            }

            let refreshedFiles = discoverSupportedFiles(in: folderURL)
            if !sidebarFilesEqual(folder.files, refreshedFiles) {
                hasFolderContentChanges = true
            }
            if folderURL != folder.url {
                hasFolderContentChanges = true
            }

            validPaths.append(folderURL.path)
            refreshedFolders.append(SidebarFolder(url: folderURL, files: refreshedFiles))
        }

        if hasFolderContentChanges {
            importedFolders = refreshedFolders
        }

        if validPaths != previousPaths {
            UserDefaults.standard.set(validPaths, forKey: Self.importedFolderPathsDefaultsKey)
        }
    }

    private func sidebarFilesEqual(_ lhs: [SidebarFile], _ rhs: [SidebarFile]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            if left.url != right.url || left.relativePath != right.relativePath {
                return false
            }
        }
        return true
    }

    private func discoverSupportedFiles(in folderURL: URL) -> [SidebarFile] {
        let standardizedFolder = folderURL.standardizedFileURL
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]

        guard let enumerator = fileManager.enumerator(
            at: standardizedFolder,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return []
        }

        var files: [SidebarFile] = []
        let supportedExtensions = AppState.supportedSidebarFileExtensions
        let folderPrefix = standardizedFolder.path.hasSuffix("/")
            ? standardizedFolder.path
            : standardizedFolder.path + "/"

        for case let candidateURL as URL in enumerator {
            let fileURL = candidateURL.standardizedFileURL
            let fileExtension = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(fileExtension) else { continue }

            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else {
                continue
            }

            let relativePath: String
            if fileURL.path.hasPrefix(folderPrefix) {
                relativePath = String(fileURL.path.dropFirst(folderPrefix.count))
            } else {
                relativePath = fileURL.lastPathComponent
            }

            files.append(SidebarFile(url: fileURL, relativePath: relativePath))
        }

        files.sort { left, right in
            left.relativePath.localizedStandardCompare(right.relativePath) == .orderedAscending
        }
        return files
    }

    private func isSidebarFileSelected(_ fileURL: URL) -> Bool {
        guard let current = appState.documentURL?.standardizedFileURL else { return false }
        return current == fileURL.standardizedFileURL
    }

    private func cursorHex(for color: NSColor) -> String {
        let normalized = color.usingColorSpace(.extendedSRGB) ?? color.usingColorSpace(.deviceRGB) ?? color
        let red = Int((max(0, min(1, normalized.redComponent)) * 255).rounded())
        let green = Int((max(0, min(1, normalized.greenComponent)) * 255).rounded())
        let blue = Int((max(0, min(1, normalized.blueComponent)) * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private func openSidebarFileInNewTab(_ fileURL: URL) {
        let targetURL = fileURL.standardizedFileURL
        selectedSidebarFolderURL = targetURL.deletingLastPathComponent().standardizedFileURL

        let sourceWindow = appState.windowForTabOperations()
        let existingWindowIDs = Set(NSApp.windows.map(ObjectIdentifier.init))

        openWindow(value: ExternalWindowRequest(path: targetURL.path))

        guard let sourceWindow else { return }
        attachOpenedFileWindowAsTab(
            sourceWindow: sourceWindow,
            targetURL: targetURL,
            existingWindowIDs: existingWindowIDs
        )
    }

    private func attachOpenedFileWindowAsTab(
        sourceWindow: NSWindow,
        targetURL: URL,
        existingWindowIDs: Set<ObjectIdentifier>,
        retryCount: Int = 0
    ) {
        let candidates = NSApp.windows.filter { window in
            window !== sourceWindow &&
            !existingWindowIDs.contains(ObjectIdentifier(window)) &&
            window.canBecomeMain &&
            !window.isExcludedFromWindowsMenu
        }

        let targetWindow =
            candidates.first { $0.representedURL?.standardizedFileURL == targetURL } ??
            candidates.first

        if let targetWindow {
            sourceWindow.tabbingMode = .preferred
            sourceWindow.tabbingIdentifier = "ecrivisse-document"
            targetWindow.tabbingMode = .preferred
            targetWindow.tabbingIdentifier = "ecrivisse-document"
            sourceWindow.addTabbedWindow(targetWindow, ordered: .above)

            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            targetWindow.makeKeyAndOrderFront(nil)
            return
        }

        guard retryCount < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            attachOpenedFileWindowAsTab(
                sourceWindow: sourceWindow,
                targetURL: targetURL,
                existingWindowIDs: existingWindowIDs,
                retryCount: retryCount + 1
            )
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
        previewFollowRatio = ratio
        previewFollowEventID &+= 1
    }

    private func handlePendingExternalFiles() {
        let urls = externalFileOpenRouter.drainPendingFileURLs()
        guard !urls.isEmpty else { return }

        dispatchExternalFilesToWindows(urls)
    }

    private func handleInitialSceneExternalFileIfNeeded() {
        guard !hasHandledInitialExternalFileRequest else { return }
        hasHandledInitialExternalFileRequest = true

        guard let request = initialExternalFileRequest else { return }
        guard !InitialExternalFileRequestTracker.hasConsumed(request.token) else { return }
        InitialExternalFileRequestTracker.consume(request.token)

        let path = request.path
        guard !path.isEmpty else { return }
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

@MainActor
private enum InitialExternalFileRequestTracker {
    private static var consumedTokens: Set<UUID> = []

    static func hasConsumed(_ token: UUID) -> Bool {
        consumedTokens.contains(token)
    }

    static func consume(_ token: UUID) {
        consumedTokens.insert(token)
    }
}

private struct HoverPressActionButton<Label: View>: View {
    enum QuickHelpPlacement {
        case above
        case below
    }

    private let quickHelpDelay: TimeInterval = 0.14

    let cornerRadius: CGFloat
    let compact: Bool
    let preferRoundedRect: Bool
    let hoverStrength: CGFloat
    let pressStrength: CGFloat
    let allowScale: Bool
    let lineWidth: CGFloat
    let drawSurface: Bool
    let quickHelpPlacement: QuickHelpPlacement
    let helpText: String?
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isShowingQuickHelp = false
    @State private var quickHelpWorkItem: DispatchWorkItem?

    private var quickHelpFill: Color {
        colorScheme == .dark ? Color.black.opacity(0.88) : Color.white.opacity(0.98)
    }

    private var quickHelpBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.17) : Color.black.opacity(0.12)
    }

    private var quickHelpForeground: Color {
        colorScheme == .dark ? Color.white : Color.black.opacity(0.92)
    }

    private var quickHelpShadow: Color {
        Color.black.opacity(colorScheme == .dark ? 0.35 : 0.18)
    }

    init(
        cornerRadius: CGFloat,
        compact: Bool = false,
        preferRoundedRect: Bool = false,
        hoverStrength: CGFloat = 0.9,
        pressStrength: CGFloat = 1.0,
        allowScale: Bool = true,
        lineWidth: CGFloat = 0.8,
        drawSurface: Bool = true,
        quickHelpPlacement: QuickHelpPlacement = .above,
        helpText: String? = nil,
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
        self.quickHelpPlacement = quickHelpPlacement
        self.helpText = helpText
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
        .overlay(alignment: quickHelpPlacement == .above ? .top : .bottom) {
            quickHelpBubble
        }
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.10)) {
                isHovered = hovered
            }
            updateQuickHelpVisibility(hovered: hovered)
        }
        .onDisappear {
            quickHelpWorkItem?.cancel()
        }
        .zIndex(isShowingQuickHelp ? 2000 : 0)
    }

    private func updateQuickHelpVisibility(hovered: Bool) {
        quickHelpWorkItem?.cancel()
        quickHelpWorkItem = nil

        guard hovered, let helpText, !helpText.isEmpty else {
            withAnimation(.easeOut(duration: 0.08)) {
                isShowingQuickHelp = false
            }
            return
        }

        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.10)) {
                isShowingQuickHelp = true
            }
        }
        quickHelpWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + quickHelpDelay, execute: work)
    }

    @ViewBuilder
    private var quickHelpBubble: some View {
        if isShowingQuickHelp, let helpText, !helpText.isEmpty {
            Text(helpText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(quickHelpFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(quickHelpBorder, lineWidth: 0.8)
                )
                .foregroundStyle(quickHelpForeground)
                .offset(y: quickHelpPlacement == .above ? -34 : 34)
                .shadow(color: quickHelpShadow, radius: 4, x: 0, y: 2)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
                .allowsHitTesting(false)
                .zIndex(1000)
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

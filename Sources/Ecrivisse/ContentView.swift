import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState()
    @ObservedObject private var externalFileOpenRouter = ExternalFileOpenRouter.shared
    @State private var isPreviewButtonHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var previewButtonTrailingPadding: CGFloat {
        appState.isPreviewPanelVisible ? 42 : 26
    }

    private var editorBackgroundColor: Color {
        if colorScheme == .dark {
            return Color(nsColor: .textBackgroundColor)
        }
        return Color(nsColor: NSColor(calibratedWhite: 0.95, alpha: 1.0))
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
                        }
                    }

                    if appState.isPreviewPanelVisible {
                        Divider()
                            .opacity(0.5)
                        MarkdownWebPreviewView(
                            markdown: appState.text,
                            onHorizontalSwipe: handlePreviewSwipe(_:)
                        )
                            .frame(minWidth: 340, idealWidth: 460, maxWidth: 760, maxHeight: .infinity)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                HStack {
                    Text("Écrivisse")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)

                    Spacer()

                    HStack(spacing: 8) {
                        Button(action: { appState.decreaseEditorFontSize() }) {
                            Image(systemName: "textformat.size.smaller")
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.editorFontSize <= appState.minimumEditorFontSize)
                        .opacity(appState.editorFontSize <= appState.minimumEditorFontSize ? 0.35 : 1.0)

                        Text("\(Int(appState.editorFontSize.rounded())) pt")
                            .frame(minWidth: 44, alignment: .trailing)
                            .font(.system(size: 11, weight: .medium, design: .rounded))

                        Button(action: { appState.increaseEditorFontSize() }) {
                            Image(systemName: "textformat.size.larger")
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.editorFontSize >= appState.maximumEditorFontSize)
                        .opacity(appState.editorFontSize >= appState.maximumEditorFontSize ? 0.35 : 1.0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04))
                    )

                    Button(action: { appState.toggleDarkMode() }) {
                        Label(
                            appState.useDarkMode ? "Dark" : "Light",
                            systemImage: appState.useDarkMode ? "moon.fill" : "sun.max.fill"
                        )
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04))
                    )

                    Text("\(appState.wordCount) words  ·  \(appState.characterCount) characters")
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
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
        .background(
            WindowAccessor { window in
                appState.configure(window: window)
            }
        )
        .preferredColorScheme(appState.useDarkMode ? .dark : .light)
        .focusedSceneValue(\.activeAppState, appState)
        .onAppear(perform: handlePendingExternalFiles)
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

    private func handlePreviewSwipe(_ normalizedDeltaX: CGFloat) {
        if normalizedDeltaX < 0 {
            appState.hidePreviewPanel()
        } else if normalizedDeltaX > 0 {
            appState.showPreviewPanel()
        }
    }

    private func handlePendingExternalFiles() {
        let urls = externalFileOpenRouter.drainPendingFileURLs()
        guard !urls.isEmpty else { return }

        for url in urls {
            if appState.openDocument(at: url) {
                break
            }
        }
    }
}

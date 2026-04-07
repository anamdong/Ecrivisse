import SwiftUI
import AppKit

@main
struct EcrivisseApp: App {
    @NSApplicationDelegateAdaptor(EcrivisseAppDelegate.self) private var appDelegate
    private let minimumContentWidth: CGFloat = 620
    private let minimumContentHeight: CGFloat = 420

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: minimumContentWidth, minHeight: minimumContentHeight)
        }
        .defaultSize(width: 980, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            WriterCommands()
        }
    }
}

final class EcrivisseAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Finder/Open-With can launch the app with file paths in argv before
        // regular open-file delegate callbacks are observed.
        let launchArgumentURLs = CommandLine.arguments
            .dropFirst()
            .compactMap(Self.fileURLFromLaunchArgument(_:))

        if !launchArgumentURLs.isEmpty {
            enqueue(urls: launchArgumentURLs)
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        enqueue(urls: [URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        enqueue(urls: urls)
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        enqueue(urls: urls)
    }

    private func enqueue(urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            ExternalFileOpenRouter.shared.enqueue(urls: urls)
            revealWindowForExternalOpen()
        }
    }

    @MainActor
    private func revealWindowForExternalOpen(retryCount: Int = 0) {
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])

        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isExcludedFromWindowsMenu }) ?? NSApp.windows.first {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        if retryCount == 8 {
            _ = NSApp.sendAction(#selector(NSDocumentController.newDocument(_:)), to: nil, from: nil)
        }

        guard retryCount < 30 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.revealWindowForExternalOpen(retryCount: retryCount + 1)
        }
    }

    private static func fileURLFromLaunchArgument(_ argument: String) -> URL? {
        guard !argument.isEmpty else { return nil }
        guard !argument.hasPrefix("-psn_") else { return nil }

        if argument.hasPrefix("file://"), let url = URL(string: argument) {
            return url
        }

        let path = NSString(string: argument).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
}

private struct WriterCommands: Commands {
    @FocusedValue(\.activeAppState) private var appState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Empty Document") {
                appState?.newDocument()
            }
            .keyboardShortcut("N", modifiers: [.command, .shift])
            .disabled(appState == nil)

            Button("Open…") {
                appState?.openDocument()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(appState == nil)

            Divider()

            Button("Close Window") {
                appState?.requestCloseWindow()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(appState == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                appState?.saveDocument()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(appState == nil)

            Button("Save As…") {
                appState?.saveDocumentAs()
            }
            .keyboardShortcut("S", modifiers: [.command, .shift])
            .disabled(appState == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                appState?.printDocument()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(appState == nil)
        }

        CommandGroup(after: .saveItem) {
            Divider()

            Button("Export as PDF…") {
                appState?.exportPDF()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(appState == nil)

            Button("Export as HTML…") {
                appState?.exportHTML()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(appState == nil)

            if appState?.canExportDOCX == true {
                Button("Export as DOCX…") {
                    appState?.exportDOCX()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(appState == nil)
            }
        }

        CommandMenu("AI") {
            Button("Summarize Current Document") {
                appState?.requestDocumentSummaryUsingAI()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(appState == nil)
        }

        CommandMenu("View") {
            Button(appState?.isPreviewPanelVisible == true ? "Hide Markdown Preview" : "Show Markdown Preview") {
                appState?.togglePreviewPanel()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(appState == nil)

            Divider()

            Button("Cycle Focus Mode") {
                appState?.cycleFocusMode()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(appState == nil)

            Button("Focus Current Sentence") {
                appState?.focusMode = .sentence
            }
            .keyboardShortcut("1", modifiers: [.command, .control])
            .disabled(appState == nil)

            Button("Focus Current Paragraph") {
                appState?.focusMode = .paragraph
            }
            .keyboardShortcut("2", modifiers: [.command, .control])
            .disabled(appState == nil)

            Button("Focus Off") {
                appState?.focusMode = .off
            }
            .keyboardShortcut("0", modifiers: [.command, .control])
            .disabled(appState == nil)
        }
    }
}

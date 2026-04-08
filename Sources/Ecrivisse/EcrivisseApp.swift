import SwiftUI
import AppKit
import Carbon

struct ExternalWindowRequest: Codable, Hashable {
    let path: String
    let token: UUID

    init(path: String, token: UUID = UUID()) {
        self.path = path
        self.token = token
    }
}

@main
struct EcrivisseApp: App {
    @NSApplicationDelegateAdaptor(EcrivisseAppDelegate.self) private var appDelegate
    private let minimumContentWidth: CGFloat = 620
    private let minimumContentHeight: CGFloat = 420

    var body: some Scene {
        WindowGroup(for: ExternalWindowRequest.self) { externalFileRequest in
            ContentView(initialExternalFilePath: externalFileRequest.wrappedValue?.path)
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
    private static let openDocumentsEventClass = AEEventClass(kCoreEventClass)
    private static let openDocumentsEventID = AEEventID(kAEOpenDocuments)

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocumentsEvent(_:withReplyEvent:)),
            forEventClass: Self.openDocumentsEventClass,
            andEventID: Self.openDocumentsEventID
        )
    }

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

    @objc
    private func handleOpenDocumentsEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor?) {
        guard let descriptorList = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        let itemCount = descriptorList.numberOfItems
        guard itemCount > 0 else { return }

        var urls: [URL] = []
        urls.reserveCapacity(itemCount)

        for index in 1...itemCount {
            guard let descriptor = descriptorList.atIndex(index) else { continue }
            if let fileURL = descriptor.fileURLValue {
                urls.append(fileURL)
                continue
            }
            if let path = descriptor.stringValue, !path.isEmpty {
                urls.append(URL(fileURLWithPath: path))
            }
        }

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
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])

        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isExcludedFromWindowsMenu }) ?? NSApp.windows.first {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            for sibling in NSApp.windows where sibling !== window {
                if sibling.isMiniaturized {
                    sibling.deminiaturize(nil)
                }
                sibling.orderFront(nil)
            }
            return
        }

        if retryCount == 0 {
            let createdWindow = NSApp.sendAction(NSSelectorFromString("newWindow:"), to: nil, from: nil)
            if createdWindow {
                NSApp.activate(ignoringOtherApps: true)
            }
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

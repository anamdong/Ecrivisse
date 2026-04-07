import Foundation

@MainActor
final class ExternalFileOpenRouter: ObservableObject {
    static let shared = ExternalFileOpenRouter()

    @Published private(set) var eventID: Int = 0
    private var pendingFileURLs: [URL] = []

    private init() {}

    func enqueue(urls: [URL]) {
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else { return }
        pendingFileURLs.append(contentsOf: fileURLs)
        eventID &+= 1
    }

    func drainPendingFileURLs() -> [URL] {
        let queued = pendingFileURLs
        pendingFileURLs.removeAll(keepingCapacity: true)
        return queued
    }
}

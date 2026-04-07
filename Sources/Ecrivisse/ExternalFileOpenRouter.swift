import Foundation

@MainActor
final class ExternalFileOpenRouter: ObservableObject {
    static let shared = ExternalFileOpenRouter()

    @Published private(set) var eventID: Int = 0
    private var pendingFileURLs: [URL] = []

    private init() {}

    func enqueue(urls: [URL]) {
        let validFileURLs = urls.compactMap { url -> URL? in
            guard url.isFileURL else { return nil }

            if let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
               isDirectory == true {
                return nil
            }

            return url
        }
        guard !validFileURLs.isEmpty else { return }
        pendingFileURLs.append(contentsOf: validFileURLs)
        eventID &+= 1
    }

    func drainPendingFileURLs() -> [URL] {
        let queued = pendingFileURLs
        pendingFileURLs.removeAll(keepingCapacity: true)
        return queued
    }
}

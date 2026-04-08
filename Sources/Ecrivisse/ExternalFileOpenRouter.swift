import Foundation

@MainActor
final class ExternalFileOpenRouter: ObservableObject {
    static let shared = ExternalFileOpenRouter()

    @Published private(set) var eventID: Int = 0
    private var pendingFileURLs: [URL] = []

    private init() {}

    var hasPendingFileURLs: Bool {
        !pendingFileURLs.isEmpty
    }

    func enqueue(urls: [URL]) {
        let validFileURLs = urls.compactMap { url -> URL? in
            guard url.isFileURL else { return nil }

            if let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
               isDirectory == true {
                return nil
            }

            return url.standardizedFileURL
        }

        guard !validFileURLs.isEmpty else { return }

        var known: Set<String> = Set(pendingFileURLs.map(\.path))
        var insertedAny = false
        for url in validFileURLs {
            let key = url.path
            guard !known.contains(key) else { continue }
            pendingFileURLs.append(url)
            known.insert(key)
            insertedAny = true
        }

        guard insertedAny else { return }
        eventID &+= 1
    }

    func drainPendingFileURLs() -> [URL] {
        let queued = pendingFileURLs
        pendingFileURLs.removeAll(keepingCapacity: true)
        return queued
    }
}

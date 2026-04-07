import Foundation

enum FocusMode: String, CaseIterable {
    case off
    case sentence
    case paragraph

    var title: String {
        switch self {
        case .off:
            return "Focus Off"
        case .sentence:
            return "Sentence Focus"
        case .paragraph:
            return "Paragraph Focus"
        }
    }

    func next() -> FocusMode {
        switch self {
        case .off:
            return .sentence
        case .sentence:
            return .paragraph
        case .paragraph:
            return .off
        }
    }
}

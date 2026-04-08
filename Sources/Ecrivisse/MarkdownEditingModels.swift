import Foundation

enum PreviewFontOption: String, CaseIterable, Identifiable {
    case systemSans
    case serif
    case rounded
    case mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemSans:
            return "Sans"
        case .serif:
            return "Serif"
        case .rounded:
            return "Rounded"
        case .mono:
            return "Mono"
        }
    }

    var cssFontStack: String {
        switch self {
        case .systemSans:
            return #"-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif"#
        case .serif:
            return #""New York", "Iowan Old Style", "Palatino Linotype", "Times New Roman", serif"#
        case .rounded:
            return #""SF Pro Rounded", "Avenir Next", "Nunito", -apple-system, sans-serif"#
        case .mono:
            return #"ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"#
        }
    }
}

enum MarkdownEditorAction {
    case heading(Int)
    case bold
    case italic
    case boldItalic
    case strikethrough
    case inlineCode
    case escapeCharacters
    case unorderedList
    case orderedList
    case link
    case codeBlock
    case blockquote
    case footnote
    case table(rows: Int, columns: Int)
}

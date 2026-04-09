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
            return #""Noto Sans CJK JP", "Noto Sans CJK KR", "Noto Sans CJK SC", "Noto Sans CJK TC", "Noto Sans JP", "Noto Sans KR", "Noto Sans SC", "Noto Sans TC", "Noto Sans Thai", "Noto Sans", -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif"#
        case .serif:
            return #""Noto Serif Korean", "Noto Serif KR", "Noto Serif CJK KR", "Noto Serif CJK JP", "Noto Serif CJK SC", "Noto Serif CJK TC", "Noto Serif JP", "Noto Serif SC", "Noto Serif TC", "Noto Serif", "New York", "Iowan Old Style", "Palatino Linotype", "Times New Roman", serif"#
        case .rounded:
            return #""Noto Sans CJK JP", "Noto Sans CJK KR", "Noto Sans CJK SC", "Noto Sans CJK TC", "Noto Sans Thai", "Noto Sans Thai Looped", "Noto Sans", "SF Pro Rounded", "Avenir Next", "Nunito", -apple-system, sans-serif"#
        case .mono:
            return #"ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"#
        }
    }
}

enum FloatingToolbarPosition: String, CaseIterable, Identifiable {
    case top
    case bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top:
            return "Top"
        case .bottom:
            return "Bottom"
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
    case checklist
    case link
    case codeBlock
    case blockquote
    case footnote
    case toc
    case table(rows: Int, columns: Int)
}

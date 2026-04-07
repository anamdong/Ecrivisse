import SwiftUI

struct MarkdownPreviewView: View {
    let markdown: String
    @State private var renderedText = AttributedString("")

    var body: some View {
        ScrollView {
            Text(renderedText)
                .textSelection(.enabled)
                .lineSpacing(8)
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.vertical, 72)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: markdown) {
            renderedText = await MarkdownRenderer.render(markdown: markdown)
        }
    }
}

enum MarkdownRenderer {
    static func render(markdown: String) async -> AttributedString {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let parsed: AttributedString
                do {
                    let options = AttributedString.MarkdownParsingOptions(
                        interpretedSyntax: .full,
                        failurePolicy: .returnPartiallyParsedIfPossible
                    )
                    parsed = try AttributedString(markdown: markdown, options: options)
                } catch {
                    parsed = AttributedString(markdown)
                }
                continuation.resume(returning: parsed)
            }
        }
    }
}

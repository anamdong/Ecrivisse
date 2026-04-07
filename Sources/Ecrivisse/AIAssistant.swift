import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AIAssistantError: LocalizedError {
    case emptyInput
    case unavailable
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "There is no text to summarize."
        case .unavailable:
            return "Apple Intelligence is unavailable on this Mac. Enable Apple Intelligence and try again."
        case .generationFailed(let message):
            return "AI generation failed: \(message)"
        }
    }
}

actor AIAssistant {
    static let shared = AIAssistant()

    private let instructions = """
    You are a concise writing assistant for markdown documents.
    Produce clear, faithful summaries without adding facts.
    Keep output plain markdown text only.
    """

    func summarizeSelection(_ text: String) async throws -> String {
        try await summarize(text, mode: .selection)
    }

    func summarizeDocument(_ text: String) async throws -> String {
        try await summarize(text, mode: .document)
    }

    private enum SummarizationMode {
        case selection
        case document
    }

    private func summarize(_ text: String, mode: SummarizationMode) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AIAssistantError.emptyInput
        }

#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: instructions)
            let modePrompt: String
            switch mode {
            case .selection:
                modePrompt = "Summarize this selected text in 1-3 sentences while preserving key meaning."
            case .document:
                modePrompt = "Summarize this document in 3-6 concise bullet points."
            }

            let prompt = """
            \(modePrompt)

            Text:
            ---
            \(trimmed)
            ---
            """

            do {
                let response = try await session.respond(to: prompt)
                let output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if output.isEmpty {
                    throw AIAssistantError.generationFailed("The model returned an empty response.")
                }
                return output
            } catch {
                throw AIAssistantError.generationFailed(error.localizedDescription)
            }
        }
#endif

        throw AIAssistantError.unavailable
    }
}

import Foundation

/// Turns a transcript window (and optionally a screen image, M5) into a streamed
/// answer from the local Ollama model. Callbacks fire on the main actor.
final class AnswerEngine {
    /// Default text model. Overridable from settings (M6).
    var model = "qwen2.5:7b"

    private let client = OllamaClient()
    private var task: Task<Void, Never>?

    private static let systemPrompt = """
    You are an expert assistant helping the user during a live interview, \
    meeting, or class. You are given a rolling transcript where "Them" is the \
    other party and "You" is the user. Answer the most recent question or request \
    from "Them" directly and accurately, at whatever length the question \
    deserves — short for simple facts, thorough for deep or technical questions. \
    If there is no clear question, give the most useful thing to say next.

    BEFORE answering any question — typed, clicked, or spoken — silently check \
    the screen content you were given ([Current screen text], [Recent \
    on-screen context], or an attached screenshot). If the question matches or \
    refers to a question visible on the screen (a quiz, exam, slide, or \
    interview question), answer THAT on-screen question: use its exact full \
    wording and its answer choices if shown, which take priority over the \
    transcript's paraphrase of it. Otherwise IGNORE the screen entirely and \
    answer from the transcript and your own knowledge — never invent on-screen \
    content, and never mention, describe, or list what is on the screen unless \
    the question is specifically about it. This check is internal: your answer \
    must never contain phrases like "based on the screen content".

    Output only the answer, no preamble. Write any mathematics in LaTeX: inline \
    math between $...$ and standalone equations between $$...$$ on their own line.
    """

    /// Generate an answer. `onToken` streams deltas; `onDone` reports completion.
    /// `focusQuestion` pins the model to one specific question instead of letting
    /// it pick something stale from the window. `screenContext` is text-only
    /// (summaries of recent screens); `imageBase64` is the single current
    /// screenshot.
    /// `history`: previous (question, answer) pairs, oldest first — replayed as
    /// chat turns so the model can resolve follow-ups like "explain that more".
    func generate(transcriptWindow: String,
                  focusQuestion: String? = nil,
                  clickedLine: Bool = false,
                  history: [(question: String?, answer: String)] = [],
                  screenContext: String? = nil,
                  imageBase64: String? = nil,
                  onToken: @escaping @MainActor (String) -> Void,
                  onDone: @escaping @MainActor (Error?) -> Void) {
        cancel()
        let model = self.model
        task = Task {
            var content = transcriptWindow
            if let screenContext, !screenContext.isEmpty {
                content += "\n\n[Recent on-screen context]\n" + screenContext
            }
            if let focusQuestion, !focusQuestion.isEmpty {
                if clickedLine {
                    content += """


                    The user clicked this transcript line: "\(focusQuestion)"
                    Answer the question it poses. Pay special attention to \
                    sentences ending in a question mark. The transcript lines \
                    above and below the clicked line may be part of the same \
                    question — read them and use them to complete it. If the \
                    clicked line itself is unclear or is not a question, search \
                    the surrounding lines for the question being asked and \
                    answer that instead. If there is truly no question anywhere, \
                    respond to the clicked line as helpfully as you can.
                    """
                } else {
                    content += "\n\nAnswer ONLY this question, just asked: \"\(focusQuestion)\""
                }
            }
            var user = OllamaClient.Message(role: "user", content: content)
            if let imageBase64 { user.images = [imageBase64] }
            var messages = [OllamaClient.Message(role: "system", content: Self.systemPrompt)]
            for turn in history {
                messages.append(OllamaClient.Message(
                    role: "user",
                    content: turn.question ?? "(answer the latest question in the transcript)"))
                messages.append(OllamaClient.Message(role: "assistant", content: turn.answer))
            }
            messages.append(user)
            do {
                for try await piece in client.chatStream(model: model, messages: messages) {
                    await onToken(piece)
                }
                await onDone(nil)
            } catch {
                await onDone(error)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

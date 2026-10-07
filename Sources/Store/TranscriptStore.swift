import Foundation
import Combine

/// Rolling, speaker-tagged transcript. Single source of truth for the UI,
/// the question detector (M4), and the answer engine (M3).
@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var utterances: [Utterance] = []
    /// In-progress (non-final) caption text per speaker — live captions.
    @Published private(set) var partials: [Speaker: String] = [:]

    /// How many utterances to keep in memory. Generous so a continued session's
    /// full transcript survives (autosave writes this list back to disk).
    private let maxUtterances = 500

    /// Append a finalized utterance and clear that speaker's live partial.
    func append(_ utterance: Utterance) {
        utterances.append(utterance)
        partials[utterance.speaker] = nil
        if utterances.count > maxUtterances {
            utterances.removeFirst(utterances.count - maxUtterances)
        }
    }

    /// Update the live (non-final) caption for a speaker.
    func setPartial(_ text: String, for speaker: Speaker) {
        if text.isEmpty { partials[speaker] = nil }
        else { partials[speaker] = text }
    }

    /// Most recent utterance overall.
    var latest: Utterance? { utterances.last }

    /// Most recent utterance from a given speaker.
    func latest(from speaker: Speaker) -> Utterance? {
        utterances.last { $0.speaker == speaker }
    }

    /// Plain-text window of the last `count` utterances for prompting,
    /// with any live partials appended so the model sees the newest words.
    func window(_ count: Int = 12, includePartials: Bool = true) -> String {
        var lines = utterances.suffix(count).map { "\($0.speaker.label): \($0.text)" }
        if includePartials {
            for (speaker, text) in partials where !text.isEmpty {
                lines.append("\(speaker.label): \(text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The `prior` utterances before (and including) the one with `id` —
    /// context for answering that specific question. Falls back to the overall
    /// tail when id is nil or unknown.
    func window(endingAt id: UUID?, prior: Int) -> String {
        var list = utterances
        if let id, let idx = list.firstIndex(where: { $0.id == id }) {
            list = Array(list[...idx])
        }
        return list.suffix(prior + 1)
            .map { "\($0.speaker.label): \($0.text)" }
            .joined(separator: "\n")
    }

    /// Context around one utterance — `before` lines above it, the line itself,
    /// and `after` lines below (when they exist). Used by click-to-ask on a
    /// transcript row.
    func window(around id: UUID, before: Int, after: Int) -> String {
        guard let idx = utterances.firstIndex(where: { $0.id == id }) else { return "" }
        let lo = max(0, idx - before)
        let hi = min(utterances.count - 1, idx + after)
        return utterances[lo...hi]
            .map { "\($0.speaker.label): \($0.text)" }
            .joined(separator: "\n")
    }

    /// Replace the transcript with a saved session's utterances.
    func load(_ list: [Utterance]) {
        utterances = Array(list.suffix(maxUtterances))
        partials.removeAll()
    }

    func clear() {
        utterances.removeAll()
        partials.removeAll()
    }
}

import Foundation
import Combine

/// One AI answer, tagged with the question it replied to.
struct AnswerRecord: Identifiable, Codable, Hashable {
    var id = UUID()
    var question: String?
    var text: String
    var createdAt = Date()
}

/// A recorded conversation: the transcript from start to end plus the AI's
/// answer history. `answers` is optional so sessions saved before it existed
/// still decode.
struct Session: Identifiable, Codable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var updatedAt = Date()
    var utterances: [Utterance]
    var answers: [AnswerRecord]?
}

/// Persists sessions as JSON files in Application Support and keeps the list
/// (newest first) for the UI. The "current" session is the one autosave writes
/// into; nil means a fresh session is created on the next utterance.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var currentID: UUID?

    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Overhear/sessions", isDirectory: true)
    }()

    init() {
        try? FileManager.default.createDirectory(at: Self.dir,
                                                 withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.dir, includingPropertiesForKeys: nil)) ?? []
        sessions = files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Session.self,
                                                    from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Write the live transcript + answer history into the current session,
    /// creating one on the first utterance. Called after every finalized
    /// utterance and every completed answer.
    func autosave(_ utterances: [Utterance], answers: [AnswerRecord] = []) {
        guard !utterances.isEmpty || !answers.isEmpty else { return }
        if let idx = sessions.firstIndex(where: { $0.id == currentID }) {
            sessions[idx].utterances = utterances
            sessions[idx].answers = answers
            sessions[idx].updatedAt = Date()
            write(sessions[idx])
        } else {
            let s = Session(title: Self.title(from: utterances),
                            utterances: utterances, answers: answers)
            currentID = s.id
            sessions.insert(s, at: 0)
            write(s)
        }
    }

    /// Next utterance starts a brand-new session.
    func startNew() { currentID = nil }

    /// Continue an existing session: future utterances append to it.
    func open(_ session: Session) { currentID = session.id }

    func delete(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
        if currentID == session.id { currentID = nil }
        try? FileManager.default.removeItem(
            at: Self.dir.appendingPathComponent("\(session.id).json"))
    }

    private func write(_ s: Session) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: Self.dir.appendingPathComponent("\(s.id).json"),
                        options: .atomic)
    }

    private static func title(from utterances: [Utterance]) -> String {
        let first = utterances.first?.text.trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty
            ? Date().formatted(date: .abbreviated, time: .shortened)
            : String(first.prefix(40))
    }
}

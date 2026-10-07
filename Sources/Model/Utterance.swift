import Foundation

/// Who spoke a given utterance. In M1 only `.me` (mic) exists;
/// `.them` (system audio) arrives in M2.
enum Speaker: String, Codable, Hashable {
    case me
    case them

    var label: String {
        switch self {
        case .me: return "You"
        case .them: return "Them"
        }
    }
}

/// A single transcribed chunk of speech. Codable so sessions persist to disk.
struct Utterance: Identifiable, Hashable, Codable {
    var id = UUID()
    let speaker: Speaker
    var text: String
    let start: Date
    var end: Date
    /// False while the ASR is still refining; true once the segment is closed.
    var isFinal: Bool
}

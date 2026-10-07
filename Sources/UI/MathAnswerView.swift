import SwiftUI
import SwiftMath

/// Renders an LLM answer with LaTeX math (via SwiftMath, fully offline):
/// `$$…$$` becomes a display equation, paragraphs containing `$…$` are rendered
/// as math lines with the prose wrapped in `\text{}`, and plain paragraphs stay
/// native (wrapping, selectable) Text. Robust while streaming: unclosed
/// delimiters are treated as plain text until they close.
struct MathAnswerView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(from: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .plain(let s):
                    Text(Self.markdown(s)).font(.system(size: 15))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .math(let latex, let display):
                    ScrollView(.horizontal, showsIndicators: false) {
                        MathLabel(latex: latex,
                                  mode: display ? .display : .text,
                                  fontSize: display ? 18 : 16)
                            .fixedSize()
                            .padding(.vertical, display ? 4 : 0)
                    }
                }
            }
        }
    }

    /// Inline markdown (**bold**, *italic*, `code`) — models emit it constantly.
    /// Inline-only so streaming chunks render safely; on parse failure the raw
    /// string shows as-is.
    private static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    // MARK: - Parsing

    enum Block {
        case plain(String)
        case math(latex: String, display: Bool)
    }

    static func blocks(from text: String) -> [Block] {
        var out: [Block] = []
        let parts = text.components(separatedBy: "$$")
        for (i, part) in parts.enumerated() {
            // Odd indices sit inside a $$ pair — but only if that pair closed.
            if i % 2 == 1, i < parts.count - 1 {
                let latex = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !latex.isEmpty, isValidLatex(latex) {
                    out.append(.math(latex: latex, display: true))
                } else if !latex.isEmpty {
                    out.append(.plain(latex))
                }
            } else {
                out.append(contentsOf: proseBlocks(part))
            }
        }
        return out
    }

    /// Prose: paragraphs with closed `$…$` become one math line (`\text{}`
    /// around the words); everything else stays plain Text.
    private static func proseBlocks(_ s: String) -> [Block] {
        var out: [Block] = []
        for rawLine in s.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let segs = line.components(separatedBy: "$")
            guard segs.count >= 3 else { out.append(.plain(line)); continue }

            var latex = ""
            for (i, seg) in segs.enumerated() {
                let insideClosedPair = i % 2 == 1 && i < segs.count - 1
                if insideClosedPair {
                    latex += seg
                } else if !seg.isEmpty {
                    let prefix = (i % 2 == 1) ? "$" : ""   // unclosed $ while streaming
                    latex += "\\text{\(escapeText(prefix + seg))}"
                }
            }
            if isValidLatex(latex) {
                out.append(.math(latex: latex, display: false))
            } else {
                out.append(.plain(line))
            }
        }
        return out
    }

    private static func escapeText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\", with: "")
        for (raw, escaped) in [("{", "\\{"), ("}", "\\}"), ("$", "\\$"),
                               ("%", "\\%"), ("#", "\\#"), ("&", "\\&"),
                               ("_", "\\_")] {
            t = t.replacingOccurrences(of: raw, with: escaped)
        }
        return t
    }

    /// Reject latex SwiftMath can't parse so we fall back to plain text instead
    /// of showing an error glyph.
    private static func isValidLatex(_ latex: String) -> Bool {
        var error: NSError?
        let list = MTMathListBuilder.build(fromString: latex, error: &error)
        return list != nil && error == nil
    }
}

/// SwiftMath's label wrapped for SwiftUI.
private struct MathLabel: NSViewRepresentable {
    let latex: String
    let mode: MTMathUILabelMode
    let fontSize: CGFloat

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.fontSize = fontSize
        label.textColor = .labelColor
        label.labelMode = mode
        label.textAlignment = .left
        label.latex = latex
        return label
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        label.labelMode = mode
        label.fontSize = fontSize
        label.latex = latex
        label.invalidateIntrinsicContentSize()
    }
}

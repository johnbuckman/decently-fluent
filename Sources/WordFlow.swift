import SwiftUI

/// One whitespace-separated piece of a paragraph, e.g. «Bonjour,» with core "Bonjour".
struct WordToken: Identifiable, Hashable {
    let id: Int
    let text: String
    let core: String
    let sentence: String

    static func tokens(_ text: String) -> [WordToken] {
        var out: [WordToken] = []
        // sentence of each token, for looking a word up in context
        var sentences: [(Range<String.Index>, String)] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, r, _, _ in
            if let s { sentences.append((r, s.trimmingCharacters(in: .whitespaces))) }
        }
        var i = 0
        var search = text.startIndex
        for piece in text.split(whereSeparator: \.isWhitespace) {
            let chunk = String(piece)
            let at = text.range(of: chunk, range: search..<text.endIndex)?.lowerBound ?? search
            search = text.index(at, offsetBy: chunk.count, limitedBy: text.endIndex) ?? text.endIndex
            let sentence = sentences.first { $0.0.contains(at) }?.1 ?? text
            let core = chunk.trimmingCharacters(in: CharacterSet.letters.union(.decimalDigits).inverted)
            out.append(WordToken(id: i, text: chunk, core: core, sentence: sentence))
            i += 1
        }
        return out
    }

    /// "l'homme" → "homme", "d’accord" → "accord"
    var afterElision: String? {
        guard let r = core.firstIndex(where: { $0 == "'" || $0 == "’" }) else { return nil }
        let rest = core[core.index(after: r)...]
        return rest.isEmpty ? nil : String(rest)
    }
}

/// The target-language paragraph as tappable words, wrapped like text.
struct WordFlowText: View {
    let rendition: Rendition
    let language: Language
    let showNewWords: Bool
    let learningLemmas: Set<String>
    let onTap: (WordToken, Gloss?) -> Void
    let onDoubleTap: (WordToken, Gloss?) -> Void
    /// The words to show, when a page holds only part of the paragraph.
    var words: Range<Int>? = nil

    var body: some View {
        let tokens = WordToken.tokens(rendition.text)
        let matches = Self.match(tokens, rendition.glossary)
        let shown = words.map { r in tokens.filter { r.contains($0.id) } } ?? tokens
        FlowLayout(spacing: 5, lineSpacing: showNewWords ? 10 : 6) {
            ForEach(shown) { t in
                let m = matches[t.id]
                let gloss = m?.gloss
                let lemma = gloss?.lemma.lowercased() ?? Lemmatizer.cachedLemma(t.core, language: language)
                let learning = learningLemmas.contains(lemma)
                let highlighted = showNewWords && (gloss?.isNew == true || learning)
                // a phrase's meaning goes under its first word only
                WordView(token: t, highlighted: highlighted, learning: learning,
                         meaning: highlighted && m?.first != false ? (gloss?.meaning ?? "") : nil)
                    .onTapGesture(count: 2) { onDoubleTap(t, gloss) }
                    .onTapGesture { onTap(t, gloss) }
            }
        }
    }

    /// Which glossary entry each token belongs to. Multi-word entries ("se plaignait",
    /// "tout à coup") only match where all their words appear in a row.
    static func match(_ tokens: [WordToken], _ glossary: [Gloss]) -> [Int: (gloss: Gloss, first: Bool)] {
        func norm(_ s: Substring) -> String {
            s.trimmingCharacters(in: CharacterSet.letters.union(.decimalDigits).inverted).lowercased()
        }
        var out: [Int: (Gloss, Bool)] = [:]
        let entries = glossary.map { g in (g, g.surface.split(separator: " ").map(norm).filter { !$0.isEmpty }) }
            .filter { !$0.1.isEmpty }
            .sorted { $0.1.count > $1.1.count }
        for (g, words) in entries {
            for start in tokens.indices where start + words.count <= tokens.count {
                let fits = words.indices.allSatisfy { k in
                    let t = tokens[start + k]
                    return t.core.lowercased() == words[k] || t.afterElision?.lowercased() == words[k]
                }
                guard fits, (start..<start + words.count).allSatisfy({ out[$0] == nil }) else { continue }
                // the label goes under the phrase's longest word ("plaignait", not "se")
                let main = words.indices.max { words[$0].count < words[$1].count } ?? 0
                for k in words.indices { out[start + k] = (g, k == main) }
            }
        }
        return out
    }
}

struct WordView: View {
    let token: WordToken
    let highlighted: Bool
    let learning: Bool
    let meaning: String?

    static let labelFont = UIFont.systemFont(ofSize: 11)

    /// Wide enough for the label's longest word, so it wraps between words, never inside one.
    private var labelMinWidth: CGFloat {
        guard let meaning else { return 0 }
        let widest = meaning.split(separator: " ").map {
            ceil((String($0) as NSString).size(withAttributes: [.font: Self.labelFont]).width)
        }.max() ?? 0
        return widest + 1
    }

    var body: some View {
        UnderLabel(minLabelWidth: labelMinWidth) {
            Text(token.text)
                .font(.system(size: 20, design: .serif))
                .padding(.horizontal, highlighted ? 2 : 0)
                .background(highlighted ? Color.yellow.opacity(0.45) : .clear, in: RoundedRectangle(cornerRadius: 3))
                .overlay(alignment: .bottom) {
                    if learning && !highlighted {
                        Rectangle().fill(Color.orange.opacity(0.7)).frame(height: 1.5).offset(y: 1)
                    }
                }
            if let meaning, !meaning.isEmpty {
                Text(meaning)
                    .font(Font(Self.labelFont))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A word with an optional label under it that wraps to the word's width
/// (or the label's longest word, if wider), so labels don't push words apart.
struct UnderLabel: Layout {
    var minLabelWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let word = subviews[0].sizeThatFits(.unspecified)
        guard subviews.count > 1 else { return word }
        let width = max(word.width, minLabelWidth)
        let label = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: max(word.width, min(width, label.width)), height: word.height + label.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let word = subviews[0].sizeThatFits(.unspecified)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(word))
        guard subviews.count > 1 else { return }
        let width = max(word.width, minLabelWidth)
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + word.height),
                          proposal: ProposedViewSize(width: width, height: nil))
    }
}

/// Lays children out left to right, wrapping onto new lines, aligned on their first baseline row.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width += (r.indices.isEmpty ? 0 : spacing) + size.width
            r.height = max(r.height, size.height)
            r.indices.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}

struct GlossCardView: View {
    let card: WordCard
    let onKnown: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.word).font(.system(.title3, design: .serif).weight(.semibold))
                    if card.lemma.lowercased() != card.word.lowercased() {
                        Text(card.lemma).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let en = card.meaning {
                    Text(en).font(.body)
                } else {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Looking it up…").foregroundStyle(.secondary) }
                }
                if card.isLearning {
                    Text("Added to your words — you'll meet it again soon.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .foregroundStyle(.secondary)
                if card.isLearning {
                    Button("I know it", action: onKnown).font(.caption).buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

extension Lemmatizer {
    private static var cache: [String: String] = [:]

    /// Lemmas for single words are looked up often while drawing, so keep them.
    static func cachedLemma(_ word: String, language: Language) -> String {
        let key = "\(language.rawValue):\(word)"
        if let l = cache[key] { return l }
        let l = lemma(word, language: language)
        cache[key] = l
        return l
    }
}

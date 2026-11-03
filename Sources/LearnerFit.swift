import Foundation

/// How easy a book is likely to be for someone reading it in a language they're
/// still learning, judged from its own text before anything is translated.
struct LearnerFit {
    enum Verdict: String { case great = "Great for learners", good = "Good for learners", hard = "Challenging" }

    var words = 0
    var chapters = 0
    var wordsPerChapter = 0
    var wordsPerSentence = 0.0
    /// Share of paragraphs with dialogue in them.
    var dialogue = 0.0
    /// Old-fashioned words (thee, hath, 'tis…) per 10,000 words.
    var archaic = 0.0
    /// Dialect spellings (ain't, 'em, warn't…) per 10,000 words.
    var dialect = 0.0

    static let archaicWords: Set<String> = ["thee", "thou", "thy", "thine", "hath", "doth", "'tis", "’tis", "ere", "whilst",
                                            "shalt", "wilt", "hast", "dost", "nay", "aye", "betwixt", "wherefore", "methinks"]
    static let dialectWords: Set<String> = ["ain't", "ain’t", "'em", "’em", "warn't", "warn’t", "gwine", "dat", "dem", "dey",
                                            "nothin'", "nothin’", "somethin'", "yer", "ye", "o'", "fur", "jes'", "'bout", "’bout"]

    init(_ book: ImportedBook) {
        var sentences = 0, archaicCount = 0, dialectCount = 0, dialogueParas = 0, paras = 0
        for ch in book.chapters {
            for p in ch.paragraphs {
                paras += 1
                let tokens = p.lowercased().split(whereSeparator: { $0.isWhitespace })
                words += tokens.count
                sentences += max(1, p.filter { ".!?".contains($0) }.count)
                for t in tokens {
                    let w = t.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"“”()—"))
                    if Self.archaicWords.contains(w) { archaicCount += 1 }
                    if Self.dialectWords.contains(w) { dialectCount += 1 }
                }
                if p.contains("“") || p.contains("\"") { dialogueParas += 1 }
            }
        }
        chapters = book.chapters.count
        wordsPerChapter = chapters > 0 ? words / chapters : 0
        wordsPerSentence = sentences > 0 ? Double(words) / Double(sentences) : 0
        dialogue = paras > 0 ? Double(dialogueParas) / Double(paras) : 0
        archaic = words > 0 ? Double(archaicCount) * 10_000 / Double(words) : 0
        dialect = words > 0 ? Double(dialectCount) * 10_000 / Double(words) : 0
    }

    var length: String {
        switch words {
        case ..<15_000: "Short"
        case ..<50_000: "Medium length"
        case ..<120_000: "Long"
        default: "Very long"
        }
    }

    /// Plain-language notes, good points first.
    var notes: [(good: Bool, text: String)] {
        var n: [(Bool, String)] = []
        if words < 50_000 { n.append((true, "\(length): about \(words.formatted()) words")) } else { n.append((false, "\(length): about \(words.formatted()) words")) }
        if wordsPerChapter < 3_000 { n.append((true, "Short chapters (about \(wordsPerChapter.formatted()) words)")) }
        else if wordsPerChapter > 8_000 { n.append((false, "Long chapters (about \(wordsPerChapter.formatted()) words)")) }
        if dialogue >= 0.3 { n.append((true, "Lots of dialogue (\(Int(dialogue * 100))% of paragraphs)")) }
        else if dialogue < 0.1 { n.append((false, "Little dialogue")) }
        if wordsPerSentence < 16 { n.append((true, "Short sentences")) } else if wordsPerSentence > 25 { n.append((false, "Long, winding sentences")) }
        if archaic > 15 { n.append((false, "Old-fashioned English (thee, hath…)")) }
        if dialect > 20 { n.append((false, "Written in dialect, which translates poorly")) }
        return n.sorted { $0.0 && !$1.0 }
    }

    var verdict: Verdict {
        var score = 0
        score += words < 25_000 ? 2 : words < 60_000 ? 1 : words > 150_000 ? -1 : 0
        score += wordsPerChapter < 3_000 ? 1 : 0
        score += dialogue >= 0.3 ? 1 : 0
        score += wordsPerSentence < 16 ? 1 : wordsPerSentence > 25 ? -1 : 0
        score -= archaic > 15 ? 2 : 0
        score -= dialect > 20 ? 2 : 0
        return score >= 4 ? .great : score >= 2 ? .good : .hard
    }
}

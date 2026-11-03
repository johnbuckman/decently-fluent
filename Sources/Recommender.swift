import Foundation
import SwiftUI

/// What the reader told the book guide.
struct ReadingProfile {
    /// The language being learned.
    var language: Language
    /// The reader's own language.
    var native: Language
    /// Books written in the language, rather than books retold in it.
    var originals: Bool
    var level: Level
    var interests: Set<Category>
    var minutesPerDay: Int

    /// A cautious estimate of comfortable reading speed for easy, graded text, in words a minute.
    var wordsPerMinute: Int {
        switch level {
        case .a1: 80
        case .a2: 100
        case .b1: 120
        case .b2: 150
        case .c1: 180
        case .native: 200
        }
    }

    /// The vocabulary measure that matters at this level: the 2,000 most common words up to B1, 5,000 above.
    var usesCoverage5k: Bool { [.b2, .c1, .native].contains(level) }

    /// Where the books come from: the language itself for originals; otherwise books in the reader's
    /// own language, and English books (the biggest collection) unless English is being learned.
    var sourceLanguages: [Language] {
        if originals { return [language] }
        return native == .english || language == .english ? [native] : [native, .english]
    }
    var retoldDescription: String { sourceLanguages.map(\.name).joined(separator: " or ") }
}

struct Reason: Identifiable {
    var id = UUID()
    var good: Bool
    var text: String
    var principle: Principle.Key?
}

struct Recommendation: Identifiable {
    var book: CatalogBook
    var score: Int
    var days: Int?
    var reasons: [Reason]
    var id: Int { book.id }

    var verdict: String {
        switch score {
        case 75...: "Excellent match"
        case 60..<75: "Good match"
        case 45..<60: "Possible match"
        default: "Harder going"
        }
    }
}

enum Recommender {
    static func recommend(_ p: ReadingProfile, limit: Int = 30) -> [Recommendation] {
        var out: [Recommendation] = []
        for source in p.sourceLanguages {
            let lang = source.rawValue
            var books = Catalog.shared.measured(language: lang, categories: p.interests, originalsOnly: p.originals)
            // a translation of a book first written in the language being learned belongs with the originals
            if !p.originals { books.removeAll { Catalog.shared.bestEditions(of: $0.id)[p.language]?.translated == false } }
            let all = Catalog.shared.measured(language: lang, originalsOnly: p.originals)
            // vocabulary and popularity are judged against every measured book in the same language
            let coverages = all.compactMap { p.usesCoverage5k ? $0.coverage5k : $0.coverage2k }.sorted()
            let popularity = all.map(\.popularity).sorted()
            var byAuthor: [String: Int] = [:]
            for b in all where !b.author.isEmpty { byAuthor[b.author, default: 0] += 1 }
            out += books.map { score($0, p, coverages: coverages, popularity: popularity, authorBooks: byAuthor[$0.author] ?? 1) }
        }
        return out.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    static func percentile(_ v: Double, in sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0.5 }
        let below = sorted.firstIndex { $0 >= v } ?? sorted.count
        return Double(below) / Double(sorted.count)
    }

    static func score(_ b: CatalogBook, _ p: ReadingProfile, coverages: [Double], popularity: [Int], authorBooks: Int) -> Recommendation {
        var reasons: [Reason] = []
        var total = 0.0

        // vocabulary (Hu & Nation 2000; Nation 2006)
        if let cov = p.usesCoverage5k ? b.coverage5k : b.coverage2k {
            let pct = percentile(cov, in: coverages)
            let band = p.usesCoverage5k ? "5,000" : "2,000"
            total += 0.30 * pct
            if pct >= 0.6 {
                reasons.append(Reason(good: true, text: "Everyday vocabulary: \(Int(cov * 100))% of its words are among the \(band) most common — easier than \(Int(pct * 100))% of books here", principle: .frequency))
            } else if pct < 0.3 {
                reasons.append(Reason(good: false, text: "Richer vocabulary: \(Int(cov * 100))% of its words are among the \(band) most common — harder than most books here, so more is simplified", principle: .frequency))
            }
        }

        // length: finish in a week or two (Nation & Waring 2020)
        var days: Int?
        if let words = b.words {
            let d = max(1, Int((Double(words) / Double(p.wordsPerMinute * p.minutesPerDay)).rounded(.up)))
            days = d
            total += 0.20 * (d <= 7 ? 1 : d <= 14 ? 0.8 : d <= 30 ? 0.4 : d <= 60 ? 0.15 : 0)
            let when = "about \(d) day\(d == 1 ? "" : "s") at \(p.minutesPerDay) minutes a day"
            if d <= 14 { reasons.append(Reason(good: true, text: "You could finish it in \(when)", principle: .quantity)) }
            else if d > 30 { reasons.append(Reason(good: false, text: "A long read: \(when)", principle: .quantity)) }
        }

        // a chapter per sitting
        if let wpc = b.wordsPerChapter, b.chapters ?? 0 > 1 {
            let minutes = max(1, wpc / p.wordsPerMinute)
            total += 0.10 * (minutes <= p.minutesPerDay ? 1 : minutes <= p.minutesPerDay * 2 ? 0.5 : 0)
            if minutes <= p.minutesPerDay { reasons.append(Reason(good: true, text: "A chapter fits in one sitting (about \(minutes) minutes)", principle: .quantity)) }
        }

        // dialogue and sentence length: the plainest kind of text
        if let d = b.dialogue {
            total += 0.15 * min(1, max(0, (d - 0.1) / 0.3))
            if d >= 0.35 { reasons.append(Reason(good: true, text: "Lots of dialogue (\(Int(d * 100))% of paragraphs): short, everyday spoken language", principle: nil)) }
            else if d < 0.1 { reasons.append(Reason(good: false, text: "Little dialogue: mostly narration and description", principle: nil)) }
        }
        if let s = b.sentenceLength {
            total += 0.10 * min(1, max(0, (26 - s) / 12))
            if s <= 15 { reasons.append(Reason(good: true, text: "Short sentences (about \(Int(s)) words)", principle: nil)) }
            else if s >= 26 { reasons.append(Reason(good: false, text: "Long sentences (about \(Int(s)) words)", principle: nil)) }
        }

        // a story many people know is easier to follow
        let pop = percentile(Double(b.popularity), in: popularity.map(Double.init))
        total += 0.15 * pop
        if pop >= 0.85 { reasons.append(Reason(good: true, text: "Among the most read books in the collection — you may already know the story, which makes it easier to follow", principle: .choice)) }

        if authorBooks >= 3 {
            reasons.append(Reason(good: true, text: "\(authorBooks) books by \(b.author) here: read on with the same style and vocabulary", principle: .narrow))
        }

        // published human translations (Toral & Way 2018)
        let editions = Catalog.shared.bestEditions(of: b.id)
        if b.lang != p.language, let e = editions[p.language] {
            total += 0.10
            reasons.append(Reason(good: true, text: e.translated
                ? "Has a published \(p.language.name) translation\(e.translator.isEmpty ? "" : " by \(e.translator)"): it is the Native level, and simpler levels start from it"
                : "First written in \(p.language.name): the Native level is the author's own text, and simpler levels start from it",
                principle: .humanTranslation))
        }
        if b.lang != p.native, let e = editions[p.native] {
            total += 0.05
            reasons.append(Reason(good: true, text: "The \(p.native.name) column uses \(e.translated ? "a published translation\(e.translator.isEmpty ? "" : " by \(e.translator)")" : "the author's original"), not a machine translation",
                                  principle: .humanTranslation))
        }

        // English that translates badly
        if (b.archaic ?? 0) > 15 { total -= 0.2; reasons.append(Reason(good: false, text: "Old-fashioned English (thee, hath…)", principle: nil)) }
        if (b.dialect ?? 0) > 20 { total -= 0.25; reasons.append(Reason(good: false, text: "Written in dialect, which is hard to retell faithfully", principle: nil)) }

        let ordered = reasons.filter(\.good) + reasons.filter { !$0.good }
        return Recommendation(book: b, score: Int(max(0, min(1, total)) * 100), days: days, reasons: ordered)
    }
}

/// The guide's answers, kept between launches.
struct StoredProfile: DynamicProperty {
    @AppStorage("guide.language") var language = Language.french.rawValue
    @AppStorage("nativeLanguage") var native = Language.english.rawValue
    @AppStorage("guide.originals") var originals = false
    @AppStorage("guide.level") var level = Level.b1.rawValue
    @AppStorage("guide.interests") var interests = ""
    @AppStorage("guide.minutes") var minutes = 20
    @AppStorage("guide.done") var done = false

    var profile: ReadingProfile {
        let mine = Language(rawValue: native) ?? .english
        var learning = Language(rawValue: language) ?? .french
        if learning == mine { learning = mine == .english ? .french : .english }
        return ReadingProfile(language: learning, native: mine, originals: originals,
                       level: Level(rawValue: level) ?? .b1,
                       interests: Set(interests.split(separator: ",").compactMap { Category(rawValue: String($0)) }),
                       minutesPerDay: minutes)
    }
}

import Foundation
import SwiftData
import NaturalLanguage

/// CEFR graded-reader levels, plus the fluent translation ("Native").
enum Level: String, Codable, CaseIterable, Identifiable {
    case a1 = "A1", a2 = "A2", b1 = "B1", b2 = "B2", c1 = "C1", native = "Native"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .a1: "A1 · Beginner"
        case .a2: "A2 · Elementary"
        case .b1: "B1 · Intermediate"
        case .b2: "B2 · Upper intermediate"
        case .c1: "C1 · Advanced"
        case .native: "Native · Fluent translation"
        }
    }

    func label(original: Bool) -> String { self == .native && original ? "Native · The original text" : label }

    /// The writing rules graded-reader series follow at each level, for the generation prompt.
    func rules(for lang: Language) -> String {
        let g = lang.grammar
        switch self {
        case .a1:
            return """
            About 300–500 headwords: only the most frequent everyday words. \
            Tenses: \(g.a1). \
            Very short, simple sentences (average 8 words or fewer), one idea per sentence. \
            Connectors only \(g.a1Connectors). No subordinate clauses beyond these. \
            Concrete vocabulary; say "he was very sad" rather than using a rare synonym. Repeat key words instead of varying them.
            """
        case .a2:
            return """
            About 1,000 headwords. \
            Tenses: \(g.a2). \
            Short sentences (average 12 words or fewer). \
            Simple connectors: \(g.a2Connectors). \
            Prefer common words; keep dialogue simple and direct.
            """
        case .b1:
            return """
            About 2,000 headwords. \
            Grammar allowed: \(g.b1). \
            Sentences up to about 18 words. Avoid idioms and literary vocabulary; explain rather than allude.
            """
        case .b2:
            return """
            About 4,000 headwords. \
            Grammar allowed: \(g.b2). \
            Natural, flowing prose, but replace rare, archaic or highly literary words and very long sentences.
            """
        case .c1:
            return """
            Near-native prose that keeps the author's tone and nuance. \
            Only simplify rare, archaic or regional words and split extremely long sentences.
            """
        case .native:
            return """
            A faithful, natural, literary translation as a professional translator would publish it. No simplification.
            """
        }
    }

    /// How many unknown words a reader at this level should meet per 100 words.
    var newWordsPer100: String {
        switch self {
        case .a1, .a2: "at most 2"
        case .b1: "at most 3"
        case .b2: "at most 4"
        case .c1, .native: "as the original requires"
        }
    }
}

/// The languages the app reads and writes: the reader's own, and the one they are learning.
enum Language: String, Codable, CaseIterable, Identifiable {
    case english = "en", french = "fr", german = "de", spanish = "es", italian = "it"
    var id: String { rawValue }
    var name: String {
        switch self {
        case .english: "English"
        case .french: "French"
        case .german: "German"
        case .spanish: "Spanish"
        case .italian: "Italian"
        }
    }
    var nl: NLLanguage {
        switch self {
        case .english: .english
        case .french: .french
        case .german: .german
        case .spanish: .spanish
        case .italian: .italian
        }
    }
    /// The reader's own language, chosen in the book guide; English until they choose.
    static var mine: Language {
        get { Language(rawValue: UserDefaults.standard.string(forKey: "nativeLanguage") ?? "") ?? .english }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "nativeLanguage") }
    }
    /// Graded-reader series in this language, named in the prompt as the model to follow.
    var readerSeries: String {
        switch self {
        case .english: "Oxford Bookworms, Cambridge English Readers, Penguin Readers"
        case .french: "CLE Lectures en français facile, Hachette Lire en français facile"
        case .german: "Hueber Lektüren, Langenscheidt Leichte Lektüren"
        case .spanish: "Edelsa Lecturas graduadas, SGEL Lecturas de español"
        case .italian: "ELI Letture graduate, Alma Edizioni Italiano facile"
        }
    }

    /// The grammar each level allows, as graded-reader series in this language use it.
    struct Grammar { var a1, a1Connectors, a2, a2Connectors, b1, b2: String }
    var grammar: Grammar {
        switch self {
        case .english: Grammar(
            a1: "present simple and continuous, plus going to for the future",
            a1Connectors: "and, but, because, then",
            a2: "past simple, present perfect of common verbs, will, can/must",
            a2Connectors: "when, because, but, then, if",
            b1: "past continuous, present perfect, first and second conditionals, relative clauses with who/which/that, common phrasal verbs",
            b2: "past perfect, passive voice, third conditional, reported speech, modal perfects (should have, might have)")
        case .french: Grammar(
            a1: "présent, plus futur proche (aller + infinitif)",
            a1Connectors: "et, mais, parce que, alors",
            a2: "présent, passé composé, futur proche, simple imparfait of être/avoir",
            a2Connectors: "quand, parce que, mais, puis, si",
            b1: "imparfait, futur simple, conditionnel présent, pronoms relatifs qui/que/où, pronoms y/en",
            b2: "subjonctif présent, plus-que-parfait, voix passive, gérondif")
        case .german: Grammar(
            a1: "Präsens, plus Perfekt of very common verbs (sein, haben, gehen, machen)",
            a1Connectors: "und, aber, denn, dann",
            a2: "Präsens, Perfekt, Präteritum of sein/haben/modal verbs",
            a2Connectors: "weil, dass, wenn, aber, dann",
            b1: "Präteritum, Nebensätze with weil/dass/wenn/als/ob, Konjunktiv II with würde, Relativsätze, trennbare Verben",
            b2: "Passiv, full Konjunktiv II, Plusquamperfekt, erweiterte Partizipien used sparingly")
        case .spanish: Grammar(
            a1: "presente de indicativo, plus ir a + infinitivo",
            a1Connectors: "y, pero, porque, entonces",
            a2: "pretérito perfecto, pretérito indefinido of common verbs, imperfecto of ser/estar/tener",
            a2Connectors: "cuando, porque, pero, después, si",
            b1: "indefinido and imperfecto contrasted, futuro simple, condicional, pronombres relativos que/donde, object pronouns",
            b2: "presente and imperfecto de subjuntivo, pluscuamperfecto, voz pasiva, gerundio")
        case .italian: Grammar(
            a1: "presente indicativo, plus stare + gerundio",
            a1Connectors: "e, ma, perché, poi",
            a2: "passato prossimo, imperfetto of essere/avere, futuro semplice of common verbs",
            a2Connectors: "quando, perché, ma, poi, se",
            b1: "imperfetto and passato prossimo contrasted, futuro, condizionale presente, pronomi relativi che/cui, pronomi ci/ne",
            b2: "congiuntivo presente and imperfetto, trapassato prossimo, forma passiva, gerundio (avoid passato remoto except in set phrases)")
        }
    }
}

/// Another edition of a book: a published human translation, or the original a translation was made from.
struct HumanEdition: Codable {
    struct Chapter: Codable { var title: String; var paragraphs: [String] }
    var language: Language
    /// Empty for the original.
    var translator: String
    var chapters: [Chapter]
}

/// One glossary entry for a word in a generated paragraph.
struct Gloss: Codable, Hashable {
    var surface: String
    var lemma: String
    /// The meaning in the reader's own language.
    var meaning: String
    var isNew: Bool
    enum CodingKeys: String, CodingKey { case surface, lemma, meaning = "english", isNew }
}

/// A paragraph rewritten at one level.
struct Rendition: Codable, Hashable {
    var text: String
    var glossary: [Gloss]
}

/// A word introduced at one level of one book, and how often the text has used it since.
struct IntroducedWord: Codable, Hashable {
    var lemma: String
    var meaning: String
    var uses: Int
    enum CodingKeys: String, CodingKey { case lemma, meaning = "english", uses }
}

@Model
final class Book {
    var uid: UUID = UUID()
    var title: String = ""
    var author: String = ""
    /// The language being learned.
    var targetLanguageRaw: String = Language.french.rawValue
    /// The language the book was written in; the same as the target language for an original.
    var sourceLanguageRaw: String = "en"
    /// The reader's own language: the side column and word meanings.
    var nativeLanguageRaw: String = "en"
    /// Who made the human translation used for the target language (Native level) or the side column, if any.
    var targetTranslator: String?
    var sideTranslator: String?
    /// A human translation's chapters ([HumanEdition]), kept until they are matched to this book's chapters.
    var humanTargetEdition: Data?
    var humanSideEdition: Data?
    var levelRaw: String = Level.b1.rawValue
    var currentChapter: Int = 0
    /// The first paragraph of the page being read, in the current chapter (pages are re-cut when the screen
    /// size or the text changes, so the place is kept by paragraph, not by page number).
    var readingParagraph: Int = 0
    /// …and the word in it the page starts at, when a page starts partway through a paragraph.
    var readingWord: Int = 0
    /// How far through the book the reader is (0…1, by words of the book as written), updated as pages turn.
    var progress: Double = 0

    /// Works out `progress` from the current chapter and paragraph.
    func updateProgress() {
        var before = 0, total = 0
        for (i, ch) in sortedChapters.enumerated() {
            for p in ch.paragraphs {
                let n = p.source.split(separator: " ").count
                total += n
                if i < currentChapter || (i == currentChapter && p.index < readingParagraph) { before += n }
            }
        }
        progress = total > 0 ? Double(before + readingWord) / Double(total) : 0
    }
    var createdAt: Date = Date()
    /// The Project Gutenberg book it came from, if it came from the catalog.
    var gutenbergID: Int?
    var introducedData: Data?
    @Relationship(deleteRule: .cascade, inverse: \Chapter.book) var chapters: [Chapter] = []

    init(title: String, author: String, language: Language, source: Language, native: Language, level: Level) {
        self.title = title
        self.author = author
        self.targetLanguageRaw = language.rawValue
        self.sourceLanguageRaw = source.rawValue
        self.nativeLanguageRaw = native.rawValue
        self.levelRaw = level.rawValue
    }

    /// The language being learned.
    var language: Language { Language(rawValue: targetLanguageRaw) ?? .french }
    var source: Language { Language(rawValue: sourceLanguageRaw) ?? .english }
    var native: Language { Language(rawValue: nativeLanguageRaw) ?? .english }
    /// The side column shows the book as written, rather than a translation.
    var sideIsSource: Bool { source == native }
    /// Written in the language being learned (not retold from English).
    var isOriginal: Bool { sourceLanguageRaw == targetLanguageRaw }
    var level: Level {
        get { Level(rawValue: levelRaw) ?? .b1 }
        set { levelRaw = newValue.rawValue }
    }
    var sortedChapters: [Chapter] { chapters.sorted { $0.index < $1.index } }

    /// Words introduced so far, per level, in the order they first appeared.
    var introduced: [String: [IntroducedWord]] {
        get { introducedData.flatMap { try? JSONDecoder().decode([String: [IntroducedWord]].self, from: $0) } ?? [:] }
        set { introducedData = try? JSONEncoder().encode(newValue) }
    }
}

@Model
final class Chapter {
    var index: Int = 0
    var title: String = ""
    var book: Book?
    @Relationship(deleteRule: .cascade, inverse: \Paragraph.chapter) var paragraphs: [Paragraph] = []
    /// This chapter in a human translation (into the target language, or into the reader's language),
    /// waiting to be lined up with the paragraphs; nil once lined up, or when there is none.
    var humanTargetText: String?
    var humanSideText: String?
    /// The human translation couldn't be lined up with this chapter, so it is machine translated.
    var humanTranslationFailed: Bool = false

    init(index: Int, title: String) {
        self.index = index
        self.title = title
    }

    var sortedParagraphs: [Paragraph] { paragraphs.sorted { $0.index < $1.index } }
}

@Model
final class Paragraph {
    var uid: UUID = UUID()
    var index: Int = 0
    /// The paragraph as the book was written.
    @Attribute(originalName: "english") var source: String = ""
    /// The translation shown in the side column, in the reader's language (human or machine),
    /// when the book wasn't written in that language.
    @Attribute(originalName: "englishTranslation") var sideTranslation: String?
    /// The paragraph in a human translation into the target language, lined up with this one.
    var humanTarget: String?
    var overrideLevelRaw: String?
    var renditionsData: Data?
    var chapter: Chapter?

    init(index: Int, source: String) {
        self.index = index
        self.source = source
    }

    var overrideLevel: Level? {
        get { overrideLevelRaw.flatMap(Level.init(rawValue:)) }
        set { overrideLevelRaw = newValue?.rawValue }
    }

    var renditions: [String: Rendition] {
        get { renditionsData.flatMap { try? JSONDecoder().decode([String: Rendition].self, from: $0) } ?? [:] }
        set { renditionsData = try? JSONEncoder().encode(newValue) }
    }

    func effectiveLevel(book: Book) -> Level { overrideLevel ?? book.level }
    /// What the side column shows, in the reader's language.
    func side(book: Book) -> String? { book.sideIsSource ? source : sideTranslation }
    func rendition(_ level: Level) -> Rendition? { renditions[level.rawValue] }
}

/// A word the reader double-tapped. It counts as known after it has been seen
/// often enough, on enough different days, without another double-tap.
@Model
final class LearnerWord {
    var key: String = ""
    var languageRaw: String = ""
    var lemma: String = ""
    /// The meaning in the reader's own language.
    @Attribute(originalName: "english") var meaning: String = ""
    var taps: Int = 0
    var lastTap: Date = Date()
    var cleanSightings: Int = 0
    var cleanDays: [Int] = []
    var known: Bool = false

    static let sightingsToKnow = 4
    static let daysToKnow = 2

    init(language: Language, lemma: String, meaning: String) {
        self.key = LearnerWord.key(language, lemma)
        self.languageRaw = language.rawValue
        self.lemma = lemma
        self.meaning = meaning
    }

    static func key(_ language: Language, _ lemma: String) -> String {
        "\(language.rawValue):\(lemma.lowercased())"
    }
}

import Foundation
import NaturalLanguage
import SwiftData

/// Dictionary forms of words, on the device ("allait" → "aller", "ging" → "gehen", "went" → "go").
enum Lemmatizer {
    static func lemma(_ word: String, language: Language) -> String {
        lemmas(in: word, language: language).first ?? word.lowercased()
    }

    static func lemmas(in text: String, language: Language) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        tagger.setLanguage(language.nl, range: text.startIndex..<text.endIndex)
        var out: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            out.append((tag?.rawValue ?? String(text[range])).lowercased())
            return true
        }
        return out
    }
}

/// The reader's own vocabulary: words they double-tapped, and when those count as learned.
@MainActor
enum Learner {
    static func word(_ language: Language, _ lemma: String, in context: ModelContext) -> LearnerWord? {
        let key = LearnerWord.key(language, lemma)
        return try? context.fetch(FetchDescriptor<LearnerWord>(predicate: #Predicate { $0.key == key })).first
    }

    /// A double-tap: the reader doesn't know this word (again).
    @discardableResult
    static func markUnknown(_ language: Language, lemma: String, meaning: String, in context: ModelContext) -> LearnerWord {
        let w = word(language, lemma, in: context) ?? {
            let n = LearnerWord(language: language, lemma: lemma, meaning: meaning)
            context.insert(n)
            return n
        }()
        if !meaning.isEmpty { w.meaning = meaning }
        w.taps += 1
        w.lastTap = Date()
        w.cleanSightings = 0
        w.cleanDays = []
        w.known = false
        try? context.save()
        return w
    }

    static func markKnown(_ w: LearnerWord, in context: ModelContext) {
        w.known = true
        try? context.save()
    }

    /// The reader saw these words in a paragraph without double-tapping them.
    static func recordSighting(lemmas: Set<String>, language: Language, in context: ModelContext) {
        let lang = language.rawValue
        guard let learning = try? context.fetch(FetchDescriptor<LearnerWord>(
            predicate: #Predicate { $0.languageRaw == lang && !$0.known })) else { return }
        let today = Int(Date().timeIntervalSinceReferenceDate / 86_400)
        var changed = false
        for w in learning where lemmas.contains(w.lemma.lowercased()) {
            // the sighting that made them double-tap doesn't count
            guard Date().timeIntervalSince(w.lastTap) > 60 else { continue }
            w.cleanSightings += 1
            if !w.cleanDays.contains(today) { w.cleanDays.append(today) }
            if w.cleanSightings >= LearnerWord.sightingsToKnow && w.cleanDays.count >= LearnerWord.daysToKnow { w.known = true }
            changed = true
        }
        if changed { try? context.save() }
    }

    /// Words still being learned, most recently tapped first, for the generator to reuse.
    static func learning(_ language: Language, in context: ModelContext, limit: Int = 30) -> [LearnerWord] {
        let lang = language.rawValue
        var d = FetchDescriptor<LearnerWord>(predicate: #Predicate { $0.languageRaw == lang && !$0.known },
                                             sortBy: [SortDescriptor(\.lastTap, order: .reverse)])
        d.fetchLimit = limit
        return (try? context.fetch(d)) ?? []
    }
}

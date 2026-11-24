import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The free service: everything on the device, no AI key. Apple's on-device model is small but writes good simple
/// English, and Apple's translator is excellent, so text is rewritten in two steps (tested 2026-11-24 on five
/// paragraphs at A2 and B1: about as fast as DeepSeek, simple natural French):
///   1. the text in English (translated first if it is in another language), simplified to the level by the model;
///   2. that simple English translated into the language being learned.
/// The Native level is a straight translation. No glossary: the model's glossaries were unreliable, so tapped words
/// get their meaning from the translator instead (`meaning`).
///
/// Needs iOS 26, a device with Apple Intelligence switched on, and the translation languages downloaded.
enum OnDevice {
    enum Problem: LocalizedError {
        case noModel(String), noLanguages(String, String)
        var errorDescription: String? {
            switch self {
            case .noModel(let why): "Apple's on-device AI isn't available here (\(why)). Choose another service in Settings."
            case .noLanguages(let a, let b): "Download \(a) and \(b) for translation on this device: tap Download in the library or in Settings."
            }
        }
    }

    /// Whether Apple's on-device model can run here; nil when it can, else why not, in a few words.
    static var modelProblem: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "this device doesn't support Apple Intelligence"
            case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is switched off in Settings"
            case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading"
            default: return "not available"
            }
        }
        #endif
        return "it needs iOS 26 or later"
    }

    static var isAvailable: Bool { modelProblem == nil }

    /// The language pairs the translator needs for this text, as codes.
    static func pairs(from source: String, to target: String, level: Level) -> [(String, String)] {
        if level == .native { return source == target ? [] : [(source, target)] }
        var p: [(String, String)] = []
        if source != "en" { p.append((source, "en")) }
        if target != "en" { p.append(("en", target)) }
        return p
    }

    /// Whether everything needed is on the device; throws with what to do if not.
    static func check(from source: String, to target: String, level: Level) async throws {
        if level != .native, let why = modelProblem { throw Problem.noModel(why) }
        for (a, b) in pairs(from: source, to: target, level: level) where !(await AppleTranslation.isReady(from: a, to: b)) {
            throw Problem.noLanguages(name(a), name(b))
        }
    }

    private static func name(_ code: String) -> String {
        Language(rawValue: code)?.name ?? Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// `texts` (in `source`) rewritten at `level` in `target`, in order.
    static func rewrite(_ texts: [String], from source: String, to target: String, level: Level) async throws -> [String] {
        try await check(from: source, to: target, level: level)
        if level == .native {
            if source == target { return texts }
            guard let t = await AppleTranslation.translate(texts, from: source, to: target) else { throw Problem.noLanguages(name(source), name(target)) }
            return t
        }
        // 1. into English
        var english = texts
        if source != "en" {
            guard let t = await AppleTranslation.translate(texts, from: source, to: "en") else { throw Problem.noLanguages(name(source), "English") }
            english = t
        }
        // 2. simplified, paragraph by paragraph (the model only takes about 4,000 tokens at a time)
        var simple: [String] = []
        for e in english { simple.append(await simplify(e, level: level) ?? e) }
        // 3. into the language being learned
        if target == "en" { return simple }
        guard let t = await AppleTranslation.translate(simple, from: "en", to: target) else { throw Problem.noLanguages("English", name(target)) }
        return t
    }

    /// One English paragraph rewritten at the level; nil if the model fails (the caller keeps the original).
    static func simplify(_ english: String, level: Level) async -> String? {
        // very short pieces (headings, labels, menu items) are already simple
        if english.split(separator: " ").count < 8 { return english }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: """
            You write graded readers (like Oxford Bookworms): you rewrite English text in simpler English at CEFR level \(level.rawValue).
            Level \(level.rawValue) rules: \(level.rules(for: .english)) New words per 100 words: \(level.newWordsPer100).
            Keep the meaning, the events, names and numbers. Simplify how it is said, not what it says. Do not add anything that is not in the source. Write one paragraph.
            """)
            return try? await session.respond(to: english, generating: SimpleEnglish.self).content.text
        }
        #endif
        return nil
    }

    /// The meaning of a word in a sentence, in the reader's own language, from the translator.
    static func meaning(of word: String, sentence: String, from source: String, to native: String) async -> (lemma: String, meaning: String)? {
        let lemma = Lemmatizer.lemma(word, language: Language(rawValue: source) ?? .english)
        guard let t = await AppleTranslation.translate([lemma == word.lowercased() ? word : lemma], from: source, to: native),
              let m = t.first, !m.isEmpty else { return nil }
        return (lemma, m)
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable struct SimpleEnglish {
    @Guide(description: "the paragraph rewritten in simple English at the reader's level")
    var text: String
}
#endif

import Foundation
import SwiftData
import Observation

/// Translates and grades paragraphs on demand, one batch at a time, and keeps
/// the book's record of which words each level has introduced. Where a published
/// human translation exists, it lines that up with the book first and uses it.
@MainActor
@Observable
final class Generator {
    static let shared = Generator()

    private(set) var pending: Set<String> = []
    private(set) var failed: [String: String] = [:]
    /// What the generator is doing besides translating, for the reader's header.
    private(set) var status: String?

    /// The request being answered now: its paragraphs, their words, and when it was sent, for the progress bar.
    private(set) var current: (keys: Set<String>, words: Int, started: Date)?
    /// How long requests have taken per source word, averaged (kept between launches).
    static var secondsPerWord: Double {
        get { let v = UserDefaults.standard.double(forKey: "secondsPerWord"); return v > 0 ? v : 0.06 }
        set { UserDefaults.standard.set(newValue, forKey: "secondsPerWord") }
    }
    /// Seconds the current request is expected to take.
    var expectedSeconds: Double { max(8, Double(current?.words ?? 0) * Self.secondsPerWord + 4) }
    var lastError: String?
    /// Whether this generator writes the side column too. The pre-generator runs one generator per level at once,
    /// and only one of them needs to.
    var writesSide = true
    /// Most paragraphs in one request. The pre-generator allows more, as plays and dialogue have many short ones.
    var batchParagraphs = Generator.batchParagraphs

    private struct Job { var book: Book; var level: Level; var paragraphs: [Paragraph] }
    private var queue: [Job] = []
    private var running = false

    static let batchParagraphs = 8
    static let batchWords = 1_200
    /// How far ahead of the reader text is made: about five printed pages. Only what is about to be read is
    /// rewritten, so a change of level costs little and no credits go on pages the reader never reaches.
    static let lookaheadWords = 1_500

    static func key(_ p: Paragraph, _ l: Level) -> String { "\(p.uid.uuidString)|\(l.rawValue)" }
    func isPending(_ p: Paragraph, _ l: Level) -> Bool { pending.contains(Self.key(p, l)) }
    func failure(_ p: Paragraph, _ l: Level) -> String? { failed[Self.key(p, l)] }

    /// Queues the next few pages from paragraph `from` that have no text yet at their level, ahead of anything
    /// already waiting. Called again as the reader scrolls, so it keeps a few pages ahead of them.
    func ensure(chapter: Chapter, book: Book, from: Int = 0) {
        var ahead: [Paragraph] = [], words = 0
        for p in chapter.sortedParagraphs where p.index >= from {
            guard words < Self.lookaheadWords else { break }
            ahead.append(p)
            words += p.source.split(separator: " ").count
        }
        queue.insert(contentsOf: jobs(for: ahead, book: book), at: 0)
        run()
    }

    func retry(_ p: Paragraph, book: Book) {
        let l = p.effectiveLevel(book: book)
        failed[Self.key(p, l)] = nil
        if let ch = p.chapter { ensure(chapter: ch, book: book, from: p.index) }
    }

    private func jobs(for paragraphs: [Paragraph], book: Book) -> [Job] {
        var byLevel: [Level: [Paragraph]] = [:]
        for p in paragraphs {
            let l = p.effectiveLevel(book: book)
            let k = Self.key(p, l)
            guard p.rendition(l) == nil, !pending.contains(k), failed[k] == nil else { continue }
            byLevel[l, default: []].append(p)
            pending.insert(k)
        }
        return byLevel.map { Job(book: book, level: $0.key, paragraphs: $0.value) }
    }

    private func run() {
        guard !running else { return }
        running = true
        Task {
            while !queue.isEmpty {
                let job = queue.removeFirst()
                if job.book.humanTargetEdition != nil || job.book.humanSideEdition != nil { await matchChapters(job.book) }
                if let ch = job.paragraphs.first?.chapter, ch.humanTargetText != nil || ch.humanSideText != nil {
                    await lineUp(ch, book: job.book)
                }
                for batch in batches(job.paragraphs) {
                    await generate(batch, level: job.level, book: job.book)
                }
            }
            running = false
        }
    }

    /// Lines up any published translations with the book's chapters, up to about `words` words of it (normally done
    /// chapter by chapter as it is read).
    func lineUpAll(_ book: Book, words limit: Int? = nil) async {
        if book.humanTargetEdition != nil || book.humanSideEdition != nil { await matchChapters(book) }
        var words = 0
        for ch in book.sortedChapters {
            if let limit, words >= limit { break }
            words += ch.paragraphs.reduce(0) { $0 + $1.source.split(separator: " ").count }
            if ch.humanTargetText != nil || ch.humanSideText != nil { await lineUp(ch, book: book) }
        }
    }

    /// Writes the book at `level` from the start, up to about `words` words of it (the whole book if nil),
    /// for the pre-generator. Paragraphs that fail are left for the reader's own generator.
    func generateAll(_ book: Book, level: Level, words limit: Int? = nil, progress: (Int) -> Void = { _ in }) async {
        // batches stay within a chapter: answers are matched by paragraph index, which starts again in each chapter
        var chapters: [[Paragraph]] = [], words = 0
        for ch in book.sortedChapters {
            if let limit, words >= limit { break }
            var ps: [Paragraph] = []
            for p in ch.sortedParagraphs {
                if let limit, words >= limit { break }
                ps.append(p)
                words += p.source.split(separator: " ").count
            }
            chapters.append(ps)
        }
        var done = 0
        for ps in chapters {
            done += ps.filter { $0.rendition(level) != nil }.reduce(0) { $0 + $1.source.split(separator: " ").count }
            for batch in batches(ps.filter { $0.rendition(level) == nil }) {
                await generate(batch, level: level, book: book)
                done += batch.reduce(0) { $0 + $1.source.split(separator: " ").count }
                progress(done)
            }
        }
    }

    private func batches(_ ps: [Paragraph]) -> [[Paragraph]] {
        var out: [[Paragraph]] = [], cur: [Paragraph] = [], words = 0
        for p in ps {
            let w = p.source.split(separator: " ").count
            if !cur.isEmpty && (cur.count >= batchParagraphs || words + w > Self.batchWords) {
                out.append(cur); cur = []; words = 0
            }
            cur.append(p); words += w
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: - One request

    private struct Answer: Decodable {
        struct Para: Decodable { var i: Int; var text: String?; var side: String?; var glossary: [Entry]? }
        struct Entry: Decodable {
            var w: String; var lemma: String?; var m: String?; var new: Bool?
        }
        var paragraphs: [Para]
    }

    /// At Native level, an original is shown as written, and a retold book in its published human translation.
    static func given(_ p: Paragraph, level: Level, book: Book) -> String? {
        guard level == .native else { return nil }
        return book.isOriginal ? p.source : p.humanTarget
    }

    private func generate(_ batch: [Paragraph], level: Level, book: Book) async {
        guard let context = book.modelContext else { return }
        let lang = book.language
        let given = batch.allSatisfy { Self.given($0, level: level, book: book) != nil }
        let needSide = writesSide && !book.sideIsSource && batch.contains { $0.sideTranslation == nil }
        let system = Self.systemPrompt(level: level, book: book, given: given, needSide: needSide,
                                       learning: Learner.learning(lang, in: context))
        let user = userPrompt(batch, level: level, book: book, given: given)
        let words = batch.reduce(0) { $0 + $1.source.split(separator: " ").count }
        current = (Set(batch.map { Self.key($0, level) }), words, Date())
        defer { current = nil }
        do {
            let data = try await LLM.json(system: system, user: user)
            if let c = current, words > 0 {
                // learn how fast the service is, so the next estimate is closer
                let perWord = max(0, Date().timeIntervalSince(c.started) - 4) / Double(words)
                Self.secondsPerWord = Self.secondsPerWord * 0.6 + perWord * 0.4
            }
            let answer = try JSONDecoder().decode(Answer.self, from: data)
            var introduced = book.introduced[level.rawValue] ?? []
            var known = Set(introduced.map { $0.lemma.lowercased() })
            for p in batch {
                let k = Self.key(p, level)
                guard let a = answer.paragraphs.first(where: { $0.i == p.index }),
                      let text = given ? Self.given(p, level: level, book: book) : a.text, !text.isEmpty else {
                    failed[k] = "Missing from the answer"; pending.remove(k); continue
                }
                if needSide, p.sideTranslation == nil, let side = a.side, !side.isEmpty { p.sideTranslation = side }
                var glossary: [Gloss] = []
                for e in a.glossary ?? [] {
                    let lemma = (e.lemma?.isEmpty == false ? e.lemma! : Lemmatizer.lemma(e.w, language: lang))
                    // "new" means first appearance at this level in this book, whatever the model thought
                    let isNew = !known.contains(lemma.lowercased()) && (e.new ?? true)
                    if isNew {
                        introduced.append(IntroducedWord(lemma: lemma, meaning: e.m ?? "", uses: 0))
                        known.insert(lemma.lowercased())
                    }
                    glossary.append(Gloss(surface: e.w, lemma: lemma, meaning: e.m ?? "", isNew: isNew))
                }
                // count every use of an introduced word, so the prompt stops recycling it once it has been seen enough
                // (glossary lemmas too: on-device lemmas aren't always available)
                let used = Set(Lemmatizer.lemmas(in: text, language: lang)).union(glossary.map { $0.lemma.lowercased() })
                for i in introduced.indices where used.contains(introduced[i].lemma.lowercased()) { introduced[i].uses += 1 }
                var r = p.renditions
                r[level.rawValue] = Rendition(text: text, glossary: glossary)
                p.renditions = r
                pending.remove(k)
            }
            var all = book.introduced
            all[level.rawValue] = introduced
            book.introduced = all
            try? context.save()
            lastError = nil
        } catch {
            for p in batch {
                let k = Self.key(p, level)
                pending.remove(k)
                failed[k] = error.localizedDescription
            }
            lastError = error.localizedDescription
        }
    }

    static let recycleUses = 5

    static func systemPrompt(level: Level, book: Book, given: Bool, needSide: Bool, learning: [LearnerWord]) -> String {
        let lang = book.language.name, native = book.native.name
        let introduced = book.introduced[level.rawValue] ?? []
        let recycle = introduced.filter { $0.uses < recycleUses }.suffix(40)
        let original = book.isOriginal
        let task = original
            ? "you adapt a book written in \(lang) into simpler \(lang) for \(native) speakers learning \(lang)"
            : "you retell a book written in \(book.source.name) in \(lang) for \(native) speakers learning \(lang)"
        let shown = original || book.targetTranslator == "" ? "the original text unchanged"
            : "the published \(lang) translation by \(book.targetTranslator ?? "a translator")"
        var s = """
        You write graded readers: \(task), following the conventions of published graded-reader series \
        (\(book.language.readerSeries)). The reader has chosen \(given ? "to read \(shown)" : "CEFR level \(level.rawValue)").

        """
        if !given {
            s += """
            Level \(level.rawValue) rules:
            \(level.rules(for: book.language))
            New words per 100 words: \(level.newWordsPer100).

            How to write:
            - Write exactly one \(lang) paragraph for each source paragraph, with the same index, in the same order. Never merge, split or drop paragraphs: the app shows them side by side with the \(native).
            - Keep the story, the characters' names, the events and the dialogue (dialogue stays dialogue). Simplify how it is said, not what happens. Cut only minor detail that the level cannot carry.
            - When a word above the level is essential to the story, keep it and make its meaning clear from the context; then use it again in the next few paragraphs so the reader learns it.
            """
            if original { s += "\n- Keep the author's own words wherever they already fit the level." }
            else if book.targetTranslator != nil { s += "\n- Paragraphs come with their published \(lang) translation. Start from it: keep the translator's words and phrasing wherever they already fit the level." }
        }
        if !recycle.isEmpty {
            s += "\n\nWords this book has recently introduced at this level. Reuse them where they fit naturally, so the reader meets each several times:\n"
            s += recycle.map { "\($0.lemma) (\($0.meaning))" }.joined(separator: ", ")
        }
        if !learning.isEmpty {
            s += "\n\nWords this reader is trying to learn. Where one fits the story naturally, use it (never force it in):\n"
            s += learning.map { "\($0.lemma) (\($0.meaning))" }.joined(separator: ", ")
        }
        let textField = given ? "" : "\"text\":\"<the \(lang) paragraph>\","
        let sideField = needSide ? "\"side\":\"<a faithful, natural \(native) translation of the source paragraph>\"," : ""
        s += """


        Glossary: for each paragraph, list the words a reader at \(level.rawValue) probably does not know yet: words above the level, \
        idioms and set phrases, plus any word from the two lists above that \(given ? "appears" : "you used"). For each give "w", \
        the exact form as it appears in \(given ? "the text" : "your text"); "lemma", its dictionary form; "m", its meaning in \(native) \
        in this context (a few words); and "new": true if this word has not appeared earlier in this book at this level \
        (it is not in the recently-introduced list), else false. \
        \(level == .native || level == .c1 ? "At this level list only uncommon words." : "")
        \(needSide ? "\nAlso give \"side\": a \(native) translation of each source paragraph, for the \(native) column." : "")
        \(given ? "\nDo not rewrite the text: the app shows it as it is." : "")

        Answer with only this JSON object:
        {"paragraphs":[{"i":<index>,\(textField)\(sideField)"glossary":[{"w":"…","lemma":"…","m":"…","new":true}]}]}
        """
        return s
    }

    private func userPrompt(_ batch: [Paragraph], level: Level, book: Book, given: Bool) -> String {
        var s = "Book: \(book.title)\(book.author.isEmpty ? "" : " by \(book.author)")\n"
        if let ch = batch.first?.chapter {
            s += "Chapter: \(ch.title)\n"
            // the paragraph just before this batch, as already written, keeps names and tone consistent
            if !given, let first = batch.first, let prev = ch.sortedParagraphs.last(where: { $0.index < first.index }),
               let r = prev.rendition(level) {
                s += "\nThe previous paragraph, as you already wrote it (for context only):\n\(r.text)\n"
            }
        }
        if given && !book.isOriginal {
            s += "\nThe \(book.language.name) text, with the \(book.source.name) paragraph it translates:\n"
            for p in batch { s += "\n[i=\(p.index)] \(p.humanTarget ?? "")\n(Source: \(p.source))\n" }
            return s
        }
        s += "\n\(book.isOriginal ? "Original \(book.language.name)" : book.source.name) paragraphs:\n"
        for p in batch {
            s += "\n[i=\(p.index)] \(p.source)\n"
            if let human = p.humanTarget {
                s += "(Published \(book.language.name) translation: \(human))\n"
            } else if !book.isOriginal, level != .native, let fluent = p.rendition(.native) {
                s += "(Fluent translation for reference: \(fluent.text))\n"
            }
        }
        return s
    }

    // MARK: - Human translations

    private var unmatched: Set<UUID> = []

    private struct ChapterMap: Decodable {
        struct Entry: Decodable { var i: Int; var t: [Int] }
        var map: [Entry]
    }

    /// Pairs the book's chapters with those of each human edition waiting on it (one request per edition),
    /// and leaves each chapter's share of the translation for `lineUp`.
    private func matchChapters(_ book: Book) async {
        guard !unmatched.contains(book.uid) else { return }
        let chapters = book.sortedChapters
        for side in [false, true] {
            guard let data = side ? book.humanSideEdition : book.humanTargetEdition,
                  let edition = try? JSONDecoder().decode(HumanEdition.self, from: data) else { continue }
            status = "Matching chapters with the \(edition.language.name) translation…"
            func outline(_ title: String, _ paragraphs: [String]) -> String {
                "\(title) — \(paragraphs.joined(separator: " ").prefix(160))"
            }
            let user = """
            Book (\(book.source.name)): \(book.title)
            \(chapters.enumerated().map { "[\($0.offset)] \(outline($0.element.title, $0.element.sortedParagraphs.map(\.source)))" }.joined(separator: "\n"))

            Another edition (\(edition.language.name)\(edition.translator.isEmpty ? ", the original" : ", translated by \(edition.translator)")):
            \(edition.chapters.enumerated().map { "[\($0.offset)] \(outline($0.element.title, $0.element.paragraphs))" }.joined(separator: "\n"))

            For each chapter of the book, give the other edition's chapters that hold the same text, in order \
            ([] if the other edition leaves it out). Leave out the other edition's prefaces, notes and other matter \
            the book doesn't have. Answer: {"map":[{"i":0,"t":[0]}]}
            """
            do {
                let data = try await LLM.json(system: "You match the chapters of a book with the chapters of another edition of the same work, in another language. Answer with only a JSON object.", user: user)
                let map = try JSONDecoder().decode(ChapterMap.self, from: data)
                for e in map.map where chapters.indices.contains(e.i) {
                    let text = e.t.filter { edition.chapters.indices.contains($0) }
                        .flatMap { edition.chapters[$0].paragraphs }.joined(separator: "\n\n")
                    if text.isEmpty { chapters[e.i].humanTranslationFailed = true; continue }
                    if side { chapters[e.i].humanSideText = text } else { chapters[e.i].humanTargetText = text }
                }
                if side { book.humanSideEdition = nil } else { book.humanTargetEdition = nil }
                try? book.modelContext?.save()
            } catch {
                // machine translation for now; try again next time the app starts
                unmatched.insert(book.uid)
            }
        }
        status = nil
    }

    private struct LinedUp: Decodable {
        struct Piece: Decodable { var i: Int; var t: String }
        var paragraphs: [Piece]
    }

    /// Splits a chapter's human translation into pieces, one per paragraph, keeping the translator's words.
    /// If the pieces don't account for the translation, the chapter falls back to machine translation.
    private func lineUp(_ chapter: Chapter, book: Book) async {
        let paragraphs = chapter.sortedParagraphs
        for side in [false, true] {
            guard let text = side ? chapter.humanSideText : chapter.humanTargetText else { continue }
            let lang = side ? book.native : book.language
            status = "Lining up the published \(lang.name) translation…"
            let user = """
            Book paragraphs (\(book.source.name)):
            \(paragraphs.map { "[i=\($0.index)] \($0.source)" }.joined(separator: "\n\n"))

            The published \(lang.name) translation of this chapter:
            \(text)

            Split the translation into pieces, one for each book paragraph, in order, so that each piece is the \
            translation of that paragraph. Copy the translation's words exactly: never translate, correct, shorten or \
            summarize. Every word of the translation goes into exactly one piece, in order. A piece is empty if the \
            translation leaves that paragraph out. Answer: {"paragraphs":[{"i":0,"t":"…"}]}
            """
            var ok = false
            if let data = try? await LLM.json(system: "You line up a published translation with the paragraphs of the book it translates. Answer with only a JSON object.", user: user),
               let answer = try? JSONDecoder().decode(LinedUp.self, from: data) {
                let pieces = Dictionary(answer.paragraphs.map { ($0.i, $0.t.trimmingCharacters(in: .whitespacesAndNewlines)) }, uniquingKeysWith: { a, _ in a })
                func letters(_ s: String) -> Int { s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count }
                let kept = paragraphs.compactMap { pieces[$0.index] }.reduce(0) { $0 + letters($1) }
                let filled = paragraphs.filter { !(pieces[$0.index] ?? "").isEmpty }.count
                // the pieces must hold (nearly) the whole translation, spread over most paragraphs
                let share = Double(kept) / Double(max(letters(text), 1))
                ok = share > 0.9 && share < 1.1 && Double(filled) / Double(max(paragraphs.count, 1)) > 0.7
                if ok {
                    for p in paragraphs {
                        let piece = pieces[p.index] ?? ""
                        // an empty piece: the translator joined this paragraph to a neighbour (or left it out);
                        // the side column stays blank rather than repeating it in machine translation
                        if side { p.sideTranslation = piece } else if !piece.isEmpty { p.humanTarget = piece }
                    }
                }
            }
            if !ok { chapter.humanTranslationFailed = true }
            if side { chapter.humanSideText = nil } else { chapter.humanTargetText = nil }
            try? chapter.modelContext?.save()
        }
        status = nil
    }

    // MARK: - Single word lookup (double-tap on a word the glossary doesn't cover)

    private struct WordAnswer: Decodable { var lemma: String; var m: String }

    func lookUp(_ word: String, sentence: String, language: Language, native: Language) async -> (lemma: String, meaning: String)? {
        let system = "You are a concise \(language.name)–\(native.name) dictionary. Answer with only a JSON object."
        let user = """
        Give the dictionary form and the \(native.name) meaning, as used here, of the \(language.name) word "\(word)" in:
        "\(sentence)"
        JSON: {"lemma":"…","m":"…"}
        """
        guard let data = try? await LLM.json(system: system, user: user),
              let a = try? JSONDecoder().decode(WordAnswer.self, from: data) else { return nil }
        return (a.lemma, a.m)
    }
}

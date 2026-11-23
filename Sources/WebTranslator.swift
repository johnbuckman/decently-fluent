import Foundation
import CryptoKit
import NaturalLanguage
import Observation

/// One piece of a web page's text (a paragraph, heading, list item, table cell…), as the page script found it.
/// Links are marked ⟦1⟧…⟦/1⟧ so they can be put back around the right words.
struct WebBlock: Codable, Hashable {
    var id: Int
    var text: String
}

/// A block rewritten in the language being learned, at one level.
struct WebRendition: Codable, Hashable {
    var text: String
    var glossary: [Gloss]
}

/// Rewrites web pages block by block, only the blocks the reader is about to see, at their level, in the
/// language they're learning. Results are kept on disk by page, language and level, so going back or
/// reloading costs nothing.
@MainActor
@Observable
final class WebTranslator {
    /// Blocks being written now, and waiting.
    private(set) var busy = 0
    private(set) var lastError: String?

    var language: Language
    var native: Language
    var level: Level
    private var page: URL?
    /// The language the current page is written in, once enough of it has been seen to tell.
    private(set) var pageLanguage: NLLanguage?

    private var cache: [String: WebRendition] = [:]
    private var cacheKey = ""
    private var queue: [WebBlock] = []
    /// Blocks waiting for a text to be written, by the text's hash.
    private var waiting: [String: [Int]] = [:]
    private var workers = 0
    /// Requests sent at once: pages are read in bursts, and two keeps up with fast scrolling.
    private static let maxWorkers = 2
    static let batchBlocks = 12
    static let batchWords = 900

    /// Called with each block that is ready (and with nil text for a block that failed).
    var onReady: (Int, WebRendition?) -> Void = { _, _ in }

    init(language: Language, native: Language, level: Level) {
        self.language = language
        self.native = native
        self.level = level
    }

    /// A new page (or a new level or language): forget what was waiting, load what is saved for it.
    func start(page url: URL?) {
        page = url
        queue = []
        waiting = [:]
        totalBlocks = 0
        doneBlocks = 0
        pageLanguage = nil
        lastError = nil
        loadCache()
    }

    func clearError() { lastError = nil }

    /// Whether this page needs rewriting at all: an original read at Native level is shown as written.
    var showsAsWritten: Bool {
        level == .native && pageLanguage.map { $0 == language.nl } == true
    }

    /// The page script asks for these blocks (they are on screen or about to be).
    func need(_ blocks: [WebBlock]) {
        if pageLanguage == nil {
            let r = NLLanguageRecognizer()
            r.processString(blocks.map(\.text).joined(separator: "\n"))
            // only trust a guess made from enough text
            if blocks.reduce(0, { $0 + $1.text.count }) > 120 { pageLanguage = r.dominantLanguage }
        }
        for b in blocks {
            let h = Self.hash(b.text)
            if let r = cache[h] { onReady(b.id, r); continue }
            if showsAsWritten { continue }
            // the same text elsewhere on the page (a repeated heading or label) is written once, for all of them
            if waiting[h] != nil { if !waiting[h]!.contains(b.id) { waiting[h]!.append(b.id) }; continue }
            waiting[h] = [b.id]
            queue.append(b)
            totalBlocks += 1
        }
        busy = queue.count + inFlight
        run()
    }

    private var inFlight = 0

    // MARK: - Progress, for the bar and time estimate

    /// Blocks asked for since the translator was last idle, and how many of them are done.
    private(set) var totalBlocks = 0
    private(set) var doneBlocks = 0
    /// The requests being answered now: their blocks, words and when each was sent.
    private var requests: [UUID: (blocks: Int, words: Int, started: Date)] = [:]

    /// Seconds one request of this many words is expected to take (the reader's own estimate).
    private static func expected(_ words: Int) -> Double { max(8, Double(words) * Generator.secondsPerWord + 4) }

    /// How far the blocks asked for have got (0…1, never quite 1 until the last answer), and about how many seconds
    /// are left; nil when nothing is being written.
    func progress(at now: Date) -> (fraction: Double, secondsLeft: Int, done: Int, total: Int, overdue: Bool)? {
        guard totalBlocks > 0, busy > 0 else { return nil }
        var share = 0.0, inFlightLeft = 0.0, overdue = false
        for r in requests.values {
            let elapsed = now.timeIntervalSince(r.started), exp = Self.expected(r.words)
            // a request in flight moves the bar by the time it has taken, stopping short of done
            share += Double(r.blocks) * min(0.95, elapsed / exp)
            inFlightLeft = max(inFlightLeft, exp - elapsed)
            if elapsed > exp { overdue = true }
        }
        let queuedWords = queue.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let queuedRequests = (queue.count + Self.batchBlocks - 1) / Self.batchBlocks
        let queuedSeconds = (Double(queuedWords) * Generator.secondsPerWord + 4 * Double(queuedRequests)) / Double(Self.maxWorkers)
        let fraction = min(1, (Double(doneBlocks) + share) / Double(totalBlocks))
        return (fraction, Int((max(0, inFlightLeft) + queuedSeconds).rounded()), doneBlocks, totalBlocks, overdue)
    }

    private func run() {
        while workers < Self.maxWorkers, !queue.isEmpty {
            var batch: [WebBlock] = [], words = 0
            while let b = queue.first {
                let w = b.text.split(separator: " ").count
                if !batch.isEmpty && (batch.count >= Self.batchBlocks || words + w > Self.batchWords) { break }
                batch.append(queue.removeFirst()); words += w
            }
            workers += 1
            inFlight += batch.count
            let key = cacheKey
            let id = UUID(), sent = words
            requests[id] = (batch.count, sent, Date())
            Task {
                let started = Date()
                let ok = await generate(batch, key: key)
                if ok, sent > 0 {
                    // learn how fast the service is, so the next estimate is closer (shared with the reader)
                    let perWord = max(0, Date().timeIntervalSince(started) - 4) / Double(sent)
                    Generator.secondsPerWord = Generator.secondsPerWord * 0.6 + perWord * 0.4
                }
                requests[id] = nil
                workers -= 1
                inFlight -= batch.count
                if key == cacheKey { doneBlocks += batch.count }
                busy = queue.count + inFlight
                if busy == 0 { totalBlocks = 0; doneBlocks = 0 }
                run()
            }
        }
    }

    private struct Answer: Decodable {
        struct Block: Decodable { var i: Int; var text: String?; var glossary: [Entry]? }
        struct Entry: Decodable { var w: String; var lemma: String?; var m: String?; var new: Bool? }
        var blocks: [Block]
    }

    /// Writes one batch; false if the request failed.
    @discardableResult
    private func generate(_ batch: [WebBlock], key: String) async -> Bool {
        let system = systemPrompt()
        var user = "Web page: \(page?.absoluteString ?? "")\n\nBlocks:\n"
        for b in batch { user += "\n[i=\(b.id)] \(b.text)\n" }
        do {
            let data = try await LLM.json(system: system, user: user)
            let answer = try JSONDecoder().decode(Answer.self, from: data)
            // a different page, level or language came along while this was being written
            let current = key == cacheKey
            var introduced = Self.introduced(language, level)
            var known = Set(introduced.map { $0.lemma.lowercased() })
            for b in batch {
                let h = Self.hash(b.text)
                let ids = current ? (waiting.removeValue(forKey: h) ?? [b.id]) : []
                guard let a = answer.blocks.first(where: { $0.i == b.id }), let text = a.text, !text.isEmpty else {
                    for id in ids { onReady(id, nil) }
                    continue
                }
                var glossary: [Gloss] = []
                for e in a.glossary ?? [] {
                    let lemma = e.lemma?.isEmpty == false ? e.lemma! : Lemmatizer.lemma(e.w, language: language)
                    let isNew = !known.contains(lemma.lowercased()) && (e.new ?? true)
                    if isNew {
                        introduced.append(IntroducedWord(lemma: lemma, meaning: e.m ?? "", uses: 0))
                        known.insert(lemma.lowercased())
                    }
                    glossary.append(Gloss(surface: e.w, lemma: lemma, meaning: e.m ?? "", isNew: isNew))
                }
                let used = Set(Lemmatizer.lemmas(in: text, language: language)).union(glossary.map { $0.lemma.lowercased() })
                for i in introduced.indices where used.contains(introduced[i].lemma.lowercased()) { introduced[i].uses += 1 }
                let r = WebRendition(text: text, glossary: glossary)
                if current {
                    cache[h] = r
                    for id in ids { onReady(id, r) }
                }
            }
            Self.setIntroduced(introduced, language, level)
            if current { saveCache(); lastError = nil }
            return true
        } catch {
            guard key == cacheKey else { return false }
            lastError = error.localizedDescription
            for b in batch { for id in waiting.removeValue(forKey: Self.hash(b.text)) ?? [b.id] { onReady(id, nil) } }
            return false
        }
    }

    private func systemPrompt() -> String {
        let lang = language.name, native = native.name
        let from = pageLanguage.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0.rawValue) }
        let same = pageLanguage == language.nl
        let task = same
            ? "you adapt a web page written in \(lang) into simpler \(lang)"
            : "you translate a web page\(from.map { " written in \($0)" } ?? "") into \(lang)"
        var s = "You write graded readers: \(task) for \(native) speakers learning \(lang), following the conventions of graded-reader series (\(language.readerSeries)). "
        if level == .native {
            s += "The reader reads at a fluent level: \(same ? "keep the text as written" : "write a natural, faithful, fluent \(lang) translation").\n"
        } else {
            s += """
            The reader has chosen CEFR level \(level.rawValue).

            Level \(level.rawValue) rules:
            \(level.rules(for: language))
            New words per 100 words: \(level.newWordsPer100).

            """
        }
        let recycle = Self.introduced(language, level).filter { $0.uses < Generator.recycleUses }.suffix(30)
        if !recycle.isEmpty {
            s += "\nWords recently introduced to this reader at this level. Reuse them where they fit naturally:\n"
            s += recycle.map { "\($0.lemma) (\($0.meaning))" }.joined(separator: ", ") + "\n"
        }
        if !learningWords.isEmpty {
            s += "\nWords this reader is trying to learn. Where one fits naturally, use it (never force it in):\n"
            s += learningWords.joined(separator: ", ") + "\n"
        }
        s += """

        How to write:
        - Each block is a separate piece of the page: a heading, paragraph, list item, table cell, caption or label. Write exactly one \(lang) block for each source block, with the same index. Never merge, split or drop blocks.
        - Keep the meaning, facts, names, numbers, dates, prices, product names, code and web addresses. Simplify how it is said, not what it says. Short items (menu labels, buttons, dates, names) stay short.
        - Text marked ⟦1⟧…⟦/1⟧ is a link. Keep the same markers, with the same numbers, around the words that carry that meaning in your version.

        Glossary: for each block, list the words a reader at \(level.rawValue) probably does not know yet: words above the level, \
        idioms and set phrases, plus any word from the lists above that you used. For each give "w", the exact form in your text; \
        "lemma", its dictionary form; "m", its meaning in \(native) in this context (a few words); and "new": true if it is not in the \
        recently-introduced list. \(level == .native || level == .c1 ? "At this level list only uncommon words." : "")

        Answer with only this JSON object:
        {"blocks":[{"i":<index>,"text":"<the \(lang) block>","glossary":[{"w":"…","lemma":"…","m":"…","new":true}]}]}
        """
        return s
    }

    /// Words the reader is learning, "lemma (meaning)", set by the browser from My words.
    var learningWords: [String] = []

    // MARK: - Saved pages

    private static var folder: URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("web", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func loadCache() {
        var u = page.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        u?.fragment = nil
        cacheKey = Self.hash("\(u?.string ?? "")|\(native.rawValue)|\(language.rawValue)|\(level.rawValue)")
        cache = (try? Data(contentsOf: Self.folder.appendingPathComponent(cacheKey + ".json")))
            .flatMap { try? JSONDecoder().decode([String: WebRendition].self, from: $0) } ?? [:]
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: Self.folder.appendingPathComponent(cacheKey + ".json"))
    }

    // MARK: - Words introduced by web pages, per language and level

    private static func introducedKey(_ l: Language, _ level: Level) -> String { "web.introduced.\(l.rawValue).\(level.rawValue)" }

    static func introduced(_ l: Language, _ level: Level) -> [IntroducedWord] {
        UserDefaults.standard.data(forKey: introducedKey(l, level))
            .flatMap { try? JSONDecoder().decode([IntroducedWord].self, from: $0) } ?? []
    }

    static func setIntroduced(_ words: [IntroducedWord], _ l: Language, _ level: Level) {
        // the newest few thousand are plenty to tell a new word from one already met
        let kept = Array(words.suffix(4_000))
        UserDefaults.standard.set(try? JSONEncoder().encode(kept), forKey: introducedKey(l, level))
    }
}

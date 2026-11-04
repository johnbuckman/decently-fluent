import Foundation
import SwiftData

/// Pages written ahead of time for the most recommended books, so they open ready to read. Each file holds one book
/// learned in one language by speakers of another: the graded text at each level, the side column, the published
/// translation lined up, and the words each level introduced. They are made by `Pregenerator` and kept on the
/// repository's `pages` release.
struct Pregenerated: Codable {
    struct Para: Codable {
        var i: Int
        /// Hash of the paragraph as written, so text from a changed Gutenberg file isn't put against the wrong paragraph.
        var h: String
        var side: String?
        var human: String?
        var r: [String: Rendition]
    }

    var version = 1
    var book: Int
    var language: String
    var native: String
    var targetTranslator: String?
    var sideTranslator: String?
    var introduced: [String: [IntroducedWord]]
    /// By chapter, the paragraphs that have something written.
    var chapters: [[Para]]

    /// Where the files are kept; DF_PAGES_URL points a development build at a local folder instead.
    static let release = ProcessInfo.processInfo.environment["DF_PAGES_URL"]
        ?? "https://github.com/johnbuckman/decently-fluent/releases/download/pages/"

    static func fileName(_ id: Int, learning: Language, native: Language) -> String {
        "\(id)-\(learning.rawValue)-\(native.rawValue).dfpages"
    }

    /// The pages for a book, if any were made (nil when there are none, or they can't be had).
    static func fetch(_ id: Int, learning: Language, native: Language) async -> Pregenerated? {
        guard let url = URL(string: release + fileName(id, learning: learning, native: native)) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("DecentlyFluent/0.1 (graded reader app)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> Pregenerated? {
        guard let json = try? (data as NSData).decompressed(using: .zlib) as Data else { return nil }
        return try? JSONDecoder().decode(Pregenerated.self, from: json)
    }

    func encoded() throws -> Data {
        try (JSONEncoder().encode(self) as NSData).compressed(using: .zlib) as Data
    }

    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 36)
    }

    /// Everything written for `book` so far.
    @MainActor
    init(of book: Book, id: Int) {
        self.book = id
        language = book.language.rawValue
        native = book.native.rawValue
        targetTranslator = book.targetTranslator
        sideTranslator = book.sideTranslator
        introduced = book.introduced
        chapters = book.sortedChapters.map { ch in
            ch.sortedParagraphs.compactMap { p in
                let r = p.renditions
                guard !r.isEmpty || p.sideTranslation != nil || p.humanTarget != nil else { return nil }
                return Para(i: p.index, h: Self.hash(p.source), side: p.sideTranslation, human: p.humanTarget, r: r)
            }
        }
    }

    /// Puts the pages into a book made from the same Gutenberg file. Paragraphs are found by their text, so the
    /// pages still fit if the import has since changed which sections it keeps (front matter, contents pages).
    @MainActor
    func apply(to book: Book) {
        var byHash: [String: [(ci: Int, para: Para)]] = [:]
        for (ci, paras) in chapters.enumerated() { for x in paras { byHash[x.h, default: []].append((ci, x)) } }
        for ch in book.sortedChapters {
            for p in ch.sortedParagraphs {
                guard let found = byHash[Self.hash(p.source)], !found.isEmpty else { continue }
                // a line that comes more than once ("— Oh !"): the one at the same place, else the first
                let x = (found.first { $0.para.i == p.index } ?? found[0]).para
                p.renditions = x.r
                if let side = x.side { p.sideTranslation = side }
                if let human = x.human { p.humanTarget = human }
            }
        }
        book.introduced = introduced
        book.targetTranslator = targetTranslator
        book.sideTranslator = sideTranslator
    }
}

struct ReadyBook: Codable, Hashable, Identifiable {
    var book: Int
    var language: String
    var native: String
    var levels: [String]
    /// About how many words of the book are written.
    var words: Int
    var id: String { "\(book)-\(language)-\(native)" }
    var lang: Language { Language(rawValue: language) ?? .french }
}

@MainActor
@Observable
final class ReadyShelf {
    static let shared = ReadyShelf()
    private(set) var books: [ReadyBook] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: "readyBooks"),
           let saved = try? JSONDecoder().decode([ReadyBook].self, from: data) { books = saved }
    }

    func refresh() async {
        guard let url = URL(string: Pregenerated.release + "index.json") else { return }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("DecentlyFluent/0.1 (graded reader app)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode([ReadyBook].self, from: data) else { return }
        books = list
        UserDefaults.standard.set(data, forKey: "readyBooks")
    }
}

/// Makes the pre-written pages, on a Mac, with the same import, prompts and glossary bookkeeping as reading does.
/// Launched with DF_PREGENERATE=<folder to write to>, plus:
///   DF_PREGEN_LANGS   languages learned (default "fr,de")
///   DF_PREGEN_LEVELS  levels (default "A1,A2,B1")
///   DF_PREGEN_TOP     books per language, taken from the guide's recommendations at those levels (default 10)
///   DF_PREGEN_BOOKS   Gutenberg ids to use instead of the recommendations
///   DF_PREGEN_WORDS   stop after about this many words of each book (default: the whole book)
/// The service and model come from DF_PROVIDER / DF_MODEL and the key from the usual environment variable.
@MainActor
enum Pregenerator {
    static let native = Language.english

    static func run(to folder: URL) async {
        let env = ProcessInfo.processInfo.environment
        let langs = (env["DF_PREGEN_LANGS"] ?? "fr,de").split(separator: ",").compactMap { Language(rawValue: String($0)) }
        let levels = (env["DF_PREGEN_LEVELS"] ?? "A1,A2,B1").split(separator: ",").compactMap { Level(rawValue: String($0)) }
        let top = Int(env["DF_PREGEN_TOP"] ?? "") ?? 10
        let ids = (env["DF_PREGEN_BOOKS"] ?? "").split(separator: ",").compactMap { Int($0) }
        let words = Int(env["DF_PREGEN_WORDS"] ?? "")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        log("model \(LLMSettings.model(LLMSettings.provider)), levels \(levels.map(\.rawValue)), words \(words.map(String.init) ?? "all")", folder)

        await withTaskGroup(of: Void.self) { group in
            for lang in langs {
                let books = ids.isEmpty ? recommended(lang, levels: levels, top: top) : ids.compactMap { Catalog.shared.book(id: $0) }
                log("\(lang.name): \(books.map { "\($0.id) \($0.title)" }.joined(separator: "; "))", folder)
                group.addTask { @MainActor in
                    for b in books { await make(b, learning: lang, levels: levels, words: words, to: folder) }
                }
            }
        }
        log("done: \(LLM.usage.input) tokens in, \(LLM.usage.output) out", folder)
    }

    /// The books the guide recommends most to English speakers learning `lang` at these levels: retold
    /// and originals alike, ranked by how often and how high they come up.
    static func recommended(_ lang: Language, levels: [Level], top: Int) -> [CatalogBook] {
        var score: [Int: Int] = [:], books: [Int: CatalogBook] = [:]
        for level in levels {
            for kind in [BookKind.retold, .original] {
                let profile = ReadingProfile(language: lang, native: native, kind: kind, level: level, interests: [], minutesPerDay: 20)
                // a later volume isn't somewhere to start reading
                let later = /(?i)\b(tome|volume|vol\.|band|teil|book|part)\s+(II|III|IV|V|VI|[2-9])\b/
                let recs = Recommender.recommend(profile, limit: top * 2).filter { $0.book.title.firstMatch(of: later) == nil }
                for (rank, r) in recs.prefix(top).enumerated() {
                    score[r.book.id, default: 0] += top - rank
                    books[r.book.id] = r.book
                }
            }
        }
        return score.sorted { $0.value > $1.value }.prefix(top).compactMap { books[$0.key] }
    }

    static func make(_ catalogBook: CatalogBook, learning lang: Language, levels: [Level], words: Int?, to folder: URL) async {
        let file = folder.appendingPathComponent(Pregenerated.fileName(catalogBook.id, learning: lang, native: native))
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        let name = "\(catalogBook.id) \(catalogBook.title) → \(lang.rawValue)"
        let start = Date(), used = LLM.usage
        do {
            let container = try ModelContainer(for: Book.self, Chapter.self, Paragraph.self, LearnerWord.self,
                                               configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = container.mainContext
            let imported = try await CatalogImport.read(catalogBook)
            let book = await CatalogImport.add(imported, from: catalogBook, learning: lang, native: native, level: levels.first ?? .b1,
                                               usePages: false, in: context) { _ in }
            // carry on from where an earlier run stopped
            let partial = file.appendingPathExtension("partial")
            if let data = try? Data(contentsOf: partial), let earlier = Pregenerated.decode(data) {
                earlier.apply(to: book)
                book.humanTargetEdition = nil
                book.humanSideEdition = nil
                log("\(name): carrying on from the last run", folder)
            } else {
                await Generator().lineUpAll(book, words: words)
            }
            let total = words ?? book.sortedChapters.reduce(0) { $0 + $1.paragraphs.reduce(0) { $0 + $1.source.split(separator: " ").count } }
            log("\(name): \(total) words, \(book.targetTranslator.map { "target by \($0.isEmpty ? "the author" : $0)" } ?? "no human target")", folder)
            await withTaskGroup(of: Void.self) { group in
                for (n, level) in levels.enumerated() {
                    group.addTask { @MainActor in
                        let g = Generator()
                        g.writesSide = n == 0
                        g.batchParagraphs = 40
                        var reported = 0
                        await g.generateAll(book, level: level, words: words) { done in
                            try? Pregenerated(of: book, id: catalogBook.id).encoded().write(to: partial)
                            if done - reported >= 5_000 { reported = done; log("  \(name) \(level.rawValue): \(done)/\(total)", folder) }
                        }
                        if let e = g.lastError { log("  \(name) \(level.rawValue): last error \(e)", folder) }
                    }
                }
            }
            try Pregenerated(of: book, id: catalogBook.id).encoded().write(to: file)
            try? FileManager.default.removeItem(at: partial)
            let (i, o) = (LLM.usage.input - used.input, LLM.usage.output - used.output)
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            writeIndex(folder)
            log("✓ \(name): \(i) in, \(o) out tokens, \(Int(Date().timeIntervalSince(start)))s, \(size / 1024) KB", folder)
        } catch {
            log("✗ \(name): \(error.localizedDescription)", folder)
        }
    }

    /// index.json: every pages file in the folder, in the order they were made (best recommended first).
    static func writeIndex(_ folder: URL) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "dfpages" }
            .sorted { (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast) ?? .distantPast
                    < (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast) ?? .distantPast }
        let list: [ReadyBook] = files.compactMap { url in
            guard let data = try? Data(contentsOf: url), let p = Pregenerated.decode(data) else { return nil }
            let levels = Level.allCases.map(\.rawValue).filter { l in p.chapters.contains { $0.contains { $0.r[l] != nil } } }
            let words = p.chapters.reduce(0) { $0 + $1.reduce(0) { $0 + (($1.r[levels.last ?? ""]?.text.split(separator: " ").count) ?? 0) } }
            return ReadyBook(book: p.book, language: p.language, native: p.native, levels: levels, words: words)
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(list).write(to: folder.appendingPathComponent("index.json"))
    }

    static func log(_ s: String, _ folder: URL) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(s)\n"
        print(line, terminator: "")
        let url = folder.appendingPathComponent("log.txt")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
}

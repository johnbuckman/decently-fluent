import Foundation
import SQLite3

/// A book in the bundled Project Gutenberg catalog (Resources/catalog.sqlite, built by tools/build_catalog.py).
struct CatalogBook: Identifiable, Hashable {
    var id: Int
    var title: String
    var author: String
    var years: String
    var language: String
    var popularity: Int
    var subjects: String
    var categories: [String]
    var words: Int?
    var measured: Bool
    var chapters: Int?
    var wordsPerChapter: Int?
    var sentenceLength: Double?
    var dialogue: Double?
    var archaic: Double?
    var dialect: Double?
    /// Share of running words among the language's 2,000 / 5,000 most common words (names count as known).
    var coverage2k: Double?
    var coverage5k: Double?
    /// Gutenberg names a translator: the text was not written in this language.
    var translated: Bool
    var translator: String

    var gutenberg: GutenbergBook { GutenbergBook(id: id, title: title, author: author) }
    var lang: Language { Language(rawValue: language) ?? .english }
    /// The language this book was first written in, if it is this edition's language.
    var originalLanguage: Language? { translated ? nil : Language(rawValue: language) }
    private static let volumeMark = #"(?i)[\s,.(—-]*\b(vol\.?|volume|tome|tomo|band|teil|parte?|part|livre|libro|book)\s*[0-9ivxlc]+\b"#
    /// One volume or part of a longer work ("Tomo 1 (de 2)", "Part 3.").
    var isVolume: Bool { title.range(of: Self.volumeMark, options: .regularExpression) != nil }
    /// The title before its volume number, to find the other volumes.
    var volumeStem: String {
        let r = title.range(of: Self.volumeMark, options: .regularExpression)
        return String(title[..<(r?.lowerBound ?? title.endIndex)]).lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }
    /// "the original" or "translated by …"
    var editionCredit: String { translated ? (translator.isEmpty ? "translated" : "translated by \(translator)") : "the original" }
}

/// Book groups the catalog tags, from Gutenberg's subjects and bookshelves.
enum Category: String, CaseIterable, Identifiable {
    case short, mystery, adventure, tales, plays, scifi, children, humour, ghost, romance, historical
    var id: String { rawValue }
    var name: String {
        switch self {
        case .short: "Short stories"
        case .mystery: "Mysteries & detectives"
        case .adventure: "Adventure"
        case .tales: "Fairy tales & fables"
        case .plays: "Plays"
        case .scifi: "Science fiction & fantasy"
        case .children: "Children's classics"
        case .humour: "Humour"
        case .ghost: "Ghost stories"
        case .romance: "Love stories"
        case .historical: "Historical fiction"
        }
    }
    var symbol: String {
        switch self {
        case .short: "text.book.closed"
        case .mystery: "magnifyingglass"
        case .adventure: "sailboat"
        case .tales: "sparkles"
        case .plays: "theatermasks"
        case .scifi: "globe.europe.africa"
        case .children: "figure.and.child.holdinghands"
        case .humour: "face.smiling"
        case .ghost: "moon.stars"
        case .romance: "heart"
        case .historical: "building.columns"
        }
    }
}

final class Catalog {
    static let shared = Catalog()
    private var db: OpaquePointer?

    private init() {
        guard let path = Bundle.main.path(forResource: "catalog", ofType: "sqlite") else { return }
        sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        editionIDs = loadEditions()
    }

    private static let columns = """
    id, title, author, years, language, popularity, subjects, categories, words, measured, chapters,
    words_per_chapter, sentence_len, dialogue, archaic, dialect, cov2k, cov5k, translated, translator
    """

    /// Measured books in one language, optionally only those in some categories, or only those written in it.
    /// Which editions a list keeps: any, only books written in their language, or only published translations.
    enum Editions { case any, originals, translations
        var sql: String { switch self { case .any: ""; case .originals: " AND translated = 0"; case .translations: " AND translated = 1" } }
    }

    func measured(language: String, categories: Set<Category> = [], editions: Editions = .any) -> [CatalogBook] {
        var sql = "SELECT \(Self.columns) FROM books WHERE language = ? AND measured = 1"
        sql += editions.sql
        if !categories.isEmpty {
            sql += " AND (" + categories.map { "(',' || categories || ',') LIKE '%,\($0.rawValue),%'" }.joined(separator: " OR ") + ")"
        }
        return query(sql, [language])
    }

    /// The most popular books of one group, measured or not.
    func shelf(_ category: Category, language: String, editions: Editions = .any, limit: Int = 60) -> [CatalogBook] {
        query("SELECT \(Self.columns) FROM books WHERE language = ? AND (',' || categories || ',') LIKE ?"
              + editions.sql + " ORDER BY popularity DESC LIMIT ?",
              [language, "%,\(category.rawValue),%", limit])
    }

    /// Title and author search, most popular first.
    func search(_ text: String, languages: [String], limit: Int = 60) -> [CatalogBook] {
        let terms = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { "\"\($0)\"*" }.joined(separator: " ")
        guard !terms.isEmpty else { return [] }
        let langs = languages.map { _ in "?" }.joined(separator: ",")
        return query("""
            SELECT \(Self.columns.split(separator: ",").map { "books." + $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: ", "))
            FROM books JOIN books_fts ON books.id = books_fts.rowid
            WHERE books_fts MATCH ? AND books.language IN (\(langs)) ORDER BY books.popularity DESC LIMIT ?
            """, [terms] + languages + [limit])
    }

    /// The same work in other languages: the original and published human translations.
    func editions(of id: Int) -> [CatalogBook] {
        guard let ids = editionIDs[id] else { return [] }
        return ids.compactMap { book(id: $0) }
    }

    /// Book id -> ids of the same work in other languages (a few thousand rows), loaded when the catalog opens.
    private var editionIDs: [Int: [Int]] = [:]

    private func loadEditions() -> [Int: [Int]] {
        var byWork: [Int: [Int]] = [:]
        guard let db else { return [:] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, work FROM editions", -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            byWork[Int(sqlite3_column_int64(stmt, 1)), default: []].append(Int(sqlite3_column_int64(stmt, 0)))
        }
        var out: [Int: [Int]] = [:]
        for ids in byWork.values { for i in ids { out[i] = ids.filter { $0 != i } } }
        return out
    }

    /// Languages this book has another edition in, with the edition to use for each: the original
    /// if there is one, then a complete edition over a single volume, then the longest.
    func bestEditions(of id: Int) -> [Language: CatalogBook] {
        var out: [Language: CatalogBook] = [:]
        func rank(_ e: CatalogBook) -> (Int, Int, Int) { (e.translated ? 0 : 1, e.isVolume ? 0 : 1, e.words ?? 0) }
        for e in editions(of: id) {
            if let cur = out[e.lang], rank(cur) >= rank(e) { continue }
            out[e.lang] = e
        }
        return out
    }

    /// The edition to use in one language, as a list: all its volumes, in order, when it comes in volumes.
    func volumes(of id: Int, in lang: Language) -> [CatalogBook] {
        guard let best = bestEditions(of: id)[lang] else { return [] }
        guard best.isVolume else { return [best] }
        let stem = best.volumeStem
        return editions(of: id)
            .filter { $0.lang == lang && $0.isVolume && $0.volumeStem == stem && $0.translator == best.translator }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func book(id: Int) -> CatalogBook? { query("SELECT \(Self.columns) FROM books WHERE id = ?", [id]).first }

    private func query(_ sql: String, _ args: [Any]) -> [CatalogBook] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            if let s = a as? String { sqlite3_bind_text(stmt, Int32(i + 1), s, -1, transient) }
            else if let n = a as? Int { sqlite3_bind_int64(stmt, Int32(i + 1), Int64(n)) }
        }
        var out: [CatalogBook] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ c: Int32) -> String { sqlite3_column_text(stmt, c).map { String(cString: $0) } ?? "" }
            func int(_ c: Int32) -> Int? { sqlite3_column_type(stmt, c) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, c)) }
            func dbl(_ c: Int32) -> Double? { sqlite3_column_type(stmt, c) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, c) }
            out.append(CatalogBook(
                id: int(0) ?? 0, title: text(1), author: text(2), years: text(3), language: text(4),
                popularity: int(5) ?? 0, subjects: text(6),
                categories: text(7).split(separator: ",").map(String.init),
                words: int(8), measured: int(9) == 1, chapters: int(10), wordsPerChapter: int(11),
                sentenceLength: dbl(12), dialogue: dbl(13), archaic: dbl(14), dialect: dbl(15),
                coverage2k: dbl(16), coverage5k: dbl(17), translated: int(18) == 1, translator: text(19)))
        }
        return out
    }
}

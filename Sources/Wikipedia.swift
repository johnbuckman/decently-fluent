import Foundation

/// A book's Wikipedia article: its plot summary (or, without one, its opening) and a link to the page.
struct WikipediaArticle: Equatable {
    var title: String
    /// The plot section, or the article's lead when it has none.
    var summary: String
    var isPlot: Bool
    var url: URL
    var language: Language
}

/// Finds a book's article on Wikipedia, in the reader's own language when it has one, otherwise in English
/// or the book's language. Uses Wikipedia's public API (no key); results are kept for the session.
@MainActor
enum Wikipedia {
    private static var cache: [String: WikipediaArticle?] = [:]

    static func article(for book: CatalogBook, in native: Language) async -> WikipediaArticle? {
        let key = "\(book.id)|\(native.rawValue)"
        if let hit = cache[key] { return hit }
        var found: WikipediaArticle?
        for lang in [native, .english, book.lang].uniqued() {
            if let a = await search(book, lang) { found = a; break }
        }
        cache[key] = found
        return found
    }

    static let otherWork = /(?i)\((\d{4} )?(film|tv series|television series|miniseries|series|comics?|comic book|musical|opera|album|song|video game|band|serial|téléfilm|fernsehserie|película|serie|fumetto)\)/

    /// Headings of the plot section, by Wikipedia language.
    private static let plotHeadings: [Language: [String]] = [
        .english: ["Plot", "Plot summary", "Synopsis", "Summary", "Story"],
        .french: ["Résumé", "Intrigue", "Synopsis", "Histoire"],
        .german: ["Handlung", "Inhalt", "Zusammenfassung"],
        .spanish: ["Argumento", "Sinopsis", "Trama", "Resumen"],
        .italian: ["Trama", "Sinossi", "Riassunto"],
    ]

    private static func search(_ book: CatalogBook, _ lang: Language) async -> WikipediaArticle? {
        // the title before any subtitle, and the author's surname
        let title = book.title.components(separatedBy: CharacterSet(charactersIn: ":;—")).first?
            .trimmingCharacters(in: .whitespaces) ?? book.title
        let surname = book.author.components(separatedBy: " & ").first?.split(separator: " ").last.map(String.init) ?? ""
        guard let hits: SearchAnswer = await get(lang, ["action": "query", "list": "search", "srlimit": "3",
                                                        "srsearch": "\(title) \(surname)"]) else { return nil }
        for hit in hits.query.search {
            // the article must be about this book: its title shares a word with the book's, and it names the author
            let words = Set(title.lowercased().split(separator: " ").map(String.init).filter { $0.count > 3 })
            let hitWords = Set(hit.title.lowercased().split(separator: " ").map(String.init))
            guard words.isEmpty || !words.isDisjoint(with: hitWords) || hit.title.lowercased().contains(title.lowercased()) else { continue }
            // not a film, series or comic of the same name ("Pride and Prejudice (2026 TV series)")
            if hit.title.firstMatch(of: Self.otherWork) != nil { continue }
            guard let page: ExtractAnswer = await get(lang, ["action": "query", "prop": "extracts", "explaintext": "1",
                                                             "redirects": "1", "titles": hit.title]),
                  let text = page.query.pages.values.first?.extract, !text.isEmpty,
                  surname.isEmpty || text.contains(surname) else { continue }
            let url = URL(string: "https://\(lang.rawValue).wikipedia.org/wiki/\(hit.title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")")!
            if let plot = section(text, plotHeadings[lang] ?? []) {
                return WikipediaArticle(title: hit.title, summary: plot, isPlot: true, url: url, language: lang)
            }
            let lead = text.components(separatedBy: "\n\n\n").first ?? text
            return WikipediaArticle(title: hit.title, summary: shorten(lead), isPlot: false, url: url, language: lang)
        }
        return nil
    }

    /// The text under the first heading in `names` ("== Plot =="), up to the next heading of the same level.
    static func section(_ text: String, _ names: [String]) -> String? {
        let lines = text.components(separatedBy: "\n")
        for name in names {
            guard let start = lines.firstIndex(where: {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("==") && !t.hasPrefix("===") && t.trimmingCharacters(in: CharacterSet(charactersIn: "= ")).caseInsensitiveCompare(name) == .orderedSame
            }) else { continue }
            var body: [String] = []
            for line in lines[(start + 1)...] {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("==") && !t.hasPrefix("===") { break }
                if t.hasPrefix("===") { continue }  // subheadings: keep their text, not the heading
                body.append(line)
            }
            let s = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count > 80 { return shorten(s) }
        }
        return nil
    }

    /// At most about 1,500 characters, ending at a sentence.
    private static func shorten(_ s: String, limit: Int = 1_500) -> String {
        let paragraphs = s.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var out = ""
        for p in paragraphs {
            if out.count + p.count > limit {
                if out.isEmpty, let cut = p.prefix(limit).lastIndex(of: ".") { out = String(p[...cut]) }
                break
            }
            out += (out.isEmpty ? "" : "\n\n") + p
        }
        return out.isEmpty ? String(s.prefix(limit)) : out
    }

    private struct SearchAnswer: Decodable {
        struct Query: Decodable { var search: [Hit] }
        struct Hit: Decodable { var title: String }
        var query: Query
    }

    private struct ExtractAnswer: Decodable {
        struct Query: Decodable { var pages: [String: Page] }
        struct Page: Decodable { var extract: String? }
        var query: Query
    }

    private static func get<T: Decodable>(_ lang: Language, _ params: [String: String]) async -> T? {
        var c = URLComponents(string: "https://\(lang.rawValue).wikipedia.org/w/api.php")!
        c.queryItems = (params.merging(["format": "json", "formatversion": "1"]) { a, _ in a }).map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: c.url!, timeoutInterval: 20)
        // Wikipedia asks API clients to identify themselves
        req.setValue("DecentlyFluent/0.1 (graded reader app; https://decentespresso.com)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}

import Foundation

/// A Project Gutenberg book to download.
struct GutenbergBook: Identifiable, Hashable {
    var id: Int
    var title: String
    var author: String

    var epubURL: URL { URL(string: "https://www.gutenberg.org/ebooks/\(id).epub.noimages")! }
    var pageURL: URL { URL(string: "https://www.gutenberg.org/ebooks/\(id)")! }
}

/// Book files come straight from gutenberg.org; what's on offer comes from the bundled catalog (Catalog.swift).
enum Gutenberg {
    /// Downloads a book's EPUB to a temporary file.
    static func download(_ book: GutenbergBook) async throws -> URL {
        var req = URLRequest(url: book.epubURL, timeoutInterval: 60)
        req.setValue("DecentlyFluent/0.1 (graded reader app)", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pg\(book.id).epub")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Gutenberg books wrap the text in licence pages, marked "*** START OF THE PROJECT GUTENBERG EBOOK … ***"
    /// and "*** END OF … ***". Keep what lies between (the start can share a file with the first chapter),
    /// and leave out a table of contents.
    static func dropGutenbergMatter(_ chapters: [(title: String, paragraphs: [String])]) -> [(title: String, paragraphs: [String])] {
        var out = chapters
        func marks(_ p: String, _ word: String) -> Bool {
            let u = p.uppercased()
            return u.contains("*** \(word) OF") || u.contains("***\(word) OF") || u.hasPrefix("\(word) OF THE PROJECT GUTENBERG")
        }
        if let ci = out.firstIndex(where: { $0.paragraphs.contains { marks($0, "START") } }),
           let pi = out[ci].paragraphs.firstIndex(where: { marks($0, "START") }) {
            out[ci].paragraphs.removeFirst(pi + 1)
            out.removeFirst(ci)
        }
        if let ci = out.firstIndex(where: { $0.paragraphs.contains { marks($0, "END") } }),
           let pi = out[ci].paragraphs.firstIndex(where: { marks($0, "END") }) {
            out[ci].paragraphs.removeLast(out[ci].paragraphs.count - pi)
            out.removeLast(out.count - ci - 1)
        }
        let contents = ["contents", "table of contents", "table des matières", "inhalt", "inhaltsverzeichnis", "índice", "indice"]
        out = out.filter { ch in
            let t = ch.title.lowercased()
            // "The Strange Case Of Dr. Jekyll…: Contents" is a contents page too
            let last = t.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespaces) ?? t
            return !ch.paragraphs.isEmpty && !contents.contains(last) && !t.contains("project gutenberg")
        }
        // publisher's notes, printing details and contents lists before the story begins
        while let first = out.first, out.count > 1, isFrontMatter(first) { out.removeFirst() }
        // …and the same lines at the head of the first section ("Verlagslogo", "1920", "MÜNCHEN ROLAND-VERLAG", "by Agatha Christie")
        if !out.isEmpty {
            while let p = out[0].paragraphs.first, out[0].paragraphs.count > 1, isFrontMatterLine(p) { out[0].paragraphs.removeFirst() }
        }
        return out
    }

    static func isFrontMatterLine(_ p: String) -> Bool {
        guard p.split(separator: " ").count <= 6 else { return false }
        let letters = p.filter(\.isLetter)
        return p.firstMatch(of: frontMatterWords) != nil || p.lowercased().contains("logo")
            || p.allSatisfy { $0.isNumber || $0.isWhitespace || $0.isPunctuation }
            || (letters.count > 3 && letters == letters.uppercased())
            || p.firstMatch(of: /^(by|par|von|di|de) [A-ZÀ-Ý]/) != nil
    }

    static let frontMatterWords = /(?i)\b(copyright|all rights reserved|diritti|editori|stampato|tipografia|verlag|druck|tausend|kapitelfolge|inhalt|indice|índice|imprimerie|éditeur|droits|table des matières|contents|printed by|publishers?)\b/

    /// A short section of front matter: under 400 words, and either naming printing, publishing or contents,
    /// or made of list-like lines.
    static func isFrontMatter(_ ch: (title: String, paragraphs: [String])) -> Bool {
        let counts = ch.paragraphs.map { $0.split(separator: " ").count }
        let words = counts.reduce(0, +)
        guard words < 400 else { return false }
        let listLike = Double(words) / Double(max(counts.count, 1)) < 8 && counts.count >= 3
        return listLike || ([ch.title] + ch.paragraphs).contains { $0.firstMatch(of: frontMatterWords) != nil }
    }
}

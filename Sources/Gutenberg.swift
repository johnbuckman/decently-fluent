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
        return out.filter { ch in
            let t = ch.title.lowercased()
            // "The Strange Case Of Dr. Jekyll…: Contents" is a contents page too
            let last = t.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespaces) ?? t
            return !ch.paragraphs.isEmpty && !contents.contains(last) && !t.contains("project gutenberg")
        }
    }
}

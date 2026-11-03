import Foundation
import Compression
import PDFKit

/// A book read from a file, before it is stored.
struct ImportedBook {
    var title: String
    var author: String
    var chapters: [(title: String, paragraphs: [String])]
}

enum ImportError: LocalizedError {
    case unsupported(String), badEPUB(String), empty
    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): "Can't read .\(ext) files yet (EPUB, PDF and plain text work)."
        case .badEPUB(let why): "This EPUB couldn't be read: \(why). DRM-protected books can't be opened."
        case .empty: "No readable text was found in this file."
        }
    }
}

enum Importer {
    static func read(url: URL) throws -> ImportedBook {
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent
        let book: ImportedBook
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        switch ext {
        // Apple Books keeps EPUBs unpacked, as folders
        case "epub" where isDir.boolValue: book = try EPUB.read(source: FolderSource(root: url), fallbackTitle: name)
        case "epub": book = try EPUB.read(data: Data(contentsOf: url), fallbackTitle: name)
        case "txt", "text", "md": book = PlainText.read(text: try readText(url), title: name)
        case "pdf": book = try readPDF(url: url, title: name)
        default: throw ImportError.unsupported(ext)
        }
        guard book.chapters.contains(where: { !$0.paragraphs.isEmpty }) else { throw ImportError.empty }
        return book
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func readPDF(url: URL, title: String) throws -> ImportedBook {
        guard let doc = PDFDocument(url: url) else { throw ImportError.empty }
        var text = ""
        for i in 0..<doc.pageCount { text += (doc.page(at: i)?.string ?? "") + "\n\n" }
        // rejoin words hyphenated across line ends
        text = text.replacingOccurrences(of: "-\n", with: "")
        let docTitle = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        var book = PlainText.read(text: text, title: (docTitle?.isEmpty == false ? docTitle! : title))
        book.author = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String ?? ""
        return book
    }
}

// MARK: - Plain text

enum PlainText {
    static let chapterLine = try! NSRegularExpression(
        pattern: #"^\s*(chapter|part|book|prologue|epilogue)\b.{0,60}$"#, options: [.caseInsensitive])

    static func read(text: String, title: String) -> ImportedBook {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // blank lines separate paragraphs; if a text has none, every line is a paragraph
        let blocks: [String]
        if normalized.range(of: #"\n\s*\n"#, options: .regularExpression) != nil {
            blocks = normalized.components(separatedBy: #"\n\s*\n"#, regex: true)
        } else {
            blocks = normalized.components(separatedBy: "\n")
        }
        let paragraphs = blocks
            .map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chapters: [(title: String, paragraphs: [String])] = []
        for p in paragraphs {
            let range = NSRange(p.startIndex..., in: p)
            if p.count < 80, chapterLine.firstMatch(in: p, range: range) != nil {
                chapters.append((p, []))
            } else {
                if chapters.isEmpty { chapters.append(("Beginning", [])) }
                chapters[chapters.count - 1].paragraphs.append(p)
            }
        }
        chapters.removeAll { $0.paragraphs.isEmpty }
        // no chapter headings: cut into sections of 30 paragraphs
        if chapters.count <= 1, paragraphs.count > 40 {
            chapters = stride(from: 0, to: paragraphs.count, by: 30).enumerated().map { i, start in
                ("Part \(i + 1)", Array(paragraphs[start..<min(start + 30, paragraphs.count)]))
            }
        }
        return ImportedBook(title: title, author: "", chapters: chapters)
    }
}

extension String {
    func components(separatedBy pattern: String, regex: Bool) -> [String] {
        guard regex, let re = try? NSRegularExpression(pattern: pattern) else { return components(separatedBy: pattern) }
        var parts: [String] = []
        var last = startIndex
        for m in re.matches(in: self, range: NSRange(startIndex..., in: self)) {
            guard let r = Range(m.range, in: self) else { continue }
            parts.append(String(self[last..<r.lowerBound]))
            last = r.upperBound
        }
        parts.append(String(self[last...]))
        return parts
    }
}

// MARK: - EPUB

/// Where an EPUB's files come from: its zip file, or a folder.
protocol EPUBSource {
    func read(_ path: String) throws -> Data
    func contains(_ path: String) -> Bool
}

extension EPUBSource {
    func text(_ path: String) throws -> String { String(decoding: try read(path), as: UTF8.self) }
}

struct FolderSource: EPUBSource {
    let root: URL
    func read(_ path: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(path)) }
    func contains(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }
}

enum EPUB {
    static func read(data: Data, fallbackTitle: String) throws -> ImportedBook {
        let zip: ZipArchive
        do { zip = try ZipArchive(data: data) } catch { throw ImportError.badEPUB("not a zip file") }
        return try read(source: zip, fallbackTitle: fallbackTitle)
    }

    static func read(source zip: EPUBSource, fallbackTitle: String) throws -> ImportedBook {
        guard let container = try? zip.text("META-INF/container.xml"),
              let opfPath = container.firstMatch(of: /full-path\s*=\s*"([^"]+)"/)?.1 else {
            throw ImportError.badEPUB("no container.xml")
        }
        let opfData = try zip.read(String(opfPath))
        let opf = OPFParser(); let parser = XMLParser(data: opfData); parser.delegate = opf
        guard parser.parse() else { throw ImportError.badEPUB("unreadable package file") }
        if zip.contains("META-INF/encryption.xml") && opf.spine.isEmpty { throw ImportError.badEPUB("encrypted") }

        let base = (String(opfPath) as NSString).deletingLastPathComponent
        var chapters: [(title: String, paragraphs: [String])] = []
        for idref in opf.spine {
            guard let item = opf.manifest[idref], item.mediaType.contains("html") else { continue }
            let href = item.href.removingPercentEncoding ?? item.href
            let path = base.isEmpty ? href : (base as NSString).appendingPathComponent(href)
            guard let xhtml = try? zip.read(normalize(path)) else { continue }
            // one file can hold several chapters: each heading starts a new one
            for (heading, paragraphs) in XHTMLText.extract(xhtml) where !paragraphs.isEmpty {
                var title = heading ?? "Chapter \(chapters.count + 1)"
                if title.allSatisfy(\.isNumber) { title = "Chapter \(title)" }
                chapters.append((title, paragraphs))
            }
        }
        return ImportedBook(title: opf.title.isEmpty ? fallbackTitle : opf.title, author: opf.creator, chapters: chapters)
    }

    /// Resolves "a/b/../c" path segments inside the archive.
    static func normalize(_ path: String) -> String {
        var out: [Substring] = []
        for part in path.split(separator: "/") {
            if part == ".." { _ = out.popLast() } else if part != "." { out.append(part) }
        }
        return out.joined(separator: "/")
    }
}

final class OPFParser: NSObject, XMLParserDelegate {
    struct Item { var href: String; var mediaType: String }
    var manifest: [String: Item] = [:]
    var spine: [String] = []
    var title = "", creator = ""
    private var text = "", inTitle = false, inCreator = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        switch local {
        case "item": if let id = a["id"], let href = a["href"] { manifest[id] = Item(href: href, mediaType: a["media-type"] ?? "") }
        case "itemref": if let id = a["idref"], a["linear"] != "no" { spine.append(id) }
        case "title": inTitle = title.isEmpty; text = ""
        case "creator": inCreator = creator.isEmpty; text = ""
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inTitle || inCreator { text += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        if local == "title", inTitle { title = text.trimmingCharacters(in: .whitespacesAndNewlines); inTitle = false }
        if local == "creator", inCreator { creator = text.trimmingCharacters(in: .whitespacesAndNewlines); inCreator = false }
    }
}

/// Pulls the paragraphs out of one XHTML file, split into sections at its headings.
final class XHTMLText: NSObject, XMLParserDelegate {
    static let blocks: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "div", "dd", "dt", "pre", "td"]
    static let skipped: Set<String> = ["script", "style", "head", "title"]

    var sections: [(heading: String?, paragraphs: [String])] = [(nil, [])]
    private var buffer = ""
    private var skipDepth = 0
    private var headingOpen = false

    static func extract(_ data: Data) -> [(heading: String?, paragraphs: [String])] {
        var s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        // HTML named entities aren't defined in XML; turn the common ones into characters
        for (entity, char) in entities { s = s.replacingOccurrences(of: "&\(entity);", with: char) }
        s = s.replacingOccurrences(of: #"<!DOCTYPE[^>]*>"#, with: "", options: .regularExpression)
        let x = XHTMLText()
        let parser = XMLParser(data: Data(s.utf8)); parser.delegate = x
        if parser.parse() { x.flush(); return x.sections }
        return [(nil, fallback(s))]
    }

    /// For files that aren't well-formed XML: split on paragraph ends and strip the tags.
    static func fallback(_ html: String) -> [String] {
        var s = html.replacingOccurrences(of: #"(?s)<(script|style|head)\b.*?</\1>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</(p|div|h[1-6]|li|blockquote)>|<br\s*/?>"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, char) in [("amp", "&"), ("lt", "<"), ("gt", ">"), ("quot", "\""), ("apos", "'")] {
            s = s.replacingOccurrences(of: "&\(entity);", with: char)
        }
        return s.components(separatedBy: #"\n\s*\n"#, regex: true)
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func flush() {
        let t = buffer.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if !t.isEmpty {
            let last = sections.count - 1
            if !headingOpen {
                sections[last].paragraphs.append(t)
            } else if !sections[last].paragraphs.isEmpty {
                sections.append((t, []))
            } else {
                // "CHAPTER I" followed by "The Storm" make one title
                sections[last].heading = sections[last].heading.map { "\($0): \(t)" } ?? t
            }
        }
        buffer = ""
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let local = name.lowercased().split(separator: ":").last.map(String.init) ?? name
        if Self.skipped.contains(local) { skipDepth += 1; return }
        if Self.blocks.contains(local) { flush(); headingOpen = ["h1", "h2", "h3", "h4"].contains(local) }
        if local == "br" { buffer += " " }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if skipDepth == 0 { buffer += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let local = name.lowercased().split(separator: ":").last.map(String.init) ?? name
        if Self.skipped.contains(local) { skipDepth = max(0, skipDepth - 1); return }
        if Self.blocks.contains(local) { flush(); headingOpen = false }
    }

    static let entities: [(String, String)] = [
        ("nbsp", "\u{00A0}"), ("mdash", "—"), ("ndash", "–"), ("hellip", "…"), ("lsquo", "‘"), ("rsquo", "’"),
        ("ldquo", "“"), ("rdquo", "”"), ("laquo", "«"), ("raquo", "»"), ("copy", "©"), ("eacute", "é"),
        ("egrave", "è"), ("ecirc", "ê"), ("agrave", "à"), ("acirc", "â"), ("ccedil", "ç"), ("ocirc", "ô"),
        ("uuml", "ü"), ("ouml", "ö"), ("auml", "ä"), ("szlig", "ß"), ("Eacute", "É"), ("thinsp", "\u{2009}"),
        ("shy", ""), ("zwnj", ""), ("trade", "™"), ("bull", "•"), ("middot", "·"),
    ]
}

// MARK: - Minimal ZIP reader (stored and deflated entries — all an EPUB uses)

struct ZipArchive: EPUBSource {
    struct Entry { var method: UInt16; var compressedSize: Int; var size: Int; var localOffset: Int }
    enum ZipError: Error { case notZip, missing(String), corrupt }

    private let bytes: [UInt8]
    private(set) var entries: [String: Entry] = [:]

    init(data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count > 22 else { throw ZipError.notZip }
        // the end-of-central-directory record is within the last 64 KB
        var eocd = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 65_557) {
            if u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = Int(u16(eocd + 10))
        var p = Int(u32(eocd + 16))
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x02014b50 else { throw ZipError.corrupt }
            let nameLen = Int(u16(p + 28)), extraLen = Int(u16(p + 30)), commentLen = Int(u16(p + 32))
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            entries[name] = Entry(method: u16(p + 10), compressedSize: Int(u32(p + 20)),
                                  size: Int(u32(p + 24)), localOffset: Int(u32(p + 42)))
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    func read(_ name: String) throws -> Data {
        guard let e = entries[name] ?? entries.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value else {
            throw ZipError.missing(name)
        }
        let h = e.localOffset
        guard h + 30 <= bytes.count, u32(h) == 0x04034b50 else { throw ZipError.corrupt }
        let start = h + 30 + Int(u16(h + 26)) + Int(u16(h + 28))
        guard start + e.compressedSize <= bytes.count else { throw ZipError.corrupt }
        let raw = bytes[start..<(start + e.compressedSize)]
        switch e.method {
        case 0: return Data(raw)
        case 8:
            guard e.size > 0 else { return Data() }
            var out = [UInt8](repeating: 0, count: e.size)
            let n = raw.withContiguousStorageIfAvailable { src in
                compression_decode_buffer(&out, e.size, src.baseAddress!, e.compressedSize, nil, COMPRESSION_ZLIB)
            } ?? 0
            guard n > 0 else { throw ZipError.corrupt }
            return Data(out.prefix(n))
        default: throw ZipError.corrupt
        }
    }

    private func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
    private func u32(_ i: Int) -> UInt32 {
        UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
    }
}

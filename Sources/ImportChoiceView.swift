import SwiftUI
import NaturalLanguage

extension ImportedBook: Identifiable {
    var id: String { title + author + "\(chapters.count)" }

    /// The language the book is written in, from a sample of its text.
    var detectedLanguage: Language? {
        // from the middle of the book: front and back matter is often in another language
        let middle = chapters.dropFirst(chapters.count / 3).flatMap(\.paragraphs)
        let sample = middle.joined(separator: " ").prefix(6_000)
        let r = NLLanguageRecognizer()
        r.languageConstraints = Language.allCases.map(\.nl)
        r.processString(String(sample))
        return r.dominantLanguage.flatMap { d in Language.allCases.first { $0.nl == d } }
    }
}

/// Asked for every book that arrives from Files, another app or AirDrop: how to read it.
struct ImportChoiceView: View {
    let imported: ImportedBook
    /// The language to learn, the language the book is in, the reader's own language.
    let onChoose: (Language, Language, Language) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var native = Language.mine

    var body: some View {
        let detected = imported.detectedLanguage
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(imported.title).font(.title3.weight(.semibold))
                        if !imported.author.isEmpty { Text(imported.author).foregroundStyle(.secondary) }
                        Text("\(imported.chapters.count) chapter\(imported.chapters.count == 1 ? "" : "s") · written in \(detected?.name ?? "an unknown language")")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Picker("Your language", selection: $native) {
                        ForEach(Language.allCases) { Text($0.name).tag($0) }
                    }
                }
                if let detected, detected != native {
                    Section {
                        choice("Read the \(detected.name) original", "The author's own words, simplified to your level. The \(native.name) side is a translation.", "text.book.closed") {
                            choose(detected, detected)
                        }
                    } footer: {
                        Text("Authentic text: real \(detected.name) as native speakers write it.")
                    }
                }
                Section {
                    ForEach(Language.allCases.filter { $0 != native && $0 != detected }) { lang in
                        choice("Read it in \(lang.name)", detected == native
                               ? "Retold in \(lang.name) at your level, with the \(native.name) original beside it."
                               : "Retold in \(lang.name) at your level, with a \(native.name) translation beside it.", "globe") {
                            choose(lang, detected ?? .english)
                        }
                    }
                } header: {
                    Text(detected == nil || detected == native ? "Read it in" : "Or")
                }
            }
            .navigationTitle("New book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func choose(_ lang: Language, _ source: Language) {
        Language.mine = native
        onChoose(lang, source, native)
    }

    private func choice(_ title: String, _ detail: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: symbol) }
        }
    }
}

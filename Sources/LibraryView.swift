import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@main
struct DecentlyFluentApp: App {
    var body: some Scene {
        WindowGroup { LibraryView() }
            .modelContainer(for: [Book.self, Chapter.self, Paragraph.self, LearnerWord.self])
    }
}

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Book.createdAt, order: .reverse) private var books: [Book]
    @State private var showImporter = false
    @State private var pendingImport: ImportedBook?
    @State private var showSettings = false
    @State private var showWords = false
    @State private var showDiscover = false
    @State private var error: String?
    @State private var path: [Book] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button { showDiscover = true } label: {
                        Label("Find a book for me…", systemImage: "sparkle.magnifyingglass")
                    }
                    Button { showImporter = true } label: {
                        Label("Open a book on this device…", systemImage: "folder")
                    }
                    if books.isEmpty {
                        Button { addSample() } label: { Label("Add the sample story", systemImage: "text.book.closed") }
                    }
                } footer: {
                    if books.isEmpty {
                        Text("Find a free classic, or open an EPUB, PDF or text file. Read it in English, French, German, Spanish or Italian — retold at your level, or the original simplified.")
                    }
                }
                Section(books.isEmpty ? "" : "Your books") {
                    ForEach(books) { book in
                    NavigationLink(value: book) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title).font(.headline)
                            Text([book.author, "\(book.language.name)\(book.isOriginal ? " original" : "") · \(book.level.label(original: book.isOriginal))", "\(book.chapters.count) chapters"]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                    .onDelete { idx in
                        for i in idx { context.delete(books[i]) }
                        try? context.save()
                    }
                }
            }
            .navigationTitle("Decently Fluent")
            .navigationDestination(for: Book.self) { ReaderView(book: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack {
                        Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                        Button { showWords = true } label: { Label("My words", systemImage: "character.book.closed") }
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.epub, .pdf, .plainText, .text]) { result in
                if case .success(let url) = result { importBook(url) }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showWords) { MyWordsView() }
            .fullScreenCover(isPresented: $showDiscover) { DiscoverView { path = [$0] } }
            .sheet(item: $pendingImport) { imported in
                ImportChoiceView(imported: imported) { lang, source, native in
                    pendingImport = nil
                    path = [BookStore.store(imported, language: lang, source: source, native: native, in: context)]
                }
            }
            // books shared from another app, opened from Files, or received by AirDrop
            .onOpenURL { importBook($0) }
            #if DEBUG
            // simulator testing of that path: SIMCTL_CHILD_DF_OPEN_FILE=/path/to/book.epub
            .task {
                if let path = ProcessInfo.processInfo.environment["DF_OPEN_FILE"] { importBook(URL(fileURLWithPath: path)) }
            }
            #endif
            .alert("Couldn't import", isPresented: .constant(error != nil), presenting: error) { _ in
                Button("OK") { error = nil }
            } message: { Text($0) }
        }
    }

    private func importBook(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            var book = try Importer.read(url: url)
            book.chapters = Gutenberg.dropGutenbergMatter(book.chapters)
            pendingImport = book
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func addSample() {
        var sample = PlainText.read(text: SampleStory.text, title: SampleStory.title)
        sample.author = SampleStory.author
        let native = Language.mine
        path = [BookStore.store(sample, language: native == .french ? .english : .french, source: .english, native: native, in: context)]
    }
}

enum BookStore {
    /// Saves an imported book; it starts at B1.
    @MainActor @discardableResult
    static func store(_ imported: ImportedBook, language: Language, source: Language, native: Language, in context: ModelContext) -> Book {
        let book = Book(title: imported.title, author: imported.author, language: language, source: source, native: native, level: .b1)
        context.insert(book)
        for (ci, ch) in imported.chapters.enumerated() {
            let chapter = Chapter(index: ci, title: ch.title)
            chapter.book = book
            context.insert(chapter)
            for (pi, text) in ch.paragraphs.enumerated() {
                let p = Paragraph(index: pi, source: text)
                p.chapter = chapter
                context.insert(p)
            }
        }
        try? context.save()
        return book
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider = LLMSettings.provider
    @State private var model = ""
    @State private var key = ""
    @State private var hasKey = false
    @AppStorage("nativeLanguage") private var native = Language.english.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Your language", selection: $native) {
                        ForEach(Language.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                } footer: {
                    Text("Word meanings and the side column are in this language, for books you add from now on.")
                }
                Section {
                    Picker("Service", selection: $provider) {
                        ForEach(Provider.choices) { Text($0.name).tag($0) }
                    }
                    TextField(provider == .bridge ? "Bridge address" : "Model", text: $model, prompt: Text(provider.defaultModel))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if provider.needsKey {
                        SecureField(hasKey ? "Key saved — type to replace" : provider.keyHint, text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: {
                    Text("Translation")
                } footer: {
                    Text("Only the next few pages are rewritten, as you read, so changing your level costs nothing and no credits go on pages you never reach. Each level is kept once made. Your key is stored in the iOS Keychain on this device.")
                }
            }
            .navigationTitle("Settings")
            .onAppear(perform: load)
            .onChange(of: provider) { _, _ in load() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        LLMSettings.provider = provider
                        LLMSettings.setModel(model, for: provider)
                        if !key.isEmpty { LLMSettings.setAPIKey(key, for: provider) }
                        dismiss()
                    }
                }
            }
        }
    }

    private func load() {
        model = LLMSettings.model(provider) == provider.defaultModel ? "" : LLMSettings.model(provider)
        hasKey = LLMSettings.apiKey(provider) != nil
        key = ""
    }
}

struct MyWordsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \LearnerWord.lastTap, order: .reverse) private var words: [LearnerWord]

    var body: some View {
        NavigationStack {
            List {
                if words.isEmpty {
                    ContentUnavailableView("No words yet", systemImage: "hand.tap",
                                           description: Text("Double-tap a word you don't know while reading. It shows the meaning, and the app weaves the word back into later pages until you stop tapping it."))
                }
                ForEach(Language.allCases) { lang in
                    let learning = words.filter { $0.languageRaw == lang.rawValue && !$0.known }
                    let known = words.filter { $0.languageRaw == lang.rawValue && $0.known }
                    if !learning.isEmpty {
                        Section("\(lang.name) — learning") {
                            ForEach(learning) { row($0) }
                        }
                    }
                    if !known.isEmpty {
                        Section("\(lang.name) — learned") {
                            ForEach(known) { row($0) }
                        }
                    }
                }
            }
            .navigationTitle("My words")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func row(_ w: LearnerWord) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(w.lemma).font(.body.weight(.semibold))
                Text(w.meaning).foregroundStyle(.secondary)
            }
            Spacer()
            Text(w.known ? "learned" : "seen \(w.cleanSightings)/\(LearnerWord.sightingsToKnow)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .swipeActions {
            Button(w.known ? "Still learning" : "I know it") {
                w.known.toggle()
                if !w.known { w.cleanSightings = 0; w.cleanDays = [] }
                try? context.save()
            }
            .tint(w.known ? .orange : .green)
        }
    }
}

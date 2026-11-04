import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@main
struct DecentlyFluentApp: App {
    init() {
        // development: write pages ahead for the most recommended books (Pregenerated.swift), then quit
        if let out = ProcessInfo.processInfo.environment["DF_PREGENERATE"] {
            Task { @MainActor in
                await Pregenerator.run(to: URL(fileURLWithPath: out))
                exit(0)
            }
        }
    }

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
    @State private var showReady = false
    @State private var editMode: EditMode = .inactive
    var stored = StoredProfile()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    if !readyBooks.isEmpty {
                        Button { showReady = true } label: {
                            Label("Recommended books (already prepared for you)", systemImage: "books.vertical")
                        }
                    }
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
                            Text([book.author, "\(book.language.name)\(book.isOriginal ? " original" : "") · \(book.level.label(original: book.isOriginal))", book.chapters.count == 1 ? "1 chapter" : "\(book.chapters.count) chapters"]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                            if book.progress > 0 || book.currentChapter > 0 {
                                HStack(spacing: 8) {
                                    ProgressView(value: min(1, book.progress)).frame(maxWidth: 160)
                                    Text("Chapter \(book.currentChapter + 1) of \(book.chapters.count) · \(Int((book.progress * 100).rounded()))%")
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .padding(.top, 2)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { delete(book) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button(role: .destructive) { delete(book) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                    .onDelete { idx in
                        for i in idx { context.delete(books[i]) }
                        try? context.save()
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Decently Fluent")
            .navigationDestination(for: Book.self) { ReaderView(book: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack {
                        Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                        Button { showWords = true } label: { Label("My words", systemImage: "character.book.closed") }
                        // deleting books without a swipe (on a Mac there is none)
                        if !books.isEmpty {
                            Button { withAnimation { editMode = editMode.isEditing ? .inactive : .active } } label: {
                                Label(editMode.isEditing ? "Done editing" : "Edit books",
                                      systemImage: editMode.isEditing ? "checkmark" : "pencil")
                            }
                        }
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.epub, .pdf, .plainText, .text]) { result in
                if case .success(let url) = result { importBook(url) }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showWords) { MyWordsView() }
            .fullScreenCover(isPresented: $showDiscover) { DiscoverView { path = [$0] } }
            .fullScreenCover(isPresented: $showReady) {
                RecommendedBooksView(books: readyBooks, profile: stored.profile) { showReady = false; path = [$0] }
            }
            .task { await ReadyShelf.shared.refresh() }
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

    /// Books with pages written ahead for readers of this language: those in the language being learned first,
    /// leaving out ones already in the library.
    private var readyBooks: [ReadyBook] {
        let profile = stored.profile
        let have = Set(books.map { "\($0.title)|\($0.language.rawValue)" })
        return ReadyShelf.shared.books
            .filter { $0.native == profile.native.rawValue }
            .filter { r in !have.contains("\(Catalog.shared.book(id: r.book)?.title ?? "")|\(r.language)") }
            .enumerated().sorted { a, b in
                let (x, y) = (a.element.lang == profile.language, b.element.lang == profile.language)
                return x != y ? x : a.offset < b.offset
            }
            .map(\.element)
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

    private func delete(_ book: Book) {
        context.delete(book)
        try? context.save()
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
        .swipeActions { knownButton(w).tint(w.known ? .orange : .green) }
        .contextMenu { knownButton(w) }
    }

    private func knownButton(_ w: LearnerWord) -> some View {
        Button(w.known ? "Still learning" : "I know it") {
            w.known.toggle()
            if !w.known { w.cleanSightings = 0; w.cleanDays = [] }
            try? context.save()
        }
    }
}

/// A book on the "Recommended books" list, as a card.
struct ReadyRow: View {
    let ready: ReadyBook
    let book: CatalogBook

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(book.author).font(.subheadline).foregroundStyle(.secondary)
                if let blurb = Catalog.shared.blurb(book.id) {
                    Text(blurb).font(.body).foregroundStyle(.primary.opacity(0.85))
                        .multilineTextAlignment(.leading).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                HStack(spacing: 6) {
                    ForEach(ready.levels, id: \.self) { l in
                        Text(l).font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text("ready to read").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }
}

/// The books whose first pages are already written, by language (the one being learned first), and each one's
/// page, set to the language its pages are in at the level they were written at nearest the reader's.
struct RecommendedBooksView: View {
    let books: [ReadyBook]
    let profile: ReadingProfile
    let onAdd: (Book) -> Void
    @Environment(\.dismiss) private var dismiss

    private var languages: [Language] {
        var seen: [Language] = []
        for b in books where !seen.contains(b.lang) { seen.append(b.lang) }
        return seen
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Their first pages are already written at the levels shown, so they open ready to read.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(languages) { lang in
                        VStack(alignment: .leading, spacing: 12) {
                            Text("In \(lang.name)").font(.title2.weight(.bold))
                            ForEach(books.filter { $0.lang == lang }) { r in
                                if let b = Catalog.shared.book(id: r.book) {
                                    NavigationLink {
                                        BookPreview(book: b, profile: Self.profile(profile, for: r), onAdd: onAdd)
                                    } label: { ReadyRow(ready: r, book: b) }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Recommended books")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Principle.Key.self) { PrincipleView(principle: Research.principle($0)) }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    static func profile(_ profile: ReadingProfile, for ready: ReadyBook) -> ReadingProfile {
        var p = profile
        p.language = ready.lang
        let levels = ready.levels.compactMap(Level.init(rawValue:))
        func rank(_ l: Level) -> Int { abs(Level.allCases.firstIndex(of: l)! - Level.allCases.firstIndex(of: profile.level)!) }
        if !levels.contains(p.level), let nearest = levels.min(by: { rank($0) < rank($1) }) { p.level = nearest }
        return p
    }
}

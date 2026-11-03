import SwiftUI
import SwiftData

/// "Find a book for me": a short guide, then recommendations ranked by the research in Research.swift.
struct DiscoverView: View {
    let onAdd: (Book) -> Void
    @Environment(\.dismiss) private var dismiss
    var stored = StoredProfile()
    @State private var editing = false
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Group {
                if !stored.done || editing {
                    GuideView(stored: stored) { editing = false }
                } else {
                    Group {
                        if search.isEmpty {
                            RecommendationsView(profile: stored.profile) { editing = true }
                        } else {
                            SearchResults(text: search, profile: stored.profile)
                        }
                    }
                    .searchable(text: $search, prompt: "Search titles and authors")
                }
            }
            .navigationTitle(!stored.done || editing ? "Find your next book" : "Books for you")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: CatalogBook.self) { BookPreview(book: $0, profile: stored.profile, onAdd: { b in dismiss(); onAdd(b) }) }
            .navigationDestination(for: Principle.Key.self) { PrincipleView(principle: Research.principle($0)) }
            .navigationDestination(for: String.self) { _ in ResearchView() }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

// MARK: - The guide

struct GuideView: View {
    var stored: StoredProfile
    let onDone: () -> Void
    @State private var step = 0
    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(step + 1), total: Double(steps)).padding(.horizontal).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case 0: languageStep
                    case 1: kindStep
                    case 2: levelStep
                    case 3: interestsStep
                    default: timeStep
                    }
                }
                .padding()
            }
            HStack {
                if step > 0 { Button("Back") { withAnimation { step -= 1 } } }
                Spacer()
                Button(step == steps - 1 ? "Show my books" : "Next") {
                    if step == steps - 1 { stored.done = true; onDone() } else { withAnimation { step += 1 } }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private var languageStep: some View {
        let p = stored.profile
        return VStack(alignment: .leading, spacing: 14) {
            Text("Your language").font(.title2.weight(.semibold))
            Text("Word meanings and the side column are in this language.").foregroundStyle(.secondary)
            Picker("Your language", selection: Binding(get: { p.native }, set: { stored.native = $0.rawValue })) {
                ForEach(Language.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Which language are you learning?").font(.title2.weight(.semibold)).padding(.top, 8)
            ForEach(Language.allCases.filter { $0 != p.native }) { lang in
                OptionCard(title: lang.name, detail: nil, selected: p.language == lang) { stored.language = lang.rawValue }
            }
        }
    }

    private var kindStep: some View {
        let p = stored.profile
        let lang = p.language.name, native = p.native.name
        var retold = p
        retold.originals = false
        return VStack(alignment: .leading, spacing: 14) {
            Text("What kind of book?").font(.title2.weight(.semibold))
            OptionCard(title: "Books in \(retold.retoldDescription), retold in \(lang)",
                       detail: "The widest choice, including stories you may already know. Turn your phone sideways to see the \(native) beside the \(lang): the book as written, or a published translation where one exists.",
                       selected: !stored.originals) { stored.originals = false }
            OptionCard(title: "Books written in \(lang)",
                       detail: "The author's own \(lang): unchanged at Native level, simplified at lower levels, keeping their words wherever they fit. The \(native) side is a published translation where one exists, otherwise a machine translation.",
                       selected: stored.originals) { stored.originals = true }
            ResearchNote(.authentic)
        }
    }

    private var levelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How well do you read?").font(.title2.weight(.semibold))
            Text("Every book is rewritten to this level. You can change it any time, even for a single paragraph.")
                .foregroundStyle(.secondary)
            ForEach(Level.allCases) { l in
                OptionCard(title: l.label(original: stored.originals), detail: Self.levelHint(l), selected: stored.level == l.rawValue) { stored.level = l.rawValue }
            }
            ResearchNote(.coverage)
            ResearchNote(.fluency)
        }
    }

    static func levelHint(_ l: Level) -> String {
        switch l {
        case .a1: "You know a few hundred words and simple present-tense sentences."
        case .a2: "You can follow simple stories about everyday things."
        case .b1: "You read straightforward texts, with a word to look up now and then."
        case .b2: "You read most texts, though rarer words and long sentences slow you down."
        case .c1: "You read nearly anything; only rare words trouble you."
        case .native: "No simplification at all."
        }
    }

    private var interestsStep: some View {
        let chosen = Set(stored.interests.split(separator: ",").map(String.init))
        return VStack(alignment: .leading, spacing: 14) {
            Text("What do you enjoy?").font(.title2.weight(.semibold))
            Text("Pick any — or none to see everything.").foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(Category.allCases) { c in
                    let on = chosen.contains(c.rawValue)
                    Button {
                        var s = chosen
                        if on { s.remove(c.rawValue) } else { s.insert(c.rawValue) }
                        stored.interests = s.sorted().joined(separator: ",")
                    } label: {
                        Label(c.name, systemImage: c.symbol)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 12)
                            .background(on ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Color.accentColor : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            ResearchNote(.choice)
        }
    }

    private var timeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How long do you read each day?").font(.title2.weight(.semibold))
            Text("We use this to estimate how long each book will take.").foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 10)], spacing: 10) {
                ForEach([10, 15, 20, 30, 45, 60], id: \.self) { m in
                    OptionCard(title: "\(m) min", detail: nil, selected: stored.minutes == m) { stored.minutes = m }
                }
            }
            ResearchNote(.quantity)
        }
    }
}

struct OptionCard: View {
    let title: String
    let detail: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(selected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

/// "What the research says": one finding, its source, and a link to the full explanation.
struct ResearchNote: View {
    let principle: Principle
    init(_ key: Principle.Key) { principle = Research.principle(key) }

    var body: some View {
        NavigationLink(value: principle.id) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "graduationcap").foregroundStyle(.indigo).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("What the research says").font(.caption.weight(.semibold)).foregroundStyle(.indigo)
                    Text(principle.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(principle.finding).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                    Text(Self.shortCite(principle.sources.first ?? "")).font(.caption2).foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color.indigo.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    /// "Hu, M. & Nation, P. (2000). Unknown…" -> "Hu & Nation (2000)"
    static func shortCite(_ source: String) -> String {
        guard let paren = source.range(of: #"\(\d{4}\)"#, options: .regularExpression) else { return source }
        let names = source[..<paren.lowerBound].components(separatedBy: " & ")
            .map { $0.split(separator: ",").first.map(String.init) ?? $0 }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return names.joined(separator: " & ") + " " + source[paren]
    }
}

// MARK: - Recommendations

struct RecommendationsView: View {
    let profile: ReadingProfile
    let onChange: () -> Void
    @State private var recs: [Recommendation] = []
    @State private var loading = true

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary).font(.subheadline)
                    Button("Change my answers", action: onChange).font(.subheadline)
                }
            } footer: {
                Text("Ranked by how well each book fits what research says helps learners read: everyday vocabulary, a length you can finish, short chapters and sentences, plenty of dialogue — within the kinds of story you chose.")
            }
            Section("Best matches") {
                if loading {
                    HStack { ProgressView(); Text("Measuring the books against your answers…").foregroundStyle(.secondary) }
                } else if recs.isEmpty {
                    Text("No measured books match these choices yet. Try fewer story types.").foregroundStyle(.secondary)
                }
                ForEach(recs) { RecommendationRow(rec: $0) }
            }
            Section("Browse") {
                ForEach(Category.allCases) { c in
                    NavigationLink { ShelfView(category: c, profile: profile) } label: { Label(c.name, systemImage: c.symbol) }
                }
            }
            Section {
                NavigationLink(value: "research") { Label("The research behind these choices", systemImage: "graduationcap") }
            }
        }
        .task {
            // a few thousand catalog lookups: keep them off the main thread
            let profile = profile
            recs = await Task.detached { Recommender.recommend(profile) }.value
            loading = false
        }
    }

    private var summary: String {
        let kind = profile.originals ? "Books written in \(profile.language.name)" : "Books in \(profile.retoldDescription) retold in \(profile.language.name)"
        let likes = profile.interests.isEmpty ? "any kind of story" : profile.interests.map(\.name).sorted().joined(separator: ", ")
        return "\(kind) · \(profile.level.rawValue) · \(profile.minutesPerDay) min a day · \(likes)"
    }
}

struct RecommendationRow: View {
    let rec: Recommendation

    var body: some View {
        NavigationLink(value: rec.book) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rec.book.title).font(.body.weight(.semibold)).lineLimit(2)
                        Text(rec.book.author).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ScoreBadge(score: rec.score)
                }
                ForEach(rec.reasons.filter(\.good).prefix(2)) { r in
                    Label(r.text, systemImage: "checkmark").font(.caption).foregroundStyle(.green).lineLimit(2)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct ScoreBadge: View {
    let score: Int
    var body: some View {
        Text("\(score)")
            .font(.callout.monospacedDigit().weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 30)
            .background(score >= 75 ? Color.green : score >= 60 ? Color.teal : score >= 45 ? Color.orange : Color.gray,
                        in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Match \(score) out of 100")
    }
}

struct ShelfView: View {
    let category: Category
    let profile: ReadingProfile
    var body: some View {
        let books = profile.sourceLanguages
            .flatMap { Catalog.shared.shelf(category, language: $0.rawValue, originalsOnly: profile.originals) }
            .sorted { $0.popularity > $1.popularity }
        List(books) { CatalogRow(book: $0) }
            .navigationTitle(category.name)
    }
}

struct CatalogRow: View {
    let book: CatalogBook
    var body: some View {
        NavigationLink(value: book) {
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).lineLimit(2)
                Text([book.author, book.words.map { "\($0 / 1000)k words" } ?? "", book.lang.name + (book.translated ? " translation" : "")]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SearchResults: View {
    let text: String
    let profile: ReadingProfile
    var body: some View {
        let results = Catalog.shared.search(text, languages: Language.allCases.map(\.rawValue))
        List {
            if results.isEmpty { Text("Nothing found.").foregroundStyle(.secondary) }
            ForEach(results) { CatalogRow(book: $0) }
        }
    }
}

// MARK: - A book, and why

struct BookPreview: View {
    let book: CatalogBook
    let profile: ReadingProfile
    let onAdd: (Book) -> Void
    @Environment(\.modelContext) private var context
    @State private var imported: ImportedBook?
    @State private var fit: LearnerFit?
    @State private var error: String?
    @State private var loading = false
    @State private var adding: String?

    private var editions: [Language: CatalogBook] { Catalog.shared.bestEditions(of: book.id) }

    private var rec: Recommendation? {
        guard book.measured else { return nil }
        let lang = book.language
        let all = Catalog.shared.measured(language: lang)
        let cov = all.compactMap { profile.usesCoverage5k ? $0.coverage5k : $0.coverage2k }.sorted()
        let authorBooks = all.filter { $0.author == book.author }.count
        return Recommender.score(book, profile, coverages: cov, popularity: all.map(\.popularity).sorted(), authorBooks: authorBooks)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title).font(.title3.weight(.semibold))
                    Text([book.author, book.years.isEmpty ? "" : "(\(book.years))"].joined(separator: " ")).foregroundStyle(.secondary)
                    if let w = book.words {
                        Text("About \(w.formatted()) words\(book.chapters.map { " · \($0) chapters" } ?? "")").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if let rec {
                Section {
                    HStack {
                        ScoreBadge(score: rec.score)
                        VStack(alignment: .leading) {
                            Text(rec.verdict).font(.headline)
                            Text("for \(profile.level.rawValue), \(profile.minutesPerDay) minutes a day").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(rec.reasons) { r in ReasonRow(reason: r) }
                    if rec.score >= 75 && profile.level != .a1 {
                        ReasonRow(reason: Reason(good: true, text: "Tip: a good fit like this is ideal for fluency practice — try a chapter one level below \(profile.level.rawValue); it should feel effortless.", principle: .fluency))
                    }
                } header: { Text("Why this book") } footer: {
                    Text("Measured from the book's text. Tap a reason with a cap icon to see the research behind it.")
                }
            } else if let fit {
                Section("For learners") {
                    Label(fit.verdict.rawValue, systemImage: fit.verdict == .hard ? "exclamationmark.triangle" : "checkmark.seal")
                        .foregroundStyle(fit.verdict == .hard ? .orange : .green)
                    ForEach(Array(fit.notes.enumerated()), id: \.offset) { _, n in
                        ReasonRow(reason: Reason(good: n.good, text: n.text, principle: nil))
                    }
                }
            }

            if !editions.isEmpty {
                Section {
                    ForEach(editions.keys.sorted { $0.name < $1.name }) { l in
                        let e = editions[l]!
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(l.name): \(e.title)").font(.subheadline)
                            Text(e.editionCredit).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Other editions") } footer: {
                    Text("Published human translations are used instead of machine translation: as the text at Native level, as the starting point for simpler levels, and in the side column.")
                }
            }

            Section {
                if let adding {
                    HStack { ProgressView(); Text(adding).foregroundStyle(.secondary) }
                } else if let imported {
                    if let original = book.originalLanguage, original != profile.native {
                        Button { Task { await add(original) } } label: { Label("Read the \(original.name) original", systemImage: "book") }
                    }
                    let langs = ([profile.language] + Language.allCases.filter { $0 != profile.language })
                        .filter { $0 != book.lang && $0 != profile.native }
                    ForEach(langs) { lang in
                        Button { Task { await add(lang) } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Read it in \(lang.name)", systemImage: "book")
                                if let e = editions[lang] {
                                    Text(e.translated ? "Uses the published translation\(e.translator.isEmpty ? "" : " by \(e.translator)")" : "Native level is the author's \(lang.name) original")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("\(imported.chapters.count) chapters, translated as you reach them.").font(.caption).foregroundStyle(.secondary)
                } else if let error {
                    Text(error).foregroundStyle(.orange)
                } else {
                    Button { Task { await load() } } label: {
                        HStack { Label("Get this book", systemImage: "arrow.down.circle"); if loading { Spacer(); ProgressView() } }
                    }
                    .disabled(loading)
                }
            } footer: { Text("Free from Project Gutenberg.") }
            Section { Link("View on gutenberg.org", destination: book.gutenberg.pageURL) }
        }
        .navigationTitle("Book")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let file = try await Gutenberg.download(book.gutenberg)
            var b = try Importer.read(url: file)
            b.chapters = Gutenberg.dropGutenbergMatter(b.chapters)
            if b.title.isEmpty || b.title.hasPrefix("pg") { b.title = book.title }
            if b.author.isEmpty { b.author = book.author }
            imported = b
            if !book.measured { fit = LearnerFit(b) }
        } catch {
            self.error = "Couldn't download this book: \(error.localizedDescription)"
        }
    }

    /// Saves the book to learn `lang` from, with any published translation it can use:
    /// into `lang` for a retold book, and into the reader's language for the side column.
    private func add(_ lang: Language) async {
        guard let imported else { return }
        let native = profile.native
        var target: (CatalogBook, Data)?, side: (CatalogBook, Data)?
        if lang != book.lang, let e = editions[lang] {
            adding = "Getting the \(lang.name) \(e.translated ? "translation" : "original")…"
            target = await Self.edition(Catalog.shared.volumes(of: book.id, in: lang)).map { (e, $0) }
        }
        if book.lang != native, let e = editions[native] {
            adding = "Getting the \(native.name) \(e.translated ? "translation" : "original")…"
            side = await Self.edition(Catalog.shared.volumes(of: book.id, in: native)).map { (e, $0) }
        }
        adding = nil
        let b = BookStore.store(imported, language: lang, source: book.lang, native: native, in: context)
        b.level = profile.level
        if let (e, data) = target { b.humanTargetEdition = data; b.targetTranslator = Self.credit(e) }
        if let (e, data) = side { b.humanSideEdition = data; b.sideTranslator = Self.credit(e) }
        try? context.save()
        onAdd(b)
    }

    /// The translator's name; empty for the author's original.
    static func credit(_ e: CatalogBook) -> String {
        e.translated ? (e.translator.isEmpty ? "an unnamed translator" : e.translator) : ""
    }

    /// Downloads another edition (every volume of it) and keeps its chapters for matching
    /// (nil if it can't be had: then machine translation).
    static func edition(_ volumes: [CatalogBook]) async -> Data? {
        guard let first = volumes.first else { return nil }
        var chapters: [HumanEdition.Chapter] = []
        for v in volumes {
            guard let file = try? await Gutenberg.download(v.gutenberg), let b = try? Importer.read(url: file) else { return nil }
            chapters += Gutenberg.dropGutenbergMatter(b.chapters).map { HumanEdition.Chapter(title: $0.title, paragraphs: $0.paragraphs) }
        }
        return try? JSONEncoder().encode(HumanEdition(language: first.lang, translator: credit(first), chapters: chapters))
    }
}

struct ReasonRow: View {
    let reason: Reason
    var body: some View {
        let row = HStack(alignment: .top, spacing: 10) {
            Image(systemName: reason.good ? "plus.circle.fill" : "minus.circle")
                .foregroundStyle(reason.good ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(reason.text).font(.subheadline).foregroundStyle(.primary)
                if let key = reason.principle {
                    let p = Research.principle(key)
                    Label("\(p.title) · \(ResearchNote.shortCite(p.sources.first ?? ""))", systemImage: "graduationcap")
                        .font(.caption2).foregroundStyle(.indigo)
                }
            }
        }
        if let key = reason.principle {
            NavigationLink(value: key) { row }
        } else {
            row
        }
    }
}

// MARK: - The research

struct ResearchView: View {
    var body: some View {
        List {
            Section {
                Text("Decently Fluent's book advice follows research on how people learn vocabulary by reading, much of it by Paul Nation of Victoria University of Wellington, a leading researcher on vocabulary learning and extensive reading. Each recommendation shows which of these findings it rests on.")
                    .font(.callout)
            }
            ForEach(Research.principles) { p in
                NavigationLink(value: p.id) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.title).font(.body.weight(.semibold))
                        Text(p.finding).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            Section {
                Text("Measurements are estimates made from each book's text: vocabulary coverage uses a frequency list for each language, built from its most read books in the collection (700 English, 300 each in French, German, Spanish and Italian).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("The research")
    }
}

struct PrincipleView: View {
    let principle: Principle
    var body: some View {
        List {
            Section("What research found") { Text(principle.finding) }
            Section("How the app uses it") { Text(principle.howWeUseIt) }
            Section("Sources") {
                ForEach(principle.sources, id: \.self) { Text($0).font(.footnote) }
            }
        }
        .navigationTitle(principle.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

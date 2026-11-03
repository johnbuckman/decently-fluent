import SwiftUI
import SwiftData

/// What the gloss card at the bottom of the reader shows.
struct WordCard: Equatable {
    var word: String
    var lemma: String
    var meaning: String?
    var isLearning: Bool
}

struct ReaderView: View {
    @Bindable var book: Book
    @Environment(\.modelContext) private var context
    @State private var generator = Generator.shared
    @State private var showNewWords = false
    @State private var card: WordCard?
    @State private var sighted: Set<String> = []
    @State private var learningLemmas: Set<String> = []
    /// The last paragraph that came on screen, where text making picks up after a change of level.
    @State private var lastSeen = 0

    private var chapters: [Chapter] { book.sortedChapters }
    private var chapter: Chapter? { chapters.indices.contains(book.currentChapter) ? chapters[book.currentChapter] : chapters.first }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if let chapter {
                            header(chapter, landscape: landscape).id("top")
                            ForEach(chapter.sortedParagraphs) { p in
                                ParagraphRow(paragraph: p, book: book, landscape: landscape, showNewWords: showNewWords,
                                             learningLemmas: learningLemmas,
                                             onTap: { tapped($0, $1) }, onDoubleTap: { doubleTapped($0, $1) },
                                             onShown: { shown(p, $0) })
                                    .onAppear {
                                        // keep a few pages ahead of the reader
                                        lastSeen = p.index
                                        generator.ensure(chapter: chapter, book: book, from: p.index)
                                    }
                            }
                            chapterNavigation
                        }
                    }
                    .padding(.horizontal, landscape ? 32 : 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: landscape ? .infinity : 720)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: book.currentChapter) { _, _ in
                    lastSeen = 0
                    proxy.scrollTo("top", anchor: .top)
                    generate()
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let card {
                GlossCardView(card: card, onKnown: { markKnown(card) }, onClose: { self.card = nil })
                    .padding(.horizontal).padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: card)
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear {
            refreshLearning()
            generate()
        }
        .onChange(of: book.levelRaw) { _, _ in generate() }
    }

    // MARK: - Pieces

    private func header(_ chapter: Chapter, landscape: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(chapter.title).font(.system(.title2, design: .serif).weight(.semibold))
            Text("\(book.language.name)\(book.isOriginal ? " original" : "") · \(book.level.label(original: book.isOriginal))\(landscape ? " · \(book.native.name) on the right" : "")")
                .font(.footnote).foregroundStyle(.secondary)
            if let credit = translationCredit(chapter) {
                Text(credit).font(.footnote).foregroundStyle(.secondary)
            }
            if let status = generator.status {
                Label(status, systemImage: "text.alignleft").font(.footnote).foregroundStyle(.secondary)
            }
            if let err = generator.lastError {
                Label(err, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(.bottom, 6)
    }

    /// Who translated what the reader sees, when it's a published human translation.
    private func translationCredit(_ chapter: Chapter) -> String? {
        var parts: [String] = []
        if let t = book.targetTranslator, !book.isOriginal {
            let text = t.isEmpty ? "the author's own \(book.language.name)" : "the \(book.language.name) translation by \(t)"
            parts.append(book.level == .native ? text.prefix(1).uppercased() + text.dropFirst() : "Simplified from \(text)")
        }
        if let t = book.sideTranslator { parts.append(t.isEmpty ? "\(book.native.name): the original" : "\(book.native.name) translation by \(t)") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ") + (chapter.humanTranslationFailed ? " (machine translated in this chapter)" : "")
    }

    private var chapterNavigation: some View {
        HStack {
            if book.currentChapter > 0 {
                Button { book.currentChapter -= 1 } label: { Label("Previous chapter", systemImage: "chevron.left") }
            }
            Spacer()
            if book.currentChapter + 1 < chapters.count {
                Button { book.currentChapter += 1 } label: { Label("Next chapter", systemImage: "chevron.right").labelStyle(TrailingIcon()) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.top, 24)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showNewWords.toggle() } label: {
                Label("New words", systemImage: showNewWords ? "highlighter" : "highlighter")
                    .symbolVariant(showNewWords ? .fill : .none)
            }
            .tint(showNewWords ? .yellow : nil)

            Menu {
                Picker("Level", selection: $book.level) {
                    ForEach(Level.allCases) { Text($0.label(original: book.isOriginal)).tag($0) }
                }
            } label: {
                Text(book.level.rawValue).font(.headline)
            }

            Menu {
                Picker("Chapter", selection: $book.currentChapter) {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { i, ch in Text(ch.title).tag(i) }
                }
            } label: { Label("Chapters", systemImage: "list.bullet") }
        }
    }

    // MARK: - Actions

    private func generate() {
        guard let chapter else { return }
        generator.ensure(chapter: chapter, book: book, from: lastSeen)
    }

    private func refreshLearning() {
        learningLemmas = Set(Learner.learning(book.language, in: context, limit: 500).map { $0.lemma.lowercased() })
    }

    private func tapped(_ token: WordToken, _ gloss: Gloss?) {
        guard let gloss else { card = nil; return }
        card = WordCard(word: token.core, lemma: gloss.lemma, meaning: gloss.meaning,
                        isLearning: learningLemmas.contains(gloss.lemma.lowercased()))
    }

    /// Double-tap: "I don't know this word." Show it, and remember it.
    private func doubleTapped(_ token: WordToken, _ gloss: Gloss?, paragraphText: String = "") {
        let lang = book.language
        if let gloss, !gloss.meaning.isEmpty {
            Learner.markUnknown(lang, lemma: gloss.lemma, meaning: gloss.meaning, in: context)
            card = WordCard(word: token.core, lemma: gloss.lemma, meaning: gloss.meaning, isLearning: true)
            refreshLearning()
            return
        }
        let guess = Lemmatizer.lemma(token.core, language: lang)
        card = WordCard(word: token.core, lemma: guess, meaning: nil, isLearning: true)
        Task {
            let found = await generator.lookUp(token.core, sentence: token.sentence, language: lang, native: book.native)
            let lemma = found?.lemma ?? guess
            Learner.markUnknown(lang, lemma: lemma, meaning: found?.meaning ?? "", in: context)
            if card?.word == token.core {
                card = WordCard(word: token.core, lemma: lemma, meaning: found?.meaning ?? "(couldn't look this up)", isLearning: true)
            }
            refreshLearning()
        }
    }

    private func markKnown(_ c: WordCard) {
        if let w = Learner.word(book.language, c.lemma, in: context) { Learner.markKnown(w, in: context) }
        card = nil
        refreshLearning()
    }

    /// A paragraph's target-language text came on screen: the reader saw its words.
    private func shown(_ p: Paragraph, _ r: Rendition) {
        let key = Generator.key(p, p.effectiveLevel(book: book))
        guard !sighted.contains(key) else { return }
        sighted.insert(key)
        var lemmas = Set(Lemmatizer.lemmas(in: r.text, language: book.language))
        lemmas.formUnion(r.glossary.map { $0.lemma.lowercased() })
        Learner.recordSighting(lemmas: lemmas, language: book.language, in: context)
        refreshLearning()
    }
}

struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon }
    }
}

// MARK: - Paragraph

struct ParagraphRow: View {
    let paragraph: Paragraph
    let book: Book
    let landscape: Bool
    let showNewWords: Bool
    let learningLemmas: Set<String>
    let onTap: (WordToken, Gloss?) -> Void
    let onDoubleTap: (WordToken, Gloss?) -> Void
    let onShown: (Rendition) -> Void
    @Environment(\.modelContext) private var context
    private var generator: Generator { Generator.shared }

    var body: some View {
        let level = paragraph.effectiveLevel(book: book)
        Group {
            if landscape {
                HStack(alignment: .top, spacing: 28) {
                    target(level).frame(maxWidth: .infinity, alignment: .leading)
                    Text(paragraph.side(book: book) ?? "\(book.native.name) translation on its way…")
                        .font(.system(size: 17, design: .serif))
                        .foregroundStyle(paragraph.side(book: book) == nil ? .tertiary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            } else {
                target(level)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { levelMenu(level) }
    }

    @ViewBuilder
    private func target(_ level: Level) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if paragraph.overrideLevel != nil {
                Text(level.rawValue)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }
            if let r = paragraph.rendition(level) {
                WordFlowText(rendition: r, language: book.language, showNewWords: showNewWords,
                             learningLemmas: learningLemmas, onTap: onTap, onDoubleTap: onDoubleTap)
                    .task(id: r.text) { onShown(r) }
            } else if let err = generator.failure(paragraph, level) {
                Button {
                    generator.retry(paragraph, book: book)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(paragraph.source).foregroundStyle(.secondary)
                        Label("Couldn't translate — tap to try again. \(err)", systemImage: "arrow.clockwise")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .buttonStyle(.plain)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(paragraph.source)
                        .font(.system(size: 17, design: .serif))
                        .foregroundStyle(.tertiary)
                        .redacted(reason: landscape ? .placeholder : [])
                }
            }
        }
    }

    @ViewBuilder
    private func levelMenu(_ current: Level) -> some View {
        Section("Level for this paragraph") {
            ForEach(Level.allCases) { l in
                Button {
                    paragraph.overrideLevel = (l == book.level) ? nil : l
                    try? context.save()
                    if let ch = paragraph.chapter { generator.ensure(chapter: ch, book: book, from: paragraph.index) }
                } label: {
                    if l == current { Label(l.label, systemImage: "checkmark") } else { Text(l.label) }
                }
            }
        }
        if paragraph.overrideLevel != nil {
            Button("Same as the book (\(book.level.rawValue))") {
                paragraph.overrideLevel = nil
                try? context.save()
            }
        }
    }
}

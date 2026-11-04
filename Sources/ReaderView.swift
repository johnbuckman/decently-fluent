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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    /// "dark" or "light" once the reader has chosen; empty follows the system.
    @AppStorage("readerScheme") private var readerScheme = ""
    /// The text size, changed by pinching and kept for every book.
    @AppStorage("readerFontSize") private var fontSize: Double = 20
    @GestureState private var pinch: CGFloat = 1
    @State private var card: WordCard?
    /// The sentence the reader tapped: its paragraph, its place there, and the side column's matching sentences.
    /// The tapped sentence: its paragraph, the sentences shaded in the target column and those in the side column.
    @State private var pick: (paragraph: UUID, target: Set<Int>, side: [String])?
    @State private var sighted: Set<String> = []
    @State private var learningLemmas: Set<String> = []
    /// The reader's size at the last layout, for paging from the buttons and keys.
    @State private var lastSize: CGSize = .zero
    /// The measured height of the text area and of the chapter heading, for cutting pages.
    @State private var pageHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    /// Only the text: no toolbar, page buttons or status bar (tap the bottom centre to switch).
    @State private var textOnly = false
    /// Counts turns made with taps, buttons and keys, so the page curl animates them.
    @State private var turns = 0

    private var chapters: [Chapter] { book.sortedChapters }
    private var chapter: Chapter? { chapters.indices.contains(book.currentChapter) ? chapters[book.currentChapter] : chapters.first }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            if let chapter {
                let pages = cut(chapter.sortedParagraphs, width: geo.size.width, landscape: landscape)
                let page = pageIndex(pages)
                VStack(spacing: 0) {
                    // pages curl like a book's: drag a corner, or tap, swipe, the buttons or the arrow keys
                    PageCurl(place: PagePlace(chapter: book.currentChapter, page: page), turns: turns,
                             neighbour: { neighbour($0, $1, width: geo.size.width, landscape: landscape) },
                             style: readerScheme == "dark" ? .dark : readerScheme == "light" ? .light : .unspecified,
                             onTurn: { place in curled(to: place, width: geo.size.width, landscape: landscape) }) { place in
                        let shown = place.chapter == book.currentChapter ? pages
                            : cut(chapters[place.chapter].sortedParagraphs, width: geo.size.width, landscape: landscape)
                        pageContent(shown, page: min(place.page, shown.count - 1), chapter: chapters[place.chapter],
                                    landscape: landscape)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
                    if !textOnly {
                        pageProgress(pages[page])
                        pageBar(page: page, pages: pages)
                    }
                }
                // with only the text showing, a tap at the bottom centre brings everything back
                .overlay(alignment: .bottom) {
                    if textOnly {
                        Color.clear.contentShape(Rectangle())
                            .frame(width: 200, height: 56)
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { textOnly = false } }
                            .accessibilityLabel("Show the toolbar and page buttons")
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.rightArrow) { turn(1, pages: pages); return .handled }
                .onKeyPress(.leftArrow) { turn(-1, pages: pages); return .handled }
                .onKeyPress(.space) { turn(1, pages: pages); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "+=-")) { key in
                    fontSize = min(36, max(14, fontSize + (key.characters == "-" ? -2 : 2)))
                    return .handled
                }
                .onAppear {
                    lastSize = geo.size
                    generate(from: pages[page].first?.paragraph.index ?? 0)
                }
                .onChange(of: geo.size) { _, size in lastSize = size }
                // a new page, or a new chapter (whose first page is also page 1)
                .onChange(of: "\(book.currentChapter)-\(page)") { _, _ in
                    pick = nil
                    generate(from: pages[page].first?.paragraph.index ?? 0)
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
        // the title is the chapters pull-down in the toolbar instead
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .toolbar(textOnly ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(textOnly)
        .persistentSystemOverlays(textOnly ? .hidden : .automatic)
        .onAppear {
            refreshLearning()
            book.updateProgress()
        }
        .preferredColorScheme(readerScheme == "dark" ? .dark : readerScheme == "light" ? .light : nil)
        .onChange(of: book.levelRaw) { _, _ in generate(from: book.readingParagraph) }
    }

    // MARK: - Pieces

    /// One page: its paragraphs (and the chapter heading on the first) and tappable words. Shown inside the page curl, which is UIKit, so it is given the reader's environment here.
    private func pageContent(_ pages: [[PageItem]], page: Int, chapter: Chapter, landscape: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if page == 0 {
                    header(chapter, landscape: landscape)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                }
                ForEach(pages[page]) { item in
                    let picked = pick?.paragraph == item.paragraph.uid ? pick : nil
                    ParagraphRow(paragraph: item.paragraph, words: item.words, wordCount: item.wordCount,
                                 book: book, landscape: landscape, showNewWords: showNewWords,
                                 selectedSentences: picked?.target ?? [], shadedSide: picked?.side ?? [],
                                 learningLemmas: learningLemmas,
                                 onTap: { tapped($0, $1, in: item.paragraph) }, onDoubleTap: { doubleTapped($0, $1) },
                                 onTapSide: { tappedSide($0, in: item.paragraph) },
                                 onShown: { shown(item.paragraph, $0) })
                }
            }
            .padding(.horizontal, landscape ? 32 : 20)
            .padding(.vertical, 16)
            .frame(maxWidth: landscape ? .infinity : 720)
            .frame(maxWidth: .infinity)
        }
        // a page normally fits; it scrolls only when a paragraph is longer than the screen
        .scrollBounceBehavior(.basedOnSize)
        // pages turn by dragging or swiping them, or with the buttons below; a tap off a word just closes its card
        .contentShape(Rectangle())
        .onTapGesture { card = nil }
        // pinch to make the text bigger or smaller; the pages are re-cut when the fingers lift
        .simultaneousGesture(MagnifyGesture()
            .updating($pinch) { v, state, _ in state = v.magnification }
            .onEnded { v in fontSize = min(36, max(14, (fontSize * v.magnification).rounded())) })
        .scaleEffect(pinch, anchor: .center)
        .environment(\.readerFontSize, fontSize)
        .environment(\.horizontalSizeClass, sizeClass)
        .modelContext(context)
    }

    /// The page before (`step` -1) or after (+1) a place, across chapters; nil at either end of the book.
    private func neighbour(_ place: PagePlace, _ step: Int, width: CGFloat, landscape: Bool) -> PagePlace? {
        func count(_ c: Int) -> Int { cut(chapters[c].sortedParagraphs, width: width, landscape: landscape).count }
        if step > 0 {
            if place.page + 1 < count(place.chapter) { return PagePlace(chapter: place.chapter, page: place.page + 1) }
            return place.chapter + 1 < chapters.count ? PagePlace(chapter: place.chapter + 1, page: 0) : nil
        }
        if place.page > 0 { return PagePlace(chapter: place.chapter, page: place.page - 1) }
        return place.chapter > 0 ? PagePlace(chapter: place.chapter - 1, page: max(0, count(place.chapter - 1) - 1)) : nil
    }

    /// The reader curled the page by hand: go to where it landed.
    private func curled(to place: PagePlace, width: CGFloat, landscape: Bool) {
        let pages = cut(chapters[place.chapter].sortedParagraphs, width: width, landscape: landscape)
        book.currentChapter = place.chapter
        go(to: pages.indices.contains(place.page) ? pages[place.page].first : nil)
    }

    private func header(_ chapter: Chapter, landscape: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(chapter.title).font(.system(.title2, design: .serif).weight(.semibold))
            if sizeClass == .compact {
                levelMenu {
                    HStack(spacing: 3) {
                        Text("\(book.language.name)\(book.isOriginal ? " original" : "") · \(book.level.label(original: book.isOriginal))")
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .font(.footnote)
                }
            } else {
                Text("\(book.language.name)\(book.isOriginal ? " original" : "") · \(book.level.label(original: book.isOriginal))\(landscape ? " · \(book.native.name) on the right" : "")")
                    .font(.footnote).foregroundStyle(.secondary)
            }
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

    private func pageBar(page: Int, pages: [[PageItem]]) -> some View {
        // full labels where they fit; with large text on a phone, shorter ones, so the bar never pushes the page
        // wider than the screen
        ViewThatFits(in: .horizontal) {
            pageBarRow(page: page, pages: pages, short: false)
            pageBarRow(page: page, pages: pages, short: true)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private func pageBarRow(page: Int, pages: [[PageItem]], short: Bool) -> some View {
        let count = pages.count
        let first = page == 0 && book.currentChapter == 0
        let last = page == count - 1 && book.currentChapter == chapters.count - 1
        let nextTitle = page == count - 1 && !last ? (short ? "Chapter" : "Next chapter") : (short ? "Next" : "Next page")
        return HStack {
            Button { previous(page: page, pages: pages) } label: {
                Label("Previous page", systemImage: "chevron.left").labelStyle(short ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                    .lineLimit(1).fixedSize()
            }
            .disabled(first)
            Spacer(minLength: 8)
            // tap the page number for only the text, on the whole screen
            Button { withAnimation(.easeInOut(duration: 0.25)) { textOnly = true } } label: {
                Text(short ? "\(page + 1) / \(count)" : "Page \(page + 1) of \(count)")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Page \(page + 1) of \(count)")
            .accessibilityHint("Shows only the text")
            Spacer(minLength: 8)
            Button { next(page: page, pages: pages) } label: {
                Label(nextTitle, systemImage: "chevron.right").labelStyle(TrailingIcon())
                    .lineLimit(1).fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .disabled(last)
        }
    }

    /// While this page's text is being written: a bar, how many paragraphs are done, and a time estimate.
    @ViewBuilder
    private func pageProgress(_ items: [PageItem]) -> some View {
        let paragraphs = Array(Set(items.map(\.paragraph.uid))).compactMap { id in items.first { $0.paragraph.uid == id }?.paragraph }
        let waiting = paragraphs.filter { p in
            let l = p.effectiveLevel(book: book)
            return p.rendition(l) == nil && generator.failure(p, l) == nil
        }
        if !waiting.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.5)) { tl in
                let total = paragraphs.count, done = total - waiting.count
                let inFlight = waiting.filter { p in generator.current?.keys.contains(Generator.key(p, p.effectiveLevel(book: book))) == true }.count
                let elapsed = generator.current.map { tl.date.timeIntervalSince($0.started) } ?? 0
                let expected = generator.expectedSeconds
                // never quite reaches the end on its own: the last bit waits for the answer
                let batchShare = min(0.95, elapsed / expected)
                let fraction = (Double(done) + Double(inFlight) * batchShare) / Double(max(total, 1))
                let left = max(0, Int((expected - elapsed).rounded()))
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: fraction)
                    HStack {
                        Text(generator.status ?? "Writing \(sizeClass == .compact ? book.level.rawValue : book.level.label(original: book.isOriginal))…")
                            .lineLimit(1)
                        Spacer()
                        Text(inFlight == 0 ? "\(done) of \(total) paragraphs · waiting its turn"
                             : elapsed > expected ? "\(done) of \(total) paragraphs · taking longer than usual, \(Int(elapsed)) s"
                             : "\(done) of \(total) paragraphs · about \(left) s left")
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20).padding(.top, 6)
            }
        }
    }

    /// The page holding the place the reader is at.
    private func pageIndex(_ pages: [[PageItem]]) -> Int {
        let at = (book.readingParagraph, book.readingWord)
        return pages.lastIndex { ($0.first?.paragraph.index ?? 0, $0.first?.words.lowerBound ?? 0) <= at } ?? 0
    }

    private func go(to item: PageItem?) {
        book.readingParagraph = item?.paragraph.index ?? 0
        book.readingWord = item?.words.lowerBound ?? 0
        book.updateProgress()
    }

    private func turn(_ step: Int, pages: [[PageItem]]) {
        let page = pageIndex(pages)
        if step > 0 { next(page: page, pages: pages) } else { previous(page: page, pages: pages) }
    }


    private func next(page: Int, pages: [[PageItem]]) {
        turns += 1
        if page + 1 < pages.count {
            go(to: pages[page + 1].first)
        } else if book.currentChapter + 1 < chapters.count {
            book.currentChapter += 1
            go(to: nil)
        }
    }

    private func previous(page: Int, pages: [[PageItem]]) {
        turns += 1
        if page > 0 {
            go(to: pages[page - 1].first)
        } else if book.currentChapter > 0 {
            book.currentChapter -= 1
            // the last page of the chapter before
            let before = chapters[book.currentChapter].sortedParagraphs
            go(to: cut(before, width: lastSize.width, landscape: lastSize.width > lastSize.height).last?.first)
        }
    }

    /// This chapter's pages for the text area as measured (estimated until it has been laid out once).
    private func cut(_ paragraphs: [Paragraph], width: CGFloat, landscape: Bool) -> [[PageItem]] {
        let height = pageHeight > 0 ? pageHeight : lastSize.height - 64
        return Self.pages(paragraphs, book: book, width: width, height: height - 32,
                          heading: headerHeight > 0 ? headerHeight + 18 : 110,
                          landscape: landscape, glossLabels: showNewWords, fontSize: fontSize)
    }

    /// Splits a chapter into pages the way a printed book does: paragraphs follow one another, and one that
    /// doesn't fit carries on at the top of the next page. Line breaks are worked out by wrapping the words
    /// as WordFlowText does, in the reader's font, so a page holds what the screen shows.
    /// `height` is the room for text on a page (the text area less its padding); `heading` is what the chapter
    /// heading takes on the first page.
    static func pages(_ paragraphs: [Paragraph], book: Book, width: CGFloat, height: CGFloat, heading: CGFloat,
                      landscape: Bool, glossLabels: Bool, fontSize: CGFloat = 20) -> [[PageItem]] {
        let whole = paragraphs.map { PageItem(paragraph: $0, words: 0..<Int.max, wordCount: Int.max) }
        guard width > 0, height > 0, !paragraphs.isEmpty else { return [whole] }
        let column = landscape ? (width - 64 - 28) / 2 : min(width, 720) - 40
        let available = height - 4  // a little to spare
        let line = lineHeight(labels: glossLabels, fontSize: fontSize)
        var pages: [[PageItem]] = [], current: [PageItem] = [], used: CGFloat = heading
        for p in paragraphs {
            let text = p.rendition(p.effectiveLevel(book: book))?.text ?? p.source
            let starts = lineStarts(text, width: column, fontSize: fontSize)  // the first word of each line
            let count = text.split(whereSeparator: \.isWhitespace).count
            var l = 0
            while l < starts.count {
                let gap: CGFloat = current.isEmpty ? 0 : 18
                let fit = Int((available - used - gap) / line)
                let rest = starts.count - l
                // all of the rest; or as many lines as fit, keeping two for the next page so a single line is
                // never left behind; or, at the top of a page, whatever fits
                let split = min(fit, rest - 2)
                if fit >= rest || split >= 2 || (current.isEmpty && fit >= 1) {
                    let take = fit >= rest ? rest : (split >= 2 ? split : max(1, fit))
                    let end = l + take < starts.count ? starts[l + take] : count
                    current.append(PageItem(paragraph: p, words: starts[l]..<end, wordCount: count))
                    used += gap + CGFloat(take) * line
                    l += take
                    if l < starts.count { pages.append(current); current = []; used = 0 }
                } else {
                    pages.append(current); current = []; used = 0
                }
            }
        }
        if !current.isEmpty { pages.append(current) }
        return pages.isEmpty ? [whole] : pages
    }

    private static func readerFont(_ size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size)
        return base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
    }
    /// Word widths already measured, by font size.
    private static var wordWidths: [CGFloat: [Substring: CGFloat]] = [:]

    /// One line of WordFlowText: the font, plus 6 points between lines (10, plus a line for the meanings,
    /// when new words are shown).
    static func lineHeight(labels: Bool, fontSize: CGFloat) -> CGFloat {
        ceil(readerFont(fontSize).lineHeight) + (labels ? 10 + ceil(WordView.labelFont.lineHeight) : 6)
    }

    /// The index of the first word of each line when `text` wraps like WordFlowText (words 5 points apart).
    static func lineStarts(_ text: String, width: CGFloat, fontSize: CGFloat) -> [Int] {
        var starts = [0], x: CGFloat = 0
        let font = readerFont(fontSize)
        var known = wordWidths[fontSize] ?? [:]
        defer { wordWidths[fontSize] = known }
        for (i, word) in text.split(whereSeparator: \.isWhitespace).enumerated() {
            let w: CGFloat
            if let k = known[word] { w = k } else {
                w = ceil((String(word) as NSString).size(withAttributes: [.font: font]).width)
                known[word] = w
            }
            if x > 0 && x + 5 + w > width { starts.append(i); x = w } else { x += (x > 0 ? 5 : 0) + w }
        }
        return starts
    }

    /// The levels, listed directly (no "Level" submenu).
    private func levelMenu(@ViewBuilder label: () -> some View) -> some View {
        Menu {
            // a ticked box: the next pages are already written at that level; an hourglass: they'll be written on demand
            Picker("Level", selection: Binding(get: { book.level }, set: { book.level = $0 })) {
                ForEach(Level.allCases) { l in
                    Label(l.label(original: book.isOriginal), systemImage: isReady(l) ? "checkmark.square" : "hourglass").tag(l)
                }
            }
            .pickerStyle(.inline)
        } label: { label() }
    }

    /// Whether the next few pages from the reader's place are already written at a level.
    private func isReady(_ level: Level) -> Bool {
        guard let chapter else { return false }
        var words = 0
        for p in chapter.sortedParagraphs where p.index >= book.readingParagraph {
            guard words < Generator.lookaheadWords else { break }
            if p.rendition(level) == nil { return false }
            words += p.source.split(separator: " ").count
        }
        return true
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // the book's title, as a pull-down listing its chapters
        // (leading, beside the back button: a Mac Catalyst toolbar has no centre slot)
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                ForEach(Array(chapters.enumerated()), id: \.offset) { i, ch in
                    Button { book.currentChapter = i; go(to: nil) } label: {
                        if i == book.currentChapter { Label(ch.title, systemImage: "checkmark") } else { Text(ch.title) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    // narrow on a phone, so the new-words and level buttons keep their place beside it
                    Text(book.title).font(.headline).lineLimit(1)
                        .frame(maxWidth: sizeClass == .compact ? 120 : 320, alignment: .leading)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }
            .accessibilityLabel("Chapters of \(book.title)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            #if targetEnvironment(macCatalyst)
            // a mouse can't pinch: text size buttons (also ⌘- and ⌘+)
            Button { fontSize = max(14, fontSize - 2) } label: { Label("Smaller text", systemImage: "textformat.size.smaller") }
                .keyboardShortcut("-", modifiers: .command)
            Button { fontSize = min(36, fontSize + 2) } label: { Label("Larger text", systemImage: "textformat.size.larger") }
                .keyboardShortcut("=", modifiers: .command)
            #endif

            // dark or light pages, whatever the system is set to
            Button { readerScheme = colorScheme == .dark ? "light" : "dark" } label: {
                Label(colorScheme == .dark ? "Light pages" : "Dark pages", systemImage: colorScheme == .dark ? "sun.max" : "moon")
            }

            Button { showNewWords.toggle() } label: {
                Label(showNewWords ? "Hide new words" : "Show new words", systemImage: showNewWords ? "eye" : "eye.slash")
            }
            .tint(showNewWords ? .accentColor : nil)

            // on a phone the level menu is the line under the chapter heading instead (the toolbar is full)
            if sizeClass != .compact {
                levelMenu {
                    Text(book.level.label(original: book.isOriginal)).font(.headline).lineLimit(1)
                }
            }


        }
    }

    // MARK: - Actions

    /// Makes text for the next few pages from this paragraph on (see Generator.lookaheadWords).
    private func generate(from index: Int) {
        guard let chapter else { return }
        generator.ensure(chapter: chapter, book: book, from: index)
    }

    private func refreshLearning() {
        learningLemmas = Set(Learner.learning(book.language, in: context, limit: 500).map { $0.lemma.lowercased() })
    }

    private func tapped(_ token: WordToken, _ gloss: Gloss?, in paragraph: Paragraph) {
        // shade the sentence, and the sentence in the same place in the other column; a second tap clears it
        if pick?.paragraph == paragraph.uid && pick?.target == [token.sentenceIndex] {
            pick = nil
        } else {
            let text = paragraph.rendition(paragraph.effectiveLevel(book: book))?.text ?? ""
            let side = paragraph.side(book: book).map { SentenceShade.counterpart(of: token.sentenceIndex, in: text, side: $0) } ?? []
            pick = (paragraph.uid, [token.sentenceIndex], side)
        }
        guard let gloss else { card = nil; return }
        card = WordCard(word: token.core, lemma: gloss.lemma, meaning: gloss.meaning,
                        isLearning: learningLemmas.contains(gloss.lemma.lowercased()))
    }

    /// A tap on a sentence in the side column (landscape): shade it, and the sentences beside it in the
    /// language being learned. A second tap clears it.
    private func tappedSide(_ sentence: String, in paragraph: Paragraph) {
        guard let side = paragraph.side(book: book),
              let text = paragraph.rendition(paragraph.effectiveLevel(book: book))?.text else { return }
        let all = SentenceShade.sentences(side)
        guard let index = all.firstIndex(where: { $0.text == sentence || $0.text.contains(sentence) || sentence.contains($0.text) }) else { return }
        if pick?.paragraph == paragraph.uid && pick?.side == [all[index].text] { pick = nil; return }
        pick = (paragraph.uid, Set(SentenceShade.counterparts(of: index, in: side, other: text)), [all[index].text])
        card = nil
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

/// Serif text set at the size that fills the space it is given: as large as fits, no larger.
struct FittedText: View {
    let text: String
    /// Sentences to shade (the counterpart of the one the reader tapped).
    var shaded: [String] = []
    /// Words to mark faintly: the meanings of the new words highlighted in the other column.
    var faint: [String] = []
    /// Called with the sentence tapped, when the text is tappable.
    var onTapSentence: ((String) -> Void)? = nil

    private var attributed: AttributedString {
        var a = AttributedString(text)
        let lower = text.lowercased()
        for term in faint where term.count > 1 {
            var from = lower.startIndex
            while let r = lower.range(of: term.lowercased(), range: from..<lower.endIndex) {
                from = r.upperBound
                // whole words only ("rocks", not "rocksteady")
                let before = r.lowerBound == lower.startIndex ? nil : lower[lower.index(before: r.lowerBound)]
                let after = r.upperBound == lower.endIndex ? nil : lower[r.upperBound]
                guard !(before?.isLetter ?? false), !(after?.isLetter ?? false) else { continue }
                let lo = text.distance(from: text.startIndex, to: r.lowerBound), n = text.distance(from: r.lowerBound, to: r.upperBound)
                let start = a.index(a.startIndex, offsetByCharacters: lo), end = a.index(start, offsetByCharacters: n)
                a[start..<end].backgroundColor = Color.yellow.opacity(0.2)
            }
        }
        for s in shaded where !s.isEmpty {
            if let r = a.range(of: s) { a[r].backgroundColor = SentenceShade.color; continue }
            // a sentence split over two pages: shade the part on this page (its start, or its end)
            let words = s.split(separator: " ")
            for k in stride(from: words.count - 1, through: 2, by: -1) {
                let start = words.prefix(k).joined(separator: " "), end = words.suffix(k).joined(separator: " ")
                if text.hasSuffix(start), let r = a.range(of: start, options: .backwards) { a[r].backgroundColor = SentenceShade.color; break }
                if text.hasPrefix(end), let r = a.range(of: end) { a[r].backgroundColor = SentenceShade.color; break }
            }
        }
        return a
    }

    var body: some View {
        GeometryReader { geo in
            let size = Self.size(text, in: geo.size)
            let t = Text(attributed)
                .font(.system(size: size, design: .serif))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let onTapSentence {
                t.contentShape(Rectangle())
                    .onTapGesture { point in
                        if let s = Self.sentence(at: point, in: text, size: size, width: geo.size.width) { onTapSentence(s) }
                    }
            } else {
                t.textSelection(.enabled)
            }
        }
    }

    private static func serif(_ size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size)
        return base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
    }

    /// The sentence at a point, laying the text out as it is drawn (same font, size and width).
    static func sentence(at point: CGPoint, in text: String, size: CGFloat, width: CGFloat) -> String? {
        let storage = NSTextStorage(string: text, attributes: [.font: serif(size)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var fraction: CGFloat = 0
        let i = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard i < storage.length, let at = Range(NSRange(location: i, length: 0), in: text)?.lowerBound else { return nil }
        var found: String?
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, r, _, stop in
            if r.contains(at) || r.upperBound == at { found = sub?.trimmingCharacters(in: .whitespacesAndNewlines); stop = true }
        }
        return found
    }

    /// The largest font size (between 9 and 32 points) at which `text`, wrapped to the width, is no taller
    /// than the height. Found by halving the range, measuring with the same serif font.
    static func size(_ text: String, in box: CGSize) -> CGFloat {
        guard box.width > 0, box.height > 0 else { return 17 }
        func height(_ size: CGFloat) -> CGFloat {
            let font = serif(size)
            return ceil((text as NSString).boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
                                                         options: [.usesLineFragmentOrigin], attributes: [.font: font], context: nil).height)
        }
        var low: CGFloat = 9, high: CGFloat = 32
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if height(mid) <= box.height { low = mid } else { high = mid }
        }
        return low
    }
}

/// What one page shows of one paragraph: all of it, or the lines that fit.
struct PageItem: Identifiable {
    let paragraph: Paragraph
    /// The words on this page (by position in the paragraph's text); 0..<Int.max for all of them.
    let words: Range<Int>
    let wordCount: Int
    var id: String { "\(paragraph.uid)-\(words.lowerBound)" }
    var isWhole: Bool { words.lowerBound == 0 && words.upperBound >= wordCount }

    /// The same share of another text (the side column, or the source while the text is being made).
    func share(of text: String) -> String {
        guard !isWhole, wordCount > 0 else { return text }
        let words = text.split(whereSeparator: \.isWhitespace)
        let from = words.count * self.words.lowerBound / wordCount
        let to = self.words.upperBound >= wordCount ? words.count : words.count * self.words.upperBound / wordCount
        return words[from..<max(from, to)].joined(separator: " ")
    }
}

/// A label style chosen at run time.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(Label($0).labelStyle(style)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon }
    }
}

// MARK: - Paragraph

struct ParagraphRow: View {
    let paragraph: Paragraph
    /// The part of the paragraph on this page.
    var words: Range<Int> = 0..<Int.max
    var wordCount: Int = Int.max
    let book: Book
    let landscape: Bool
    let showNewWords: Bool
    /// The sentence of this paragraph the reader tapped, if any, and its counterpart in the side column.
    var selectedSentences: Set<Int> = []
    var shadedSide: [String] = []
    let learningLemmas: Set<String>
    let onTap: (WordToken, Gloss?) -> Void
    let onDoubleTap: (WordToken, Gloss?) -> Void
    /// A sentence of the side column was tapped.
    var onTapSide: (String) -> Void = { _ in }
    let onShown: (Rendition) -> Void
    @Environment(\.modelContext) private var context
    private var generator: Generator { Generator.shared }

    /// The meanings of this paragraph's highlighted words ("shook, rattled" → "shook", "rattled"; "to wait" → "wait").
    private func faintTerms(_ level: Level) -> [String] {
        guard let r = paragraph.rendition(level) else { return [] }
        return r.glossary.filter { $0.isNew || learningLemmas.contains($0.lemma.lowercased()) }
            .flatMap { $0.meaning.split(whereSeparator: { ",;/".contains($0) }) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("to ") ? String($0.dropFirst(3)) : $0 }
            .filter { !$0.isEmpty }
    }

    private var part: PageItem { PageItem(paragraph: paragraph, words: words, wordCount: wordCount) }

    var body: some View {
        let level = paragraph.effectiveLevel(book: book)
        Group {
            if landscape {
                HStack(alignment: .top, spacing: 28) {
                    target(level).frame(maxWidth: .infinity, alignment: .leading)
                    // the side column takes its height from the paragraph beside it, and its font size is
                    // worked out so its text fills exactly that height: the two columns line up paragraph by paragraph
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .topLeading) {
                            let side = paragraph.side(book: book).map { part.share(of: $0) }
                            FittedText(text: side ?? "\(book.native.name) translation on its way…", shaded: shadedSide,
                                       faint: showNewWords ? faintTerms(level) : [],
                                       onTapSentence: side == nil ? nil : onTapSide)
                                .foregroundStyle(side == nil ? .tertiary : .secondary)
                        }
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
            if paragraph.overrideLevel != nil && words.lowerBound == 0 {
                Text(level.label(original: book.isOriginal))
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }
            if let r = paragraph.rendition(level) {
                WordFlowText(rendition: r, language: book.language, showNewWords: showNewWords,
                             learningLemmas: learningLemmas, onTap: onTap, onDoubleTap: onDoubleTap,
                             words: part.isWhole ? nil : words, selectedSentences: selectedSentences)
                    .task(id: r.text) { onShown(r) }
            } else if let err = generator.failure(paragraph, level) {
                Button {
                    generator.retry(paragraph, book: book)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(part.share(of: paragraph.source)).foregroundStyle(.secondary)
                        Label("Couldn't translate — tap to try again. \(err)", systemImage: "arrow.clockwise")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .buttonStyle(.plain)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(part.share(of: paragraph.source))
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
            Button("Same as the book (\(book.level.label(original: book.isOriginal)))") {
                paragraph.overrideLevel = nil
                try? context.save()
            }
        }
    }
}

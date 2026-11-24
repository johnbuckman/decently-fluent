import SwiftUI
import SwiftData
import WebKit

/// What the address bar's text means: a web address, or words to search for.
enum AddressBar {
    static func url(for input: String, searchLanguage: Language) -> URL? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // words with spaces between them are a search, even after an address ("example.com recipes")
        if !t.contains(where: \.isWhitespace), let u = URL(string: t), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host != nil { return u }
        // looks like an address: no spaces, a dot, and a plausible ending ("example.com", "fr.wikipedia.org/wiki/Paris")
        if !t.contains(" "), t.contains("."), let host = t.split(separator: "/").first,
           host.split(separator: ".").last.map({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) == true,
           let u = URL(string: "https://" + t) { return u }
        if t.hasPrefix("localhost"), let u = URL(string: "http://" + t) { return u }
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: t), URLQueryItem(name: "hl", value: searchLanguage.rawValue)]
        return c.url
    }
}

extension URL {
    /// A page on one of Google's sites (google.com, google.fr, google.co.uk, maps.google.com…): shown as it is,
    /// never rewritten.
    var isGoogle: Bool {
        guard let host = host?.lowercased() else { return false }
        return host.range(of: #"(^|\.)google\.(com|co\.[a-z]{2}|com\.[a-z]{2}|[a-z]{2})$"#, options: .regularExpression) != nil
    }
}

/// Passes the page script's messages on without the web view keeping its owner alive.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WebModel?
    let original: Bool
    init(_ target: WebModel, original: Bool) { self.target = target; self.original = original }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.received(message.body, original: original) }
    }
}

/// The browser: the page in the language being learned, and (landscape) the page as written beside it.
@MainActor
@Observable
final class WebModel: NSObject, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
    let translated: WKWebView
    let original: WKWebView
    let translator: WebTranslator

    var address = ""
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress: Double = 0
    var card: WordCard?
    var showNewWords = false { didSet { run("window.__df && __df.showNew(\(showNewWords))", in: translated) } }
    /// Whether the original page is showing beside the translated one.
    var sideBySide = false { didSet { if sideBySide { followOriginal() } } }

    /// The page the reader is scrolling, which the other follows.
    private var leader: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    private var context: ModelContext?
    private var learningLemmas: Set<String> = []

    init(language: Language, native: Language, level: Level) {
        translator = WebTranslator(language: language, native: native, level: level)
        translated = WebModel.makeView(mode: "translate")
        original = WebModel.makeView(mode: "original")
        super.init()
        for (view, isOriginal) in [(translated, false), (original, true)] {
            view.configuration.userContentController.add(MessageProxy(self, original: isOriginal), name: "df")
            view.navigationDelegate = self
            view.uiDelegate = self
        }
        translator.onReady = { [weak self] id, r in self?.deliver(id, r) }
        // double-taps on words: WebKit keeps the second tap of a double-tap for itself, so they're caught here,
        // alongside WebKit's own gestures
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        translated.addGestureRecognizer(tap)
        observations = [
            translated.observe(\.canGoBack) { [weak self] v, _ in MainActor.assumeIsolated { self?.canGoBack = v.canGoBack } },
            translated.observe(\.canGoForward) { [weak self] v, _ in MainActor.assumeIsolated { self?.canGoForward = v.canGoForward } },
            translated.observe(\.isLoading) { [weak self] v, _ in MainActor.assumeIsolated { self?.isLoading = v.isLoading } },
            translated.observe(\.estimatedProgress) { [weak self] v, _ in MainActor.assumeIsolated { self?.progress = v.estimatedProgress } },
            translated.observe(\.title) { [weak self] v, _ in MainActor.assumeIsolated { self?.title = v.title ?? "" } },
            translated.observe(\.url) { [weak self] v, _ in
                MainActor.assumeIsolated {
                    guard let self, let u = v.url else { return }
                    self.address = u.absoluteString
                    if self.sideBySide { self.followOriginal() }
                }
            },
        ]
    }

    private static func makeView(mode: String) -> WKWebView {
        let config = WKWebViewConfiguration()
        let c = config.userContentController
        let start = "window.__dfMode = '\(mode)';"
        c.addUserScript(WKUserScript(source: start, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        c.addUserScript(WKUserScript(source: WebScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.allowsInlineMediaPlayback = true
        let v = WKWebView(frame: .zero, configuration: config)
        v.allowsBackForwardNavigationGestures = true
        #if DEBUG
        if #available(iOS 16.4, *) { v.isInspectable = true }
        #endif
        return v
    }

    func attach(_ context: ModelContext) {
        self.context = context
        refreshLearning()
    }

    // MARK: - Navigation

    func go(_ input: String) {
        guard let u = AddressBar.url(for: input, searchLanguage: translator.language) else { return }
        load(u)
    }

    func load(_ url: URL) {
        address = url.absoluteString
        translated.load(URLRequest(url: url))
    }

    func reloadOrStop() {
        if isLoading { translated.stopLoading() } else { translated.reload() }
    }

    /// The original page shows what the translated one shows.
    private func followOriginal() {
        guard let u = translated.url, !u.isGoogle, original.url != u else { return }
        original.load(URLRequest(url: u))
    }

    /// Ask again for the blocks that failed.
    func retryFailed() {
        translator.clearError()
        run("window.__df && __df.retry()", in: translated)
    }

    /// A new level or language: write the page again.
    func rewrite() {
        translator.start(page: translated.url)
        refreshLearning()
        run("window.__df && __df.reset()", in: translated)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === translated else { return }
        card = nil
        translator.start(page: webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === translated { run("window.__df && __df.showNew(\(showNewWords))", in: translated) }
    }

    /// A link that opens a new window opens here instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url { load(u) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // a link followed in the original page opens in both
        if webView === original, action.navigationType == .linkActivated, let u = action.request.url {
            load(u)
            return .cancel
        }
        return .allow
    }

    // MARK: - Messages from the page script

    fileprivate func received(_ body: Any, original isOriginal: Bool) {
        guard let m = body as? [String: Any], let type = m["type"] as? String else { return }
        let view = isOriginal ? original : translated
        switch type {
        case "need" where !isOriginal && translated.url?.isGoogle != true:
            let blocks = (m["blocks"] as? [[String: Any]] ?? []).compactMap { b -> WebBlock? in
                guard let id = b["id"] as? Int, let t = b["text"] as? String else { return nil }
                return WebBlock(id: id, text: t)
            }
            translator.learningWords = learningWords()
            translator.need(blocks)
            // an original read at Native level: nothing to write, show it as it is
            if translator.showsAsWritten { run("document.querySelectorAll('.df-pending').forEach(e => e.classList.remove('df-pending'))", in: translated) }
        case "tap" where !isOriginal:
            tapped(m, double: false)
        case "dbl" where !isOriginal:
            tapped(m, double: true)
        case "tapOff":
            card = nil
        case "seen" where !isOriginal:
            if let id = m["id"] as? Int { sighted(id) }
        case "lead":
            leader = view
        case "scroll":
            guard sideBySide, (leader ?? translated) === view, let key = m["key"] as? String,
                  let quoted = try? JSONSerialization.data(withJSONObject: key, options: .fragmentsAllowed),
                  let js = String(data: quoted, encoding: .utf8) else { return }
            let frac = m["frac"] as? Double ?? 0, below = m["below"] as? Double ?? 0
            let edge = (m["edge"] as? String).flatMap { ["top", "bottom"].contains($0) ? $0 : nil } ?? ""
            let other = isOriginal ? translated : original
            run("window.__df && __df.scrollTo(\(js), \(frac), \(below), '\(edge)')", in: other)
        default: break
        }
    }

    private var texts: [Int: WebRendition] = [:]

    private func deliver(_ id: Int, _ r: WebRendition?) {
        if let r {
            texts[id] = r
            let glossary: [[String: Any]] = r.glossary.map { ["w": $0.surface, "lemma": $0.lemma, "m": $0.meaning, "isNew": $0.isNew] }
            let payload: [String: Any] = ["id": id, "text": r.text, "glossary": glossary]
            guard let data = try? JSONSerialization.data(withJSONObject: [payload]),
                  let json = String(data: data, encoding: .utf8) else { return }
            run("window.__df && __df.apply(\(json))", in: translated)
        } else {
            run("window.__df && __df.failed([\(id)])", in: translated)
        }
    }

    private func run(_ js: String, in view: WKWebView) {
        view.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Words

    private var lastTap: (time: Date, point: CGPoint)?
    private var lastDouble: Date?
    /// How close together two taps make a double-tap.
    private static let doubleTap: TimeInterval = {
        #if DEBUG
        // simulator testing: taps sent one by one are slower than a finger
        if let ms = ProcessInfo.processInfo.environment["DF_DOUBLE_TAP_MS"].flatMap(Double.init) { return ms / 1000 }
        #endif
        return 0.4
    }()

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: translated)
        if let last = lastTap, Date().timeIntervalSince(last.time) < Self.doubleTap, hypot(p.x - last.point.x, p.y - last.point.y) < 24 {
            lastTap = nil
            run("window.__df && __df.wordAt(\(p.x), \(p.y))", in: translated)
        } else {
            lastTap = (Date(), p)
        }
    }

    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private func tapped(_ m: [String: Any], double: Bool) {
        guard let word = m["word"] as? String else { return }
        let lang = translator.language
        let g = m["gloss"] as? [String: Any]
        let lemma = (g?["lemma"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let meaning = (g?["m"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if double { lastDouble = Date() }
        if !double {
            // the page also reports the second tap of a double-tap as a tap: it mustn't close the card
            if let d = lastDouble, Date().timeIntervalSince(d) < 1 { return }
            // a single tap shows a meaning the glossary already has; a second tap on the same word hides it
            guard let lemma, let meaning else { card = nil; return }
            if card?.word == word { card = nil; return }
            card = WordCard(word: word, lemma: lemma, meaning: meaning, isLearning: learningLemmas.contains(lemma.lowercased()))
            return
        }
        guard let context else { return }
        if let lemma, let meaning {
            Learner.markUnknown(lang, lemma: lemma, meaning: meaning, in: context)
            card = WordCard(word: word, lemma: lemma, meaning: meaning, isLearning: true)
            refreshLearning()
            return
        }
        let guess = Lemmatizer.lemma(word, language: lang)
        card = WordCard(word: word, lemma: guess, meaning: nil, isLearning: true)
        let sentence = m["sentence"] as? String ?? word
        let native = translator.native
        Task {
            let found = await Generator.shared.lookUp(word, sentence: sentence, language: lang, native: native)
            let lemma = found?.lemma ?? guess
            Learner.markUnknown(lang, lemma: lemma, meaning: found?.meaning ?? "", in: context)
            if card?.word == word {
                card = WordCard(word: word, lemma: lemma, meaning: found?.meaning ?? "(couldn't look this up)", isLearning: true)
            }
            refreshLearning()
        }
    }

    func markKnown(_ c: WordCard) {
        if let context, let w = Learner.word(translator.language, c.lemma, in: context) { Learner.markKnown(w, in: context) }
        card = nil
        refreshLearning()
    }

    /// A rewritten block came on screen: the reader saw its words.
    private func sighted(_ id: Int) {
        guard let context, let r = texts[id] else { return }
        var lemmas = Set(Lemmatizer.lemmas(in: r.text, language: translator.language))
        lemmas.formUnion(r.glossary.map { $0.lemma.lowercased() })
        Learner.recordSighting(lemmas: lemmas, language: translator.language, in: context)
    }

    private func refreshLearning() {
        guard let context else { return }
        learningLemmas = Set(Learner.learning(translator.language, in: context, limit: 500).map { $0.lemma.lowercased() })
    }

    private func learningWords() -> [String] {
        guard let context else { return [] }
        return Learner.learning(translator.language, in: context).map { "\($0.lemma) (\($0.meaning))" }
    }
}

/// Shows a WKWebView the model owns.
struct WebViewHost: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct WebBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage("guide.language") private var languageRaw = Language.french.rawValue
    @AppStorage("nativeLanguage") private var nativeRaw = Language.english.rawValue
    /// The browser's level, starting at the one chosen in the book guide.
    @AppStorage("web.level") private var levelRaw = UserDefaults.standard.string(forKey: "guide.level") ?? Level.b1.rawValue
    @State private var model: WebModel
    @State private var typed = ""
    @FocusState private var editing: Bool
    /// Translation languages the free service needs, being downloaded from the error's Download button.
    @State private var downloadPair: (source: String, target: String)?
    let start: URL?

    init(start: URL?) {
        self.start = start
        let d = UserDefaults.standard
        let lang = Language(rawValue: d.string(forKey: "guide.language") ?? "") ?? .french
        let native = Language(rawValue: d.string(forKey: "nativeLanguage") ?? "") ?? .english
        let level = Level(rawValue: d.string(forKey: "web.level") ?? d.string(forKey: "guide.level") ?? "") ?? .b1
        _model = State(initialValue: WebModel(language: lang, native: native, level: level))
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let wide = geo.size.width >= 600
            VStack(spacing: 0) {
                topBar(wide: wide)
                ZStack(alignment: .top) {
                    HStack(spacing: 0) {
                        WebViewHost(view: model.translated)
                        // Google's pages aren't rewritten, so there's nothing to show beside them
                        if landscape && model.translated.url?.isGoogle != true {
                            Divider()
                            WebViewHost(view: model.original)
                        }
                    }
                    if model.isLoading {
                        ProgressView(value: model.progress).progressViewStyle(.linear).tint(.accentColor)
                    }
                }
                .overlay(alignment: .bottom) { overlays }
                if !wide { bottomBar }
            }
            .onAppear { model.sideBySide = landscape }
            .onChange(of: landscape) { _, l in model.sideBySide = l }
        }
        .task {
            model.attach(context)
            if let start { model.load(start) } else if model.translated.url == nil { editing = true }
        }
        .onChange(of: model.address) { _, a in if !editing { typed = a } }
        // once the languages are downloaded, write the parts of the page that failed again
        .modifier(AppleTranslationDownload(pair: $downloadPair) { model.retryFailed() })
    }

    // MARK: - Bars

    private func topBar(wide: Bool) -> some View {
        HStack(spacing: 14) {
            if wide {
                closeButton
                navButtons
            }
            HStack(spacing: 6) {
                Image(systemName: model.translated.url?.scheme == "https" ? "lock.fill" : "magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Search or enter website", text: $typed)
                    .focused($editing)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { model.go(typed); editing = false }
                    .onChange(of: editing) { _, e in if !e { typed = model.address } }
                    // the whole address is selected when the field is tapped, so typing replaces it (as in Safari)
                    .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { n in
                        guard let field = n.object as? UITextField else { return }
                        DispatchQueue.main.async { field.selectAll(nil) }
                    }
                if editing && !typed.isEmpty {
                    Button { typed = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
                Button { model.reloadOrStop() } label: {
                    Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isLoading ? "Stop" : "Reload")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            if wide {
                levelMenu
                newWordsButton
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private var bottomBar: some View {
        HStack {
            closeButton
            Spacer()
            navButtons
            Spacer()
            levelMenu
            Spacer()
            newWordsButton
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(.bar)
    }

    private var closeButton: some View {
        Button { dismiss() } label: { Label("Library", systemImage: "books.vertical") }
            .labelStyle(.iconOnly)
    }

    private var navButtons: some View {
        HStack(spacing: 22) {
            Button { model.translated.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!model.canGoBack).accessibilityLabel("Back")
            Button { model.translated.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!model.canGoForward).accessibilityLabel("Forward")
        }
    }

    private var newWordsButton: some View {
        Button { model.showNewWords.toggle() } label: {
            Label(model.showNewWords ? "Hide new words" : "Show new words", systemImage: model.showNewWords ? "eye" : "eye.slash")
        }
        .labelStyle(.iconOnly)
        .tint(model.showNewWords ? .accentColor : nil)
    }

    private var levelMenu: some View {
        Menu {
            Picker("Level", selection: Binding(get: { model.translator.level }, set: { l in
                levelRaw = l.rawValue
                model.translator.level = l
                model.rewrite()
            })) {
                ForEach(Level.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Learning", selection: Binding(get: { model.translator.language }, set: { l in
                languageRaw = l.rawValue
                model.translator.language = l
                model.rewrite()
            })) {
                ForEach(Language.allCases.filter { $0 != model.translator.native }) { Text("Learning \($0.name)").tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(model.translator.level.rawValue)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.tint, lineWidth: 1.2))
        }
        .accessibilityLabel("Level: \(model.translator.level.label)")
    }

    // MARK: - Overlays

    /// "12 s", "about 2 min".
    static func duration(_ seconds: Int) -> String {
        seconds < 90 ? "\(max(1, seconds)) s" : "\(Int((Double(seconds) / 60).rounded())) min"
    }

    @ViewBuilder private var overlays: some View {
        VStack(spacing: 8) {
            if let error = model.translator.lastError {
                HStack(spacing: 10) {
                    Text(error).font(.footnote)
                    if let pair = model.translator.missingLanguages {
                        Button("Download") { downloadPair = pair }.font(.footnote.weight(.semibold))
                    } else {
                        Button("Try again") { model.retryFailed() }.font(.footnote.weight(.semibold))
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            } else if model.translator.busy > 0 {
                // a bar and a time estimate, like the book reader's
                TimelineView(.periodic(from: .now, by: 0.5)) { tl in
                    if let p = model.translator.progress(at: tl.date) {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: p.fraction)
                            HStack {
                                Text("Writing in \(model.translator.language.name) at \(model.translator.level.rawValue)…")
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(p.overdue ? "\(p.done) of \(p.total) · taking longer than usual"
                                     : "\(p.done) of \(p.total) · about \(Self.duration(p.secondsLeft)) left")
                                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: 420)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            if let card = model.card {
                GlossCardView(card: card, onKnown: { model.markKnown(card) }, onClose: { model.card = nil })
                    .frame(maxWidth: 520)
            }
        }
        .padding(12)
        .animation(.easeOut(duration: 0.2), value: model.card)
    }
}

# Decently Fluent

A graded-reader generator for iPhone, iPad and Mac, for learners of English, French, German, Spanish or Italian whose own language is one of the others. Read a book retold in the language you're learning at your CEFR level (A1–C1, or the fluent "Native" translation) — or read an original, simplified to your level, with your own language beside it. Where Project Gutenberg has a published human translation, the app uses it instead of machine translation.

## What it does

- **Graded rewriting, only as you read.** Only the next few pages (about 1,500 words) are rewritten, keeping just ahead of you as you scroll, so you can change level at any point and no AI credits go on pages you never reach. Each level follows the rules published graded readers use: a capped vocabulary, the tenses allowed at that level, short sentences, and a limited number of new words per 100 words. Once a level is made it is kept.
- **Change the level of any paragraph** by long-pressing it.
- **Your language and the one you're learning:** any two of English, French, German, Spanish and Italian (chosen in the book guide or Settings). Word meanings and the side column are in your language.
- **Portrait** shows only the language you're learning. **Landscape** puts it on the left and your language on the right, paragraph by paragraph: the book as written, a published translation, or a machine translation.
- **Human translations first.** The catalog knows which Gutenberg books are the same work in different languages. When you add a book that has one, the app downloads that edition too, matches its chapters, and lines its paragraphs up with the book's (keeping the translator's words). It is then the Native level, the starting point for simpler levels, and the side column. Chapters that can't be lined up fall back to machine translation, and the reader says so.
- **New words** (highlighter button): highlights the words this book has just introduced at your level and shows their meaning underneath. Tap a highlighted word for its meaning.
- **Double-tap a word you don't know.** It shows the meaning and adds the word to *My words*. Later paragraphs reuse it where it fits. After you've seen it 4 times, on at least 2 different days, without double-tapping it again, it counts as learned.
- **Wikipedia:** each book's page shows its plot summary from Wikipedia (in your language where there is an article, else English) with a link to the article.
- **Find a book for me:** a short guide (your language and the one you're learning, retold or original, level, favourite kinds of story, minutes a day), then books from the bundled Project Gutenberg catalog ranked by research on learning from reading — mostly Paul Nation's — with every reason and its source shown (`Sources/Research.swift`).
- **Open books from anywhere:** Files, another app's share sheet, or AirDrop (EPUB, PDF, text). The app detects the book's language and asks whether to read the original or retell it.
- **Recycling:** each book keeps a list of the words each level has introduced and asks the writer to reuse them until each has been seen 5 times, as graded readers do.

## Build

```bash
xcodegen generate
xcodebuild -project DecentlyFluent.xcodeproj -scheme DecentlyFluent -destination 'platform=iOS Simulator,name=iPhone 17e' -derivedDataPath build-sim build
```

Translation needs an API key, entered in Settings (stored in the Keychain): Claude (default `claude-opus-5-5`) or DeepSeek (`deepseek-flash`).

For simulator testing without typing a key, pass it in the launch environment:

```bash
SIMCTL_CHILD_DF_PROVIDER=deepseek SIMCTL_CHILD_DF_DEEPSEEK_KEY=sk-… xcrun simctl launch booted com.decentespresso.decentlyfluent
```

(`DF_ANTHROPIC_KEY` for Claude.)

### Dev bridge: a Claude Code session answers instead of an API

Debug builds offer a third service, **Claude Code (dev bridge)**. The app sends its requests to a small server on the Mac (`http://localhost:8793/llm`), and a Claude Code session answers them. There's no API key or cost; it's for testing only (each request waits up to 30 minutes for an answer).

```bash
python3 tools/claude_bridge.py
```

Then launch with `SIMCTL_CHILD_DF_PROVIDER=bridge`, or pick it in Settings. Each request appears as `tools/queue/<id>.request.json` (`python3 tools/claude_bridge.py --pending` lists the waiting ones). Claude Code writes the JSON answer to `tools/queue/<id>.answer.json`, and the app carries on. To wait for the next request:

```bash
until python3 tools/claude_bridge.py --pending | grep -q request; do sleep 2; done
```

## The book catalog

`Resources/catalog.sqlite` holds Project Gutenberg's novels, stories, plays and tales in English, French, German, Spanish and Italian, built by `tools/build_catalog.py` from Gutenberg's RDF catalog (Gutenberg asks tools to use it rather than crawl the site). The most read 700 English and 300 each French, German, Spanish and Italian books are measured from their full text: length, chapters, sentence length, dialogue, old-fashioned or dialect English, and vocabulary coverage (share of words among the 2,000 / 5,000 most common in that language). Books whose Gutenberg record names a translator are flagged `translated` (with the translator's name). Many translations name none, so DeepSeek is also asked which language each author wrote in (for authors with books in several languages), and books in any other language are flagged too. Originals and translations are offered separately in the book guide ("originally written in" and "professionally translated into"). The `editions` table groups books that are the same work in different languages: candidates share a Gutenberg author record, and DeepSeek decides which titles match, one request per author, cached in a JSON file. Rebuild:

```bash
DEEPSEEK_API_KEY=sk-… python3 tools/build_catalog.py rdf --analyse 700 300 300 300 300 --cache texts --editions tools/editions-cache.json --out Resources/catalog.sqlite
```

Book texts are fetched from Gutenberg mirrors, measured and discarded. Book files themselves are downloaded from gutenberg.org when the reader picks one.

## Code map

| File | What's in it |
| --- | --- |
| `Sources/Models.swift` | SwiftData models (Book, Chapter, Paragraph, LearnerWord), CEFR level rules |
| `Sources/Importer.swift` | EPUB (zip or Apple Books folder), PDF and text import; a small zip reader |
| `Sources/LLM.swift` | Claude and DeepSeek clients, retries, Keychain |
| `Sources/Generator.swift` | The translation queue, the graded-reader prompt, recycling of introduced words |
| `Sources/Learning.swift` | Lemmas (NaturalLanguage), double-tap tracking and when a word counts as learned |
| `Sources/Catalog.swift` | Reads the bundled SQLite catalog: measured books, shelves, full-text search |
| `Sources/Research.swift` | The research findings behind recommendations, with sources |
| `Sources/Recommender.swift` | Scores books for a reader's profile and gives the reasons |
| `Sources/DiscoverView.swift` | The book guide, recommendations, "why this book", the research pages |
| `Sources/Gutenberg.swift` | Downloads a book; removes Gutenberg's licence pages |
| `Sources/ImportChoiceView.swift` | Opening a book from Files, sharing or AirDrop; language detection |
| `Sources/LearnerFit.swift` | Judges an unmeasured book after download |
| `Sources/ReaderView.swift`, `WordFlow.swift` | The reader: tappable word layout, labels, gloss card, landscape view |

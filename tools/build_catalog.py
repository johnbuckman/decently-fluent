#!/usr/bin/env python3
"""Builds Resources/catalog.sqlite: the Project Gutenberg books the app can offer.

    python3 tools/build_catalog.py <rdf-dir> [--analyse N_EN N_FR N_DE N_ES N_IT] [--cache <dir>]
        [--editions <cache.json>] [--out Resources/catalog.sqlite]

<rdf-dir> is the unpacked https://www.gutenberg.org/cache/epub/feeds/rdf-files.tar.bz2
(Gutenberg asks that tools use these files instead of crawling the website).

Step 1 keeps fiction, plays and tales in English, French, German, Spanish and Italian, with their
subjects, shelves, download counts, text size and translator. Step 2 downloads the texts of the most downloaded
books from Gutenberg mirrors, measures them for learners and throws them away:

  words, chapters, words per chapter, words per sentence, share of paragraphs with dialogue,
  old-fashioned and dialect words per 10,000 (English), and lexical coverage: the share of
  running words that are among the 2,000 / 5,000 most common words of that language (Nation's
  lexical profile; proper nouns count as known, as in Hu & Nation 2000). The frequency list
  is built from the analysed books themselves, ranked by how many books a word appears in.

Step 3 (--editions) finds the same work in several languages: an original and its human translations,
or two translations of one original. Candidates share a Gutenberg author record; DeepSeek (key in
DEEPSEEK_API_KEY) decides which titles are the same work, one request per author, cached in the
JSON file so rebuilds only ask about new books.
"""
import collections, concurrent.futures as cf, glob, json, math, os, re, sqlite3, sys, time, unicodedata, urllib.error, urllib.request
import xml.etree.ElementTree as ET

NS = {
    "rdf": "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    "dcterms": "http://purl.org/dc/terms/",
    "pgterms": "http://www.gutenberg.org/2009/pgterms/",
    "dcam": "http://purl.org/dc/dcam/",
    "marcrel": "http://id.loc.gov/vocabulary/relators/",
}
LANGS = {"en", "fr", "de", "es", "it"}
MIN_DOWNLOADS = {"en": 150, "fr": 20, "de": 20, "es": 20, "it": 20}

# shelf key -> words found in a book's subjects or bookshelves (lower case)
CATEGORIES = {
    "short": ["short stories", "short story"],
    "mystery": ["detective", "mystery", "crime", "policiers", "kriminal", "policiaca", "gialli"],
    "adventure": ["adventure", "sea stories", "pirates", "western stories", "voyages", "aventures", "abenteuer"],
    "tales": ["fairy tales", "fables", "folklore", "legends", "contes", "märchen", "fairy", "cuentos de hadas", "fiabe"],
    "plays": ["drama", "plays", "comedies", "tragedies", "théâtre", "theater", "teatro"],
    "scifi": ["science fiction", "fantasy", "fantastic fiction", "utopias"],
    "children": ["juvenile fiction", "children's", "children"],
    "humour": ["humor", "humorous", "satire", "comic"],
    "ghost": ["ghost stories", "horror", "supernatural"],
    "romance": ["love stories", "romance fiction"],
    "historical": ["historical fiction", "history -- fiction"],
}
FICTION_HINTS = ["fiction", "stories", "tales", "novel", "romans", "roman", "erzählungen", "novellen", "drama", "plays",
                 "comedies", "fables", "fairy", "contes", "nouvelles", "märchen", "théâtre", "novela", "cuentos",
                 "teatro", "romanzo", "romanzi", "racconti", "novelle"]
NOT_FICTION = ["poetry", "poems", "poésie", "gedichte", "lyrik", "poesía", "poesia", "periodicals", "dictionaries",
               "cookery", "sermons"]


def text_of(el, path):
    found = el.find(path, NS)
    return found.text.strip() if found is not None and found.text else ""


def parse_rdf(path):
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        return None
    eb = root.find("pgterms:ebook", NS)
    if eb is None:
        return None
    m = re.search(r"ebooks/(\d+)", eb.get(f"{{{NS['rdf']}}}about", ""))
    if not m:
        return None
    if text_of(eb, "dcterms:type/rdf:Description/rdf:value") != "Text":
        return None
    langs = [v.text for v in eb.findall("dcterms:language/rdf:Description/rdf:value", NS) if v.text]
    if len(langs) != 1 or langs[0] not in LANGS:
        return None
    authors, years = [], ""
    for ag in eb.findall("dcterms:creator/pgterms:agent", NS):
        name = text_of(ag, "pgterms:name")
        if name:
            # "Doyle, Arthur Conan" -> "Arthur Conan Doyle"; "Wells, H. G. (Herbert George)" -> "H. G. Wells"
            plain = re.sub(r"\s*\([^)]*\)", "", name).strip()
            parts = plain.split(", ", 1)
            authors.append(f"{parts[1]} {parts[0]}" if len(parts) == 2 and "," not in parts[1] else plain)
            if not years:
                b, d = text_of(ag, "pgterms:birthdate"), text_of(ag, "pgterms:deathdate")
                years = f"{b}–{d}" if b or d else ""
    # a translator means the text was not written in this language
    translators = [text_of(t, "pgterms:agent/pgterms:name") for t in eb.findall("marcrel:trl", NS)]
    translators = [re.sub(r"\s*\([^)]*\)", "", t).strip() for t in translators if t]
    translators = [f"{t.split(', ', 1)[1]} {t.split(', ', 1)[0]}" if ", " in t else t for t in translators]
    translated = eb.find("marcrel:trl", NS) is not None
    agents = [ag.get(f"{{{NS['rdf']}}}about", "").rsplit("/", 1)[-1] for ag in eb.findall("dcterms:creator/pgterms:agent", NS)]
    subjects = [v.text for v in eb.findall("dcterms:subject/rdf:Description/rdf:value", NS) if v.text]
    shelves = [v.text for v in eb.findall("pgterms:bookshelf/rdf:Description/rdf:value", NS) if v.text]
    txt_bytes = 0
    for f in eb.findall("dcterms:hasFormat/pgterms:file", NS):
        about = f.get(f"{{{NS['rdf']}}}about", "")
        if about.endswith((".txt.utf-8", ".txt")) and not about.endswith(".zip"):
            ext = text_of(f, "dcterms:extent")
            if ext.isdigit():
                txt_bytes = max(txt_bytes, int(ext))
    title = text_of(eb, "dcterms:title").replace("\r", "").replace("\n", " — ")
    # library-catalog subfield markers: "Lucifer : $b roman moderne" -> "Lucifer: roman moderne"
    title = re.sub(r"\s*:\s*\$[a-z]\s*", ": ", title).replace(" ;", ";").strip(" :")
    return {
        "id": int(m.group(1)), "title": title, "author": " & ".join(authors[:2]), "years": years,
        "language": langs[0], "downloads": int(text_of(eb, "pgterms:downloads") or 0),
        "subjects": subjects, "shelves": shelves, "txt_bytes": txt_bytes,
        "issued": text_of(eb, "dcterms:issued"), "translated": translated,
        "translator": " & ".join(translators[:2]), "agents": [a for a in agents if a],
    }


def classify(b):
    hay = " | ".join(b["subjects"] + b["shelves"]).lower()
    cats = [k for k, words in CATEGORIES.items() if any(w in hay for w in words)]
    fiction = bool(cats) or any(h in hay for h in FICTION_HINTS) or re.search(r"\bP[QRSTZ]\b", " ".join(b["subjects"]))
    if any(n in hay for n in NOT_FICTION) and not cats:
        return None
    return cats if fiction else None


# --- step 2: measuring a text -------------------------------------------------------------

WORD = re.compile(r"[A-Za-zÀ-ÖØ-öø-ÿŒœ]+(?:['’][A-Za-zÀ-ÖØ-öø-ÿ]+)*")
CHAPTER = re.compile(r"^\s*(chapter|chapitre|kapitel|capítulo|capitulo|capitolo|book|livre|buch|libro|act|acte|akt|acto|atto|"
                     r"scene|scène|escena|scena|part|partie|teil|parte|[ivxlc]+\.?|\d+\.?)\b[^\n]{0,60}$", re.I | re.M)
ARCHAIC = {"thee", "thou", "thy", "thine", "hath", "doth", "'tis", "’tis", "ere", "whilst", "shalt", "wilt", "hast", "dost",
           "nay", "aye", "betwixt", "wherefore", "methinks"}
DIALECT = {"ain't", "ain’t", "'em", "warn't", "gwine", "dat", "dem", "dey", "nothin'", "yer", "ye", "jes'", "'bout"}
# speech marks: English double or single curly quotes; French guillemets or a dash ("--" in Gutenberg texts)
# opening a line; German „…“, »…« or a dash; Spanish and Italian a dash (raya) opening a line, or «…» / “…”
DIALOGUE = {"en": re.compile(r"[\"“‘]|(?:^|\s)'[A-Z]"),
            "fr": re.compile(r"[«»\"“]|^\s*(?:--|[—–])"),
            "de": re.compile(r"[„“»«\"‚]|^\s*(?:--|[—–])"),
            "es": re.compile(r"[«»\"“]|^\s*(?:--|-|[—–])"),
            "it": re.compile(r"[«»\"“]|^\s*(?:--|-|[—–])")}


MIRRORS = ["https://mirror.csclub.uwaterloo.ca/gutenberg", "http://mirrors.xmission.com/gutenberg",
           "https://mirrors.ocf.berkeley.edu/gutenberg"]


CACHE = None  # --cache <dir>: keep downloaded texts (gzipped) so rebuilds don't fetch them again


def fetch(book_id):
    if CACHE:
        import gzip
        path = os.path.join(CACHE, f"{book_id}.txt.gz")
        if os.path.exists(path):
            return gzip.open(path, "rt", encoding="utf-8").read()
        text = fetch_mirror(book_id)
        if text:
            with gzip.open(path, "wt", encoding="utf-8") as f:
                f.write(text)
        return text
    return fetch_mirror(book_id)


def fetch_mirror(book_id):
    """The plain text from one of Gutenberg's mirrors (spread across them; Gutenberg asks bulk tools
    to use mirrors). Mirrors keep books in folders by digit: 1342 -> 1/3/4/1342/1342-0.txt"""
    digits = str(book_id)
    folder = "/".join(digits[:-1]) + f"/{digits}" if len(digits) > 1 else f"0/{digits}"
    for attempt in range(len(MIRRORS) * 2):
        base = MIRRORS[(book_id + attempt) % len(MIRRORS)]
        for name in (f"{digits}-0.txt", f"{digits}.txt", f"{digits}-8.txt"):
            req = urllib.request.Request(f"{base}/{folder}/{name}", headers={"User-Agent": "DecentlyFluent catalog builder (one-off, polite)"})
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    data = r.read()
                return data.decode("utf-8" if not name.endswith("-8.txt") else "latin-1", "replace")
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    continue
                break
            except Exception:
                break
        time.sleep(1)
    return None


def body(text):
    s = re.search(r"\*\*\*\s*START OF.*?\*\*\*", text)
    e = re.search(r"\*\*\*\s*END OF.*?\*\*\*", text)
    return text[s.end() if s else 0: e.start() if e else len(text)]


def measure(book_id, lang):
    raw = fetch(book_id)
    if not raw:
        return None
    t = body(raw).replace("\r\n", "\n")
    paras = [p.strip() for p in re.split(r"\n\s*\n", t) if p.strip()]
    tokens = WORD.findall(t)
    if len(tokens) < 2000:
        return None
    lower = [w.lower() for w in tokens]
    sentences = max(1, len(re.findall(r"[.!?]+[\"”»’)]*(?:\s|$)", t)))
    chapters = len(CHAPTER.findall(t)) or 1
    dlg = DIALOGUE[lang]
    dialogue = sum(1 for p in paras if any(dlg.search(line) for line in p.split("\n")[:2])) / max(1, len(paras))
    caps = collections.Counter(w for w in tokens if w[0].isupper())
    counts = collections.Counter(lower)
    # words that almost always appear capitalised are names: they count as known
    proper = {w.lower() for w, c in caps.items() if c >= 0.9 * counts[w.lower()]}
    per10k = 10000 / len(lower)
    return {
        "id": book_id, "words": len(lower), "chapters": chapters, "words_per_chapter": len(lower) // chapters,
        "sentence_len": round(len(lower) / sentences, 1), "dialogue": round(dialogue, 3),
        "archaic": round(sum(counts[w] for w in ARCHAIC) * per10k, 1) if lang == "en" else 0,
        "dialect": round(sum(counts[w] for w in DIALECT) * per10k, 1) if lang == "en" else 0,
        "counts": counts, "proper": proper,
    }


def coverage(m, ranks, limit):
    known = sum(c for w, c in m["counts"].items() if ranks.get(w, 10**9) < limit or w in m["proper"])
    return round(known / sum(m["counts"].values()), 4)


def infer_translations(books):
    """Some Gutenberg records of translations name no translator (an Italian Monte-Cristo). Treat a book as
    translated when its language is a small minority among its author's books that do look like originals."""
    by_agent = collections.defaultdict(collections.Counter)
    for b in books:
        if not b["translated"]:
            for a in b["agents"]:
                by_agent[a][b["language"]] += 1
    found = []
    for b in books:
        if b["translated"] or not b["agents"]:
            continue
        langs = by_agent[b["agents"][0]]
        main, count = langs.most_common(1)[0]
        if main != b["language"] and count >= 3 and langs[b["language"]] * 3 <= count:
            found.append(b)
    for b in found:
        b["translated"] = True
    print(f"inferred {len(found)} more translations from their authors' main language", flush=True)


def originals_by_work(books, works):
    """A work has one original language: the one most of its author's untranslated books are in. Other
    editions of the work that Gutenberg doesn't mark as translations (Pinocchio: The Tale of a Puppet) are.
    When the author's books don't settle it, a language the work also has a named translation in isn't it."""
    by_id = {b["id"]: b for b in books}
    by_agent = collections.defaultdict(collections.Counter)
    for b in books:
        if not b["translated"]:
            for a in b["agents"]:
                by_agent[a][b["language"]] += 1
    n = 0
    for ids in works:
        group = [by_id[i] for i in ids if i in by_id]
        untranslated = [b for b in group if not b["translated"]]
        if len({b["language"] for b in untranslated}) < 2 or not group[0]["agents"]:
            continue
        counts = by_agent[group[0]["agents"][0]].most_common(2)
        main = counts[0][0]
        if len(counts) > 1 and counts[0][1] == counts[1][1]:
            # no clear main language: a language this work also has a named translation in isn't the original
            translated_into = {b["language"] for b in group if b["translated"]}
            candidates = {b["language"] for b in untranslated} - translated_into
            if len(candidates) != 1:
                continue
            main = candidates.pop()
        for b in untranslated:
            if b["language"] != main:
                b["translated"] = True
                n += 1
    print(f"inferred {n} more translations from works with an original in another language", flush=True)


# --- step 3: the same work in several languages ------------------------------------------

def deepseek(system, user):
    # curl rather than urllib: python.org builds of Python often have no CA certificates installed
    import subprocess
    body = json.dumps({
        "model": "deepseek-flash", "reasoning_effort": "low", "response_format": {"type": "json_object"},
        "max_tokens": 16000,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    })
    err = None
    for wait in (0, 5, 20, 60):
        time.sleep(wait)
        r = subprocess.run(["curl", "-sS", "--max-time", "300", "https://api.deepseek.com/chat/completions",
                            "-H", "Content-Type: application/json", "-H", "@-", "--data-binary", body],
                           input=f"Authorization: Bearer {os.environ['DEEPSEEK_API_KEY']}", capture_output=True, text=True)
        try:
            return json.loads(json.loads(r.stdout)["choices"][0]["message"]["content"])
        except Exception as e:
            err = RuntimeError(f"{e}: {r.stderr.strip() or r.stdout[:200]}")
    raise err


def find_editions(books, cache_path):
    """Groups of book ids that are the same work in different languages."""
    cache = json.load(open(cache_path)) if os.path.exists(cache_path) else {}
    by_agent = collections.defaultdict(list)
    for b in books:
        for a in b["agents"]:
            by_agent[a].append(b)
    # authors with books in more than one language, at least one of them a translation
    todo = {a: bs for a, bs in by_agent.items()
            if len({b["language"] for b in bs}) > 1 and any(b["translated"] for b in bs)}
    print(f"editions: {len(todo)} authors with books in several languages", flush=True)
    system = ("You are a bibliographer. You group books that are the same literary work in different languages. "
              "Answer with only a JSON object.")

    def ask(item):
        agent, bs = item
        key = agent + ":" + ",".join(str(i) for i in sorted(b["id"] for b in bs))
        if key in cache:
            return key, cache[key]
        lines = "\n".join(f'{b["id"]} [{b["language"]}{", translated" if b["translated"] else ""}] {b["title"][:120]}' for b in bs)
        user = (f"Project Gutenberg books by {bs[0]['author']}:\n{lines}\n\n"
                "Group the books that are the same work in different languages: an original and its translations, or "
                "translations of the same original. A volume or part of a work goes with the whole work, or with the same "
                "volume in another language. Leave out books with no counterpart in another language, and anything you "
                "are not sure about. Answer: {\"works\": [[id, id], ...]}")
        try:
            return key, deepseek(system, user).get("works", [])
        except Exception as e:
            print("  editions request failed:", agent, e, flush=True)
            return key, None

    done = 0
    with cf.ThreadPoolExecutor(8) as ex:
        for key, works in ex.map(ask, todo.items()):
            if works is not None:
                cache[key] = works
            done += 1
            if done % 50 == 0:
                print(f"  editions {done}/{len(todo)}", flush=True)
                json.dump(cache, open(cache_path, "w"))
    json.dump(cache, open(cache_path, "w"))
    lang = {b["id"]: b["language"] for b in books}
    works = []
    for key, groups in cache.items():
        if key.split(":", 1)[0] not in todo:
            continue
        for g in groups:
            ids = [i for i in g if isinstance(i, int) and i in lang]
            if len({lang[i] for i in ids}) > 1:
                works.append(ids)
    return works


def main():
    global CACHE
    rdf_dir = sys.argv[1]
    if "--cache" in sys.argv:
        CACHE = sys.argv[sys.argv.index("--cache") + 1]
        os.makedirs(CACHE, exist_ok=True)
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else "Resources/catalog.sqlite"
    n_analyse = dict(zip(["en", "fr", "de", "es", "it"], map(int, sys.argv[sys.argv.index("--analyse") + 1:][:5]))) if "--analyse" in sys.argv else {}

    files = glob.glob(os.path.join(rdf_dir, "**", "*.rdf"), recursive=True)
    print(f"{len(files)} rdf files", flush=True)
    books = []
    with cf.ProcessPoolExecutor() as ex:
        for b in ex.map(parse_rdf, files, chunksize=500):
            if b and b["downloads"] >= MIN_DOWNLOADS[b["language"]]:
                cats = classify(b)
                if cats is not None:
                    b["categories"] = cats
                    books.append(b)
    # popularity: downloads in the last 30 days, discounted for books released this year, whose counts
    # are swollen by bulk downloads of newly public-domain titles rather than readers
    this_year = time.strftime("%Y")
    for b in books:
        b["popularity"] = b["downloads"] // 10 if b["issued"].startswith(this_year) else b["downloads"]
    books.sort(key=lambda b: -b["popularity"])
    # one edition of each work: the most downloaded
    seen, unique = set(), []
    for b in books:
        # accents dropped, so "Andia" and "Andía" are the same title
        plain = unicodedata.normalize("NFKD", b["title"].lower().split(":")[0].split(" — ")[0])
        key = (re.sub(r"[^a-z0-9]", "", plain), b["author"].lower())
        if key not in seen:
            seen.add(key)
            unique.append(b)
    books = unique
    print("kept", collections.Counter(b["language"] for b in books), flush=True)
    infer_translations(books)

    measured = {}
    for lang, n in n_analyse.items():
        todo = [b["id"] for b in books if b["language"] == lang][:n]
        print(f"measuring {len(todo)} {lang} books", flush=True)
        results = []
        with cf.ThreadPoolExecutor(6) as ex:
            for i, m in enumerate(ex.map(lambda i: measure(i, lang), todo)):
                if m:
                    results.append(m)
                if i % 100 == 99:
                    print(f"  {lang} {i + 1}/{len(todo)}", flush=True)
        # frequency list for this language: rank by the number of books a word appears in, then by total count
        rng, tot = collections.Counter(), collections.Counter()
        for m in results:
            for w, c in m["counts"].items():
                if w not in m["proper"]:
                    rng[w] += 1
                    tot[w] += c
        ranked = sorted(rng, key=lambda w: (-rng[w], -tot[w]))
        ranks = {w: i for i, w in enumerate(ranked)}
        for m in results:
            m["cov2k"], m["cov5k"] = coverage(m, ranks, 2000), coverage(m, ranks, 5000)
            del m["counts"], m["proper"]
            measured[m["id"]] = m

    works = find_editions(books, sys.argv[sys.argv.index("--editions") + 1]) if "--editions" in sys.argv else []
    originals_by_work(books, works)

    if os.path.exists(out):
        os.remove(out)
    db = sqlite3.connect(out)
    db.executescript("""
    CREATE TABLE books(id INTEGER PRIMARY KEY, title TEXT, author TEXT, years TEXT, language TEXT,
      downloads INTEGER, issued TEXT, popularity INTEGER, subjects TEXT, shelves TEXT, categories TEXT,
      words INTEGER, measured INTEGER, chapters INTEGER, words_per_chapter INTEGER, sentence_len REAL,
      dialogue REAL, archaic REAL, dialect REAL, cov2k REAL, cov5k REAL, translated INTEGER, translator TEXT);
    CREATE INDEX books_lang ON books(language, popularity DESC);
    CREATE VIRTUAL TABLE books_fts USING fts5(title, author, content='books', content_rowid='id');
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE editions(id INTEGER PRIMARY KEY, work INTEGER);
    CREATE INDEX editions_work ON editions(work);
    """)
    for work, ids in enumerate(works):
        db.executemany("INSERT OR IGNORE INTO editions VALUES (?, ?)", [(i, work) for i in ids])
    for b in books:
        m = measured.get(b["id"])
        # unmeasured: estimate words from the text file size (about 5.9 bytes a word in English)
        words = m["words"] if m else (int(b["txt_bytes"] / 5.9) if b["txt_bytes"] else None)
        db.execute("INSERT INTO books VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (
            b["id"], b["title"], b["author"], b["years"], b["language"], b["downloads"], b["issued"], b["popularity"],
            " | ".join(b["subjects"][:5]), " | ".join(b["shelves"][:4]), ",".join(b["categories"]),
            words, 1 if m else 0,
            m and m["chapters"], m and m["words_per_chapter"], m and m["sentence_len"], m and m["dialogue"],
            m and m["archaic"], m and m["dialect"], m and m["cov2k"], m and m["cov5k"], 1 if b["translated"] else 0, b["translator"]))
    db.execute("INSERT INTO books_fts(books_fts) VALUES('rebuild')")
    db.execute("INSERT INTO meta VALUES ('built', ?)", (time.strftime("%Y-%m-%d"),))
    db.commit()
    db.execute("VACUUM")
    db.close()
    print(f"wrote {out}: {len(books)} books, {len(measured)} measured, {len(works)} works in several languages, {os.path.getsize(out) // 1024} KB", flush=True)


if __name__ == "__main__":
    main()

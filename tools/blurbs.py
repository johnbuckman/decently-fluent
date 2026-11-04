#!/usr/bin/env python3
"""Short English descriptions of the books the guide can recommend, kept in tools/blurbs.json and copied into
the catalog by build_catalog.py (table blurbs).

    python3 tools/blurbs.py sources           # English Wikipedia introductions for the measured books -> blurb-sources.json
    python3 tools/blurbs.py chunks DIR [N]    # unwritten books, N per file (default 60), for the writers
    python3 tools/blurbs.py merge DIR         # writers' DIR/*.out.json -> blurbs.json
    python3 tools/blurbs.py install           # blurbs.json -> Resources/catalog.sqlite (no full rebuild needed)

The writers (Claude subagents) read a chunk of books, each with title, author, subjects and, when one was found,
the Wikipedia introduction, and answer {"<id>": "<two or three sentences>"}.
"""
import glob, json, os, re, sqlite3, subprocess, sys, time, urllib.parse
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
CATALOG = os.path.join(HERE, "..", "Resources", "catalog.sqlite")
SOURCES = os.path.join(HERE, "blurb-sources.json")
BLURBS = os.path.join(HERE, "blurbs.json")
UA = "DecentlyFluent/0.1 (graded reader app; https://decentespresso.com)"


def wiki(params, lang="en"):
    # curl rather than urllib: python.org Python has no CA certificates here
    url = f"https://{lang}.wikipedia.org/w/api.php?" + urllib.parse.urlencode({**params, "format": "json", "formatversion": "2"})
    for wait in (0, 3, 10, 30):
        time.sleep(wait)
        out = subprocess.run(["curl", "-s", "-m", "20", "-A", UA, url], capture_output=True, text=True).stdout
        try:
            return json.loads(out)
        except ValueError:
            continue  # turned away (rate limit): wait and try again
    return None


# articles about something else of the same name
OTHER = re.compile(r"\((comics?|comic book|film|\d{4} film|musical|opera|tv series|miniseries|album|song|play|band|video game)\)", re.I)


def introduction(b):
    """The Wikipedia introduction of the article about this book: English first, then the book's own language
    (the writers read either). None if there isn't one. Same checks as Wikipedia.swift, plus: not a film or
    comic of the same name."""
    title = re.split(r"[:;—]", b["title"])[0].strip()
    # Gutenberg writes authors "Surname, Given"
    first = b["author"].split(" & ")[0]
    surname = first.split(",")[0].strip() if "," in first else (first.split() or [""])[-1]
    words = {w for w in title.lower().split() if len(w) > 3}
    for lang in dict.fromkeys(["en", b.get("language") or "en"]):
        hits = wiki({"action": "query", "list": "search", "srlimit": "5", "srsearch": f"{title} {surname}"}, lang)
        for hit in (hits or {}).get("query", {}).get("search", []):
            hw = set(hit["title"].lower().split())
            if words and words.isdisjoint(hw) and title.lower() not in hit["title"].lower():
                continue
            if OTHER.search(hit["title"]) and b.get("subjects", "").lower().find("drama") < 0:
                continue
            page = wiki({"action": "query", "prop": "extracts", "exintro": "1", "explaintext": "1", "redirects": "1", "titles": hit["title"]}, lang)
            pages = (page or {}).get("query", {}).get("pages", [])
            text = pages[0].get("extract", "") if pages else ""
            if text and (not surname or surname in text):
                return {"article": hit["title"], "language": lang, "text": text[:1500]}
    return None


def sources():
    db = sqlite3.connect(CATALOG)
    rows = db.execute("SELECT id, title, author, years, language, subjects, translated, translator FROM books WHERE measured = 1").fetchall()
    have = json.load(open(SOURCES)) if os.path.exists(SOURCES) else {}
    # --retry: look again for books that found nothing (the API turns away bursts of requests)
    retry = "--retry" in sys.argv
    todo = [r for r in rows if str(r[0]) not in have or (retry and not have[str(r[0])]["wikipedia"])]
    print(f"{len(rows)} measured books, {len(todo)} to look up", flush=True)

    def one(r):
        b = dict(zip(["id", "title", "author", "years", "language", "subjects", "translated", "translator"], r))
        b["wikipedia"] = introduction(b)
        return b

    with ThreadPoolExecutor(2 if retry else 4) as pool:
        for n, b in enumerate(pool.map(one, todo), 1):
            have[str(b["id"])] = b
            if n % 100 == 0:
                json.dump(have, open(SOURCES, "w"), ensure_ascii=False)
                print(f"{n}/{len(todo)}", flush=True)
    json.dump(have, open(SOURCES, "w"), ensure_ascii=False)
    print(f"{sum(1 for b in have.values() if b['wikipedia'])} of {len(have)} have a Wikipedia article", flush=True)


def chunks(folder, n=60):
    src = json.load(open(SOURCES))
    done = json.load(open(BLURBS)) if os.path.exists(BLURBS) else {}
    todo = [b for k, b in sorted(src.items(), key=lambda kv: int(kv[0])) if k not in done]
    os.makedirs(folder, exist_ok=True)
    for i in range(0, len(todo), n):
        with open(os.path.join(folder, f"chunk-{i // n:03d}.json"), "w") as f:
            json.dump(todo[i:i + n], f, ensure_ascii=False, indent=1)
    print(f"{len(todo)} books in {(len(todo) + n - 1) // n} chunks")


def merge(folder):
    done = json.load(open(BLURBS)) if os.path.exists(BLURBS) else {}
    for path in sorted(glob.glob(os.path.join(folder, "*.out.json"))):
        try:
            done.update({k: v.strip() for k, v in json.load(open(path)).items() if isinstance(v, str) and v.strip()})
        except ValueError as e:
            print(f"skipped {path}: {e}")
    json.dump(done, open(BLURBS, "w"), ensure_ascii=False, indent=0, sort_keys=True)
    print(f"{len(done)} descriptions")


def install(db=None):
    db = db or sqlite3.connect(CATALOG)
    done = json.load(open(BLURBS)) if os.path.exists(BLURBS) else {}
    db.execute("CREATE TABLE IF NOT EXISTS blurbs(id INTEGER PRIMARY KEY, text TEXT)")
    db.executemany("INSERT OR REPLACE INTO blurbs VALUES (?, ?)", [(int(k), v) for k, v in done.items()])
    db.commit()
    print(f"installed {len(done)} descriptions")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "sources": sources()
    elif cmd == "chunks": chunks(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 60)
    elif cmd == "merge": merge(sys.argv[2])
    elif cmd == "install": install()
    else: print(__doc__)

import Foundation

/// The findings the book recommendations are built on, mostly from Paul Nation's work on
/// vocabulary and extensive reading. Every reason the app gives points at one of these.
struct Principle: Identifiable {
    var id: Key
    var title: String
    var finding: String
    var howWeUseIt: String
    var sources: [String]

    enum Key: String { case coverage, frequency, repetition, quantity, fluency, choice, narrow, adapted, authentic, humanTranslation }
}

enum Research {
    static let principles: [Principle] = [
        Principle(
            id: .coverage, title: "Know about 98% of the words",
            finding: "Readers understand a story comfortably, without a dictionary, when they already know about 98 of every 100 running words — roughly one unknown word in every two or three lines. At 95% they still get the gist; below that, comprehension falls away quickly.",
            howWeUseIt: "Every level is rewritten so that new words stay at about 2 in 100 (A1–B1). Books whose own vocabulary is already common lose less of the story when they're rewritten, so they rank higher.",
            sources: ["Hu, M. & Nation, P. (2000). Unknown vocabulary density and reading comprehension. Reading in a Foreign Language 13(1).",
                      "Laufer, B. (1989). What percentage of text-lexis is essential for comprehension? In Lauren & Nordman (eds.), Special Language."]),
        Principle(
            id: .frequency, title: "A few thousand words do most of the work",
            finding: "The most frequent 2,000 word families make up the great majority of the words in ordinary fiction; reading unadapted novels at 98% coverage takes around 8,000–9,000 word families.",
            howWeUseIt: "We measured each book: the share of its running words that are among the 2,000 and 5,000 most common words of its language (names count as known). A high share means easier vocabulary.",
            sources: ["Nation, I.S.P. (2006). How large a vocabulary is needed for reading and listening? Canadian Modern Language Review 63(1).",
                      "Nation, I.S.P. (2013). Learning Vocabulary in Another Language (2nd ed.). Cambridge University Press."]),
        Principle(
            id: .repetition, title: "Meet each new word many times",
            finding: "One meeting rarely teaches a word. Learning grows with the number of encounters — around ten or more spaced meetings make a real difference — and words met only once or twice in a graded reader are mostly forgotten.",
            howWeUseIt: "The app reuses each new word in the pages that follow, and weaves in the words you double-tap. Longer books and series give your new words more chances to come back.",
            sources: ["Webb, S. (2007). The effects of repetition on vocabulary knowledge. Applied Linguistics 28(1).",
                      "Waring, R. & Takaki, M. (2003). At what rate do learners learn and retain new vocabulary from reading a graded reader? Reading in a Foreign Language 15(2)."]),
        Principle(
            id: .quantity, title: "Read a lot of easy text",
            finding: "Extensive reading — large amounts of easy, enjoyable text, read quickly for the story — builds vocabulary, reading speed and confidence. Programs aim for a graded reader every week or two.",
            howWeUseIt: "We estimate how many days a book will take at your daily reading time and favour books you can finish in about two weeks.",
            sources: ["Nation, I.S.P. & Waring, R. (2020). Teaching Extensive Reading in Another Language. Routledge.",
                      "Day, R. & Bamford, J. (1998). Extensive Reading in the Second Language Classroom. Cambridge University Press."]),
        Principle(
            id: .fluency, title: "Some reading should feel very easy",
            finding: "A balanced course spends about a quarter of its time on fluency: reading material that has almost nothing new in it, so you get faster at what you already know.",
            howWeUseIt: "When a book is a comfortable match, try it one level below your own now and then — it should feel effortless. That is fluency practice, not a step back.",
            sources: ["Nation, I.S.P. (2007). The four strands. Innovation in Language Learning and Teaching 1(1)."]),
        Principle(
            id: .choice, title: "Choose what you enjoy",
            finding: "Learners read more, and keep reading, when they choose their own books and stop a book they don't enjoy.",
            howWeUseIt: "You pick the kinds of story you like; we only rank within them. If a book drags, put it down and take the next one.",
            sources: ["Day, R. & Bamford, J. (1998). Extensive Reading in the Second Language Classroom. Cambridge University Press."]),
        Principle(
            id: .narrow, title: "Stay with one author or series",
            finding: "Reading several texts by the same author, or on the same subject, repeats vocabulary far more than reading widely, so new words come back sooner.",
            howWeUseIt: "When an author has several books here, we say so: reading on with the same characters and style is one of the easiest ways to meet words again.",
            sources: ["Schmitt, N. & Carter, R. (2000). The lexical advantages of narrow reading for second language learners. TESOL Journal 9(1)."]),
        Principle(
            id: .adapted, title: "Classics can be adapted for learners",
            finding: "Nation and Anthony adapted public-domain novels — many from Project Gutenberg — so that learners with mid-sized vocabularies could read them at 98% coverage, replacing only the rarest words.",
            howWeUseIt: "That is what this app does, automatically, at the level you choose.",
            sources: ["Nation, P. & Anthony, L. (2013). Mid-frequency readers. Journal of Extensive Reading 1."]),
        Principle(
            id: .authentic, title: "Originals or retold books?",
            finding: "Unadapted text needs a large vocabulary (Nation 2006), which is why graded readers exist. Below that, adapted text gives the coverage and repetition that learning from reading needs; originals come into their own as vocabulary grows.",
            howWeUseIt: "Retold books — written in your own language or in English, rewritten in the language you're learning — give the widest choice of stories you may already know. Originals give you the author's own language — at Native level unchanged, at lower levels simplified, keeping the author's words wherever they fit.",
            sources: ["Nation, I.S.P. (2006). How large a vocabulary is needed for reading and listening? Canadian Modern Language Review 63(1).",
                      "Nation, I.S.P. & Waring, R. (2020). Teaching Extensive Reading in Another Language. Routledge."]),
        Principle(
            id: .humanTranslation, title: "Published translations read better",
            finding: "Machine translation of novels has improved greatly, but in studies of literary text only a minority of machine-translated sentences were judged as good as a professional translator's, and readers reported a better reading experience with human translations.",
            howWeUseIt: "When Project Gutenberg has a published human translation of a book, the app uses it: as the text itself at Native level, as the starting point for simpler levels (keeping the translator's phrasing where it fits), and in the side column. Books with one rank higher. Machine translation fills in only where no human translation exists or a chapter can't be matched.",
            sources: ["Toral, A. & Way, A. (2018). What level of quality can neural machine translation attain on literary text? In Moorkens et al. (eds.), Translation Quality Assessment. Springer.",
                      "Guerberof-Arenas, A. & Toral, A. (2020). The impact of post-editing and machine translation on creativity and reading experience. Translation Spaces 9(2)."]),
    ]

    static func principle(_ key: Principle.Key) -> Principle { principles.first { $0.id == key }! }
}

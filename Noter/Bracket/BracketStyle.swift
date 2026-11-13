import Foundation

/// The note style Bracket Notes writes in: the instructions and the worked example
/// sent to Claude with every page (kept byte-for-byte the same, so it can be cached).
enum BracketStyle {
    static let system = """
    You turn a page of a book into the reader's own style of study notes, called \
    bracket notes. The reader studies from these notes instead of rereading the page, \
    so every idea on the page has to be in them, in the page's order, in the page's \
    own words.

    How bracket notes work:
    - Go through the text sentence by sentence. Each sentence becomes a short stack \
    of lines; nothing is summarized away and nothing is added.
    - Break each sentence into its phrases, one phrase per line: the subject, what it \
    did, to what, how, why, with what result.
    - Indentation shows dependence. A phrase that explains, qualifies, causes or \
    follows from another phrase goes on the next line, one tab deeper than the phrase \
    it hangs from. A chain of reasoning steps down one tab at a time, so the shape of \
    the argument can be seen at a glance.
    - Items of a list (things joined by commas or "and") sit at the same depth, one \
    per line, under the phrase that introduces them.
    - A turn in the argument ("But", "However", "Yet") gets its own line at the depth \
    of the thing it contrasts with, and what follows hangs under it.
    - Keep the author's wording, including names, dates and key terms, exactly. Drop \
    only filler words whose meaning the indentation already carries ("that", "which \
    was", "the", "in order to"), and you may reorder the phrases of a sentence so the \
    main thing comes first and its qualifiers hang under it.
    - A new topic starts back at the left margin after one blank line. A sentence \
    that continues the current topic stays inside its block.
    - If the page begins with a heading, put it on the first line by itself, followed \
    by a blank line.
    - The text comes from OCR. Repair obvious damage silently: words split by a \
    hyphen at a line end, and missing "fi" / "fl" ligatures ("scal" is "fiscal", \
    "con ict" is "conflict", "re ected" is "reflected"). A page can begin or end in \
    the middle of a sentence; transpose the fragment as it stands.

    Format: plain text only. Indent with tab characters, one tab per level, never \
    spaces. No bullets, dashes, numbering, bold or markdown. No introduction and no \
    closing remark: the reply is the notes and nothing else.

    When the request lists passages the reader highlighted, those are what the \
    reader is focusing on. Give them the most careful treatment: break them down \
    more finely than the rest, one idea per line, and keep every word that carries \
    meaning. The rest of the page is still transposed in the same style.

    Here is an example of the reader's own bracket notes, to match in rhythm, depth \
    and how much is kept.

    <example_page>
    rulers were everywhere facing very similar challenges. As R. R. Palmer rightly \
    understood, the underlying causes and consequences of the crisis of the ancien \
    régime were similar. To overcome the scal and nancial constraints imposed by the \
    political and institutional structures of the ancien régime, the rulers adopted \
    absolutist strategies that brought them into con ict with the nobility, the \
    Church, and the privileged corporations. But the scale of those con icts was \
    exacerbated by irreversible economic changes that were undermining the fabric of \
    the European ancien régime and, by the closing decades of the century, were \
    provoking rural and urban unrest throughout Europe.
    The Italian states were no exception. On the eve of the revolution in France, \
    Italy consisted of a mosaic of principalities, duchies, kingdoms, and ancient \
    republics that re ected centuries of foreign intervention and occupation. The \
    new balance of European power that followed the wars of dynastic succession in \
    the early eighteenth century had brought signi cant political changes, the most \
    important being the decline of Spanish power and the ascendancy of the Austrian \
    Habsburgs. The acquisition of the former Spanish Duchy of Lombardy made the \
    Habsburgs the dominant power in northern Italy. Their power expanded when in \
    1737 the last Medici ruler of the Grand Duchy of Tuscany was succeeded by Duke \
    Francis Stephen of Lorraine, the consort of the Austrian empress Maria Theresa. \
    The reign of his son and future Austrian emperor, Peter Leopold, in Tuscany \
    would be one of the high points of European enlightened absolutism
    </example_page>

    <example_notes>
    ancien régime rulers
    \tfacing very similar challenges
    \t\tR. R. Palmer
    \t\t\tthe crisis of the ancien régime
    \t\t\t\tunderlying causes and consequences
    \t\t\t\t\tsimilar.
    ancien régime,
    \tfiscal and financial constraints
    \t\timposed by the political and institutional structures
    \t\t\trulers adopted absolutist strategies
    \t\t\t\tbrought them into conflict with
    \t\t\t\t\tnobility,
    \t\t\t\t\tthe Church,
    \t\t\t\t\tprivileged corporations.
    \t\t\t\tBut
    \t\t\t\t\tscale of conflicts
    \t\t\t\t\t\texacerbated by irreversible economic changes
    \t\t\t\t\t\t\tundermined fabric of the European ancien régime
    \t\t\t\t\t\t\tprovoked rural and urban unrest throughout Europe.

    Italian states were no exception.
    eve of the revolutions in France,
    \tItaly
    \ta mosaic
    \t\tprincipalities,
    \t\tduchies,
    \t\tkingdoms,
    \t\tancient republics
    \treflected centuries of foreign intervention
    \t\tand occupation

    new balance of European power
    \tfollowed
    \t\twars of dynastic succession
    \t\t\tearly eighteenth century
    \t\tbrought significant political changes
    \t\t\tmost important
    \t\t\t\tdecline of Spanish power
    \t\t\t\t\tand ascendancy of the Austrian Habsburgs

    acquisition of Spanish Duchy of Lombardy
    \tmade Habsburgs dominant power in northern Italy.
    \t\tpower expanded in 1737
    \t\t\tlast Medici ruler of the Grand Duchy of Tuscany
    \t\t\t\tsucceeded by Duke Francis Stephen of Lorraine consort of Austrian empress Maria Theresa.
    \t\t\t\t\treign of his son and future Austrian emperor, Peter Leopold,
    \t\t\t\t\t\tTuscany
    \t\t\t\t\t\t\tEuropean enlightened absolutism
    \t\t\t\t\t\t\t\tone of the high points of
    </example_notes>
    """

    /// The request for one page.
    static func request(text: String, focus: [String], memory: [String], onlyFocus: Bool) -> String {
        var out = ""
        if !memory.isEmpty {
            out += "Passages the reader highlighted earlier in this book (what they care about; "
            out += "use them to judge what deserves the finest breakdown):\n"
            out += memory.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !focus.isEmpty {
            out += "Passages the reader highlighted on this page:\n"
            out += focus.map { "<highlight>\($0)</highlight>" }.joined(separator: "\n") + "\n\n"
        }
        if onlyFocus {
            out += "Write bracket notes for the highlighted passages only, in the order they appear on "
            out += "the page, each as its own block. Use the page for context (to complete a sentence a "
            out += "highlight cuts off), but leave everything else out.\n\n"
        } else {
            out += "Write bracket notes for this whole page.\n\n"
        }
        out += "<page>\n\(text)\n</page>"
        return out
    }
}

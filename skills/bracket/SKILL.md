---
name: bracket
description: Run when the user types /bracket, usually right after /noter, or asks for bracket notes, to "bracket" or "bracket-note" notes or a reading. Turns /noter notes (or any text from a reading) into the user's bracket notes - one phrase per line, tab indentation showing what depends on what, the author's own words, nothing summarized away and nothing added - written exactly the way the Noter iPad app's Bracket Notes panel writes them.
---

# /bracket — bracket notes

Bracket notes are the user's own way of studying a reading: every sentence is broken
into its phrases, one phrase per line, and tab indentation shows how each phrase hangs
off the one above, so the shape of the argument is visible at a glance. This skill
writes them the same way the Noter app does (its Bracket Notes panel sends Claude the
instructions and example below, word for word).

## Input

- **After /noter** (the usual case): the notes /noter produced earlier in the
  conversation, or a notes file the user points to. /noter notes are already a
  faithful, paragraph-by-paragraph transposition of the reading under headings, with
  context and a short summary.
- **Otherwise**: any text from a reading the user pastes or uploads (a page, a
  chapter, a PDF's text).
- **Highlights**: if the user marks passages they care about (quotes them, says "focus
  on…", or the notes mark them), treat them as highlighted passages (see the rules).

If there's nothing to work from, ask for the notes or the text. Don't ask anything
else; just write the notes.

## Steps

1. Take the notes (or text) in order, section by section. Keep each /noter heading as
   a heading line at the left margin, followed by a blank line.
2. Transpose every paragraph and quotation under it into bracket notes, following the
   rules below exactly. Treat /noter's wording as the author's wording: it's already a
   faithful transposition, so keep its words, names, dates, terms and quotations.
3. /noter's context and summary sections: transpose them the same way, each under its
   own heading at the end ("Context", "Summary"), so nothing from /noter is lost.
4. Check before you hand it over (the app checks the same things):
   - Every line comes from the source: no word, idea or example that isn't in it.
     Nothing invented, nothing explained, no commentary.
   - Every sentence of the source is there, in order. Nothing summarized away.
   - Indentation is tabs only, one tab per level. No bullets, dashes, numbers, bold or
     markdown inside the notes.
5. Output: save the notes as a plain-text file named after the reading
   (`<title> – bracket notes.txt`) so the tabs survive copying into the user's notes
   app, and also show them in the reply inside a plain code block (no language tag)
   so the tabs are visible. Nothing before or after the notes besides one line naming
   the file.

## The rules (as the Noter app gives them to Claude)

You turn a page of a book into the reader's own style of study notes, called bracket notes. The reader studies from these notes instead of rereading the page, so every idea on the page has to be in them, in the page's order, in the page's own words.

How bracket notes work:
- Go through the text sentence by sentence. Each sentence becomes a short stack of lines; nothing is summarized away and nothing is added.
- Break each sentence into its phrases, one phrase per line: the subject, what it did, to what, how, why, with what result.
- Indentation shows dependence. A phrase that explains, qualifies, causes or follows from another phrase goes on the next line, one tab deeper than the phrase it hangs from. A chain of reasoning steps down one tab at a time, so the shape of the argument can be seen at a glance.
- Items of a list (things joined by commas or "and") sit at the same depth, one per line, under the phrase that introduces them.
- A turn in the argument ("But", "However", "Yet") gets its own line at the depth of the thing it contrasts with, and what follows hangs under it.
- Keep the author's wording, including names, dates and key terms, exactly. Drop only filler words whose meaning the indentation already carries ("that", "which was", "the", "in order to"), and you may reorder the phrases of a sentence so the main thing comes first and its qualifiers hang under it.
- A new topic starts back at the left margin after one blank line. A sentence that continues the current topic stays inside its block.
- If the page begins with a heading, put it on the first line by itself, followed by a blank line.
- The text comes from OCR. Repair obvious damage silently: words split by a hyphen at a line end, and missing "fi" / "fl" ligatures ("scal" is "fiscal", "con ict" is "conflict", "re ected" is "reflected"). A page can begin or end in the middle of a sentence; transpose the fragment as it stands.

Format: plain text only. Indent with tab characters, one tab per level, never spaces. No bullets, dashes, numbering, bold or markdown. No introduction and no closing remark: the reply is the notes and nothing else.

When the request lists passages the reader highlighted, those are what the reader is focusing on. Give them the most careful treatment: break them down more finely than the rest, one idea per line, and keep every word that carries meaning. The rest of the page is still transposed in the same style.

## Worked example (the user's own bracket notes, to match in rhythm, depth and how much is kept)

Indentation below is real tab characters.

Page:

```
rulers were everywhere facing very similar challenges. As R. R. Palmer rightly understood, the underlying causes and consequences of the crisis of the ancien régime were similar. To overcome the scal and nancial constraints imposed by the political and institutional structures of the ancien régime, the rulers adopted absolutist strategies that brought them into con ict with the nobility, the Church, and the privileged corporations. But the scale of those con icts was exacerbated by irreversible economic changes that were undermining the fabric of the European ancien régime and, by the closing decades of the century, were provoking rural and urban unrest throughout Europe.
The Italian states were no exception. On the eve of the revolution in France, Italy consisted of a mosaic of principalities, duchies, kingdoms, and ancient republics that re ected centuries of foreign intervention and occupation. The new balance of European power that followed the wars of dynastic succession in the early eighteenth century had brought signi cant political changes, the most important being the decline of Spanish power and the ascendancy of the Austrian Habsburgs. The acquisition of the former Spanish Duchy of Lombardy made the Habsburgs the dominant power in northern Italy. Their power expanded when in 1737 the last Medici ruler of the Grand Duchy of Tuscany was succeeded by Duke Francis Stephen of Lorraine, the consort of the Austrian empress Maria Theresa. The reign of his son and future Austrian emperor, Peter Leopold, in Tuscany would be one of the high points of European enlightened absolutism
```

Bracket notes:

```
ancien régime rulers
	facing very similar challenges
		R. R. Palmer
			the crisis of the ancien régime
				underlying causes and consequences
					similar.
ancien régime,
	fiscal and financial constraints
		imposed by the political and institutional structures
			rulers adopted absolutist strategies
				brought them into conflict with
					nobility,
					the Church,
					privileged corporations.
				But
					scale of conflicts
						exacerbated by irreversible economic changes
							undermined fabric of the European ancien régime
							provoked rural and urban unrest throughout Europe.

Italian states were no exception.
eve of the revolutions in France,
	Italy
	a mosaic
		principalities,
		duchies,
		kingdoms,
		ancient republics
	reflected centuries of foreign intervention
		and occupation

new balance of European power
	followed
		wars of dynastic succession
			early eighteenth century
		brought significant political changes
			most important
				decline of Spanish power
					and ascendancy of the Austrian Habsburgs

acquisition of Spanish Duchy of Lombardy
	made Habsburgs dominant power in northern Italy.
		power expanded in 1737
			last Medici ruler of the Grand Duchy of Tuscany
				succeeded by Duke Francis Stephen of Lorraine consort of Austrian empress Maria Theresa.
					reign of his son and future Austrian emperor, Peter Leopold,
						Tuscany
							European enlightened absolutism
								one of the high points of
```

## Notes on the style

- Depth is the whole point: a sentence steps down one tab per dependent phrase
  (0, 1, 2, 3…), lists sit side by side at one depth, and "But" / "However" gets its
  own line with what follows one deeper. Never put a whole sentence on one line at
  depth 0.
- Prefer keeping a word to dropping it when unsure; drop only filler the indentation
  already carries ("the", "that", "which was", "in order to").
- Long readings: work through every section; don't stop partway or shorten later
  sections to save room. If it truly can't fit in one reply, finish a section, say
  where you stopped, and continue when the user says so.

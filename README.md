# Noter

A no-frills iPad reader for scanned books and PDFs, built around the Apple Pencil.

- **Load a PDF** → Noter runs Apple's on-device text recognition (Vision) on every page.
- **PDF / Text / Highlights** tabs at the top switch between the original scan, the
  recognized transcript, and your list of highlights.
- **Just draw to highlight.** With the Apple Pencil, sweep over any line — in the PDF *or*
  the transcript — and Noter snaps the stroke to the words underneath and highlights them.
  No selecting, no color picker, no menu. Fingers still scroll and zoom; the pencil never
  scrolls.
- **Two-page scans** (a book photographed/scanned open, two pages per PDF page) are
  detected automatically and split at the gutter, so reading order, highlights and page
  numbers are per *book* page. Override in **⋯ › Page layout** (Auto / Single / Two-page).
- **Book page numbers, not PDF page numbers.** Noter reads the printed page number
  (top or bottom margin, arabic or roman numerals), rejects misreads, and fills in pages
  where none is printed (chapter openings, blank pages). Every highlight is labelled with
  that page, e.g. *p. 147*. If a page number can't be found it falls back to the PDF page.
- **Highlights file.** All highlight text is written to
  `On My iPad › Noter › Highlights › <Title> – Highlights.md`, grouped by book page, and
  rewritten on every change. The Highlights tab also has *Copy all* and *Export*.
- **Auto-save, always.** Every highlight, every recognized page and your reading position
  is written to disk the moment it happens (atomic writes), so a dead battery loses nothing.
  Unfinished text recognition resumes where it stopped.
- **Read aloud.** The small ▶︎ control in the top-right corner reads the book with Apple's
  best installed voice, highlighting the line being read (and the word, in the text view)
  and scrolling along. While it's reading, tap a word with your finger to jump there.
  Speed 0.75×–3×. It never interferes with the pencil: the read-aloud marker is a separate
  layer, and auto-scrolling pauses while you write or scroll.
- **Large PDFs.** Pages are recognized one at a time starting from the page you're
  looking at; results are stored per page and only a handful are kept in memory. The
  transcript loads lazily, so 1,000-page books are fine.

## Apple Pencil

| Action | Result |
| --- | --- |
| Draw across part of a line | Highlights the words you crossed |
| Draw diagonally over several lines | Highlights from where you started to where you ended, like a text selection |
| Vertical line in the margin | Highlights the lines next to it |
| Draw over an existing highlight | Extends / merges it (never stacks) |
| Double-tap (Pencil 2 / Pro) or **squeeze** (Pencil Pro) | Toggles highlighter ↔ eraser (honors your Settings › Apple Pencil choice) |
| Eraser: draw over highlights | Removes them |

The toolbar also has undo, the highlighter/eraser toggle and the highlight color (set once;
it's remembered).

## Natural-sounding voice

iOS only lets apps use voices installed on the device. For the best ("neural") voice, go to
**Settings › Accessibility › Spoken Content › Voices › English** and download a voice marked
**Premium** (or Enhanced). Noter picks the best installed voice automatically; you can change
it from the speed menu in the read-aloud control. Siri's own voices aren't available to apps.

## Building

Requirements: Xcode 16 or newer, iPadOS 17+ device (Apple Pencil features need a real iPad).

1. Open `Noter.xcodeproj`.
2. Select the **Noter** target › *Signing & Capabilities* › choose your Team.
   If Xcode says the bundle id is taken, change `com.filthydevl.noter` to anything unique.
3. Pick your iPad as the run destination and press **Run**.

`project.yml` is an optional [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec that
produces the same project if you ever need to regenerate it.

## Where things live

```
Noter/
  App/          app entry point
  Models/       data types, storage, library (import / delete)
  OCR/          page rendering + Vision text recognition, background worker
  Layout/       spread detection, reading order, page numbers, pen-to-word snapping
  Reader/       document session, PDF view, transcript view, highlights list
  Speech/       read-aloud engine and the corner control
  Library/      document list
Support/Info.plist
```

On device, each document is stored in `Application Support/Library/<id>/`
(`document.pdf`, `highlights.json`, `info.json`, `ocr/p<N>.json`). The PDF itself is never
modified.

## Notes / limits

- Text recognition runs while a document is open (it resumes automatically next time).
  Pages you highlight or read aloud are recognized first, on demand.
- Recognition languages are detected automatically by Vision.
- Password-protected PDFs aren't supported.

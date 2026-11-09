import XCTest

/// Simulator smoke test run by CI. Expects the workflow to have seeded a document
/// titled "Sample Book" (2 PDF pages) into the app's library before launch.
final class NoterSmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testOpenReadTranscriptAndSpeak() {
        let app = XCUIApplication()
        app.launch()

        let row = app.staticTexts["Sample Book"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Library row for the seeded PDF is missing")
        snapshot(app, "1-library")
        row.tap()

        // PDF view
        let textTab = app.buttons["Text"]
        XCTAssertTrue(textTab.waitForExistence(timeout: 30), "Reader toolbar (PDF/Text/Highlights) didn't appear")
        sleep(3)
        snapshot(app, "2-pdf")
        assertRunning(app, "after opening the PDF view")

        // Text tab: wait for OCR of both pages to finish (progress indicator disappears).
        textTab.tap()
        let progress = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Recognizing text'")).firstMatch
        let ocrDone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: progress)
        wait(for: [ocrDone], timeout: 180)
        sleep(2)
        snapshot(app, "3-transcript")
        let recognized = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS[c] 'brown fox' OR label CONTAINS[c] 'brown fox'"))
            .firstMatch.exists
        print("NOTER-SMOKE: transcript shows recognized text: \(recognized)")
        // Only the Text view's pages (the PDF view exposes the PDF's own text layer).
        let pages = app.collectionViews.descendants(matching: .textView)
        print("NOTER-SMOKE: text view pages on screen: \(pages.count)")
        for i in 0..<min(pages.count, 2) {
            let v = (pages.element(boundBy: i).value as? String) ?? ""
            if let r = v.range(of: "London") {
                print("NOTER-SMOKE: page \(i) around 'London': \(v[r.lowerBound...].prefix(40))")
            }
        }
        let marker = pages.matching(NSPredicate(format: "value CONTAINS 'London. 7' OR value CONTAINS 'London.7'"))
            .firstMatch.exists
        let london = pages.matching(NSPredicate(format: "value CONTAINS 'spoke in London.'")).firstMatch.exists
        let falseQuestion = pages.matching(NSPredicate(format: "value CONTAINS 'London?'")).firstMatch.exists
        print("NOTER-SMOKE: sentence before footnote shown: \(london), footnote marker left in text: \(marker), "
              + "footnote misread as '?': \(falseQuestion)")
        assertRunning(app, "after text recognition")

        // Reading options: change theme and font, nothing crashes.
        let options = app.buttons["Reading options"]
        if options.waitForExistence(timeout: 5) {
            options.tap()
            let sepia = app.buttons["Sepia theme"]
            print("NOTER-SMOKE: reading options shown: \(sepia.waitForExistence(timeout: 5))")
            if sepia.exists { sepia.tap() }
            if app.buttons["Charter"].exists { app.buttons["Charter"].tap() }
            sleep(1)
            snapshot(app, "3b-reading-options")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.95)).tap() // dismiss the popover
            sleep(1)
            assertRunning(app, "after changing reading options")
        }

        // Read aloud
        let play = app.buttons["Read aloud"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "Read-aloud button missing")
        play.tap()
        // Timeline of the transport controls: "Pause reading" / "Stop reading" exist while
        // the synthesizer is active; both vanish when the queue runs out or speech fails.
        let pause = app.buttons["Pause reading"]
        let stop = app.buttons["Stop reading"]
        for tick in 0..<16 {
            print("NOTER-SMOKE: t=\(Double(tick) * 0.5)s pause=\(pause.exists) stop=\(stop.exists)")
            Thread.sleep(forTimeInterval: 0.5)
        }
        let bookmark = app.buttons["Go to reading position"]
        print("NOTER-SMOKE: bookmark button shown: \(bookmark.exists)")
        if bookmark.exists { bookmark.tap() }
        snapshot(app, "4-speaking")
        assertRunning(app, "while reading aloud")
        if stop.exists { stop.tap() }

        // Highlights tab, then back to the PDF.
        app.buttons["Highlights"].tap()
        sleep(1)
        snapshot(app, "5-highlights")
        app.buttons["PDF"].tap()
        sleep(1)

        // Scribble: the pen button switches to the scribble pen, its toolbar appears, a
        // finger tap on the page shows "!" on the pen button, Tidy copes with no ink.
        let pen = app.buttons["Highlighter (tap for scribble pen)"]
        if pen.waitForExistence(timeout: 5) {
            pen.tap()
            let tidy = app.buttons["Tidy handwriting on this page"]
            print("NOTER-SMOKE: scribble toolbar shown: \(tidy.waitForExistence(timeout: 5))")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).tap()
            sleep(1)
            let hint = app.descendants(matching: .any)["Scribble is on"].exists
            print("NOTER-SMOKE: scribble hint shown: \(hint)")
            snapshot(app, "5b-scribble")
            if tidy.exists { tidy.tap() }
            sleep(2)
            assertRunning(app, "in scribble mode")
            let back = app.buttons["Scribble pen (tap for highlighter)"]
            if back.exists { back.tap() }
            sleep(1)
        } else {
            print("NOTER-SMOKE: pen button not found")
        }

        // Key words come from your own short highlights (none in this test).
        app.buttons["Key words"].tap()
        sleep(1)
        print("NOTER-SMOKE: key words empty state: \(app.staticTexts["No key words yet"].exists)")
        snapshot(app, "6-keywords")

        // Questions highlighter: finds the questions, marks them, jumps and blinks.
        app.buttons["Questions"].tap()
        let question = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Why did so many women'")).firstMatch
        let found = question.waitForExistence(timeout: 60)
        let rhetorical = app.staticTexts["Rhetorical"].exists
        print("NOTER-SMOKE: questions found: \(found), rhetorical label shown: \(rhetorical)")
        snapshot(app, "7-questions")
        let mark = app.switches["Mark on pages"]
        if mark.exists { mark.tap() }
        sleep(1)
        if found { question.tap() }
        sleep(3)
        snapshot(app, "8-question-jump")
        assertRunning(app, "after jumping to a question")
        app.buttons["Text"].tap()
        sleep(2)
        if found { question.tap() }
        sleep(3)
        assertRunning(app, "after jumping to a question in the text view")

        // Page slider, and switching views keeps the place.
        print("NOTER-SMOKE: page slider shown: \(app.sliders["Page"].exists)")
        app.buttons["PDF"].tap()
        sleep(2)
        app.buttons["Text"].tap()
        sleep(2)
        assertRunning(app, "after switching views")

        // Search: whole words, any case.
        app.buttons["Search"].tap()
        let field = app.textFields["Search text"]
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("BROWN fox")
            let hit = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'brown fox'")).firstMatch
            let searchFound = hit.waitForExistence(timeout: 20)
            print("NOTER-SMOKE: search found 'BROWN fox': \(searchFound)")
            snapshot(app, "9-search")
            if searchFound { hit.tap() }
            sleep(3)
            if app.buttons["Close search"].exists { app.buttons["Close search"].tap() }
            sleep(1)
        } else {
            print("NOTER-SMOKE: search field missing")
        }
        assertRunning(app, "after searching")

        // Colors: name a color, add one from the wheel, auto switch on.
        let colorButton = app.buttons["Highlight color"]
        if colorButton.waitForExistence(timeout: 5) {
            colorButton.tap()
            let nameColors = app.buttons["Name & add colors…"]
            if nameColors.waitForExistence(timeout: 5) {
                nameColors.tap()
                let field = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Name it'"))
                    .firstMatch
                if field.waitForExistence(timeout: 5) {
                    field.tap()
                    field.typeText("Ideas")
                }
                if app.buttons["Add color"].exists { app.buttons["Add color"].tap() }
                sleep(1)
                snapshot(app, "9b-colors")
                print("NOTER-SMOKE: colors panel shown: \(app.staticTexts["Colors"].exists), "
                      + "named: \(app.textFields.matching(NSPredicate(format: "value == 'Ideas'")).firstMatch.exists)")
                if app.buttons["Close colors"].exists { app.buttons["Close colors"].tap() }
                sleep(1)
            } else {
                print("NOTER-SMOKE: name colors button missing")
            }
        }
        let auto = app.buttons["Auto color switch off (tap to turn on)"]
        print("NOTER-SMOKE: auto color switch button: \(auto.exists)")
        if auto.exists { auto.tap() }
        sleep(1)
        assertRunning(app, "after the colors panel")

        // Notes panel (no highlights in this test: its empty state).
        app.buttons["Notes"].tap()
        sleep(1)
        print("NOTER-SMOKE: notes panel shown: \(app.staticTexts["Notes"].exists), "
              + "empty state: \(app.staticTexts["No highlights yet"].exists)")
        snapshot(app, "10-notes")
        if app.buttons["Close notes"].exists { app.buttons["Close notes"].tap() }
        sleep(1)

        // Save PDF with highlights + scribbles: the file is written and the share sheet opens.
        let save = app.buttons["Save PDF"]
        if save.waitForExistence(timeout: 5) {
            save.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let withInk = app.buttons["Save PDF — highlights + scribbles"]
            if withInk.waitForExistence(timeout: 5) { withInk.tap() }
            let sheet = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == 'Save to Files' OR identifier == 'ActivityListView'")).firstMatch
            let shown = sheet.waitForExistence(timeout: 30)
            print("NOTER-SMOKE: save PDF share sheet shown: \(shown)")
            snapshot(app, "11-save-pdf")
        } else {
            print("NOTER-SMOKE: save PDF button missing")
        }
        assertRunning(app, "at the end of the smoke test")
    }

    private func assertRunning(_ app: XCUIApplication, _ when: String) {
        XCTAssertEqual(app.state, .runningForeground, "Noter is not running \(when) (crashed?)")
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}

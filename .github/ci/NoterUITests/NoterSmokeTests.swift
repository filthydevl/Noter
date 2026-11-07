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
        assertRunning(app, "after text recognition")

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
        snapshot(app, "4-speaking")
        assertRunning(app, "while reading aloud")
        if stop.exists { stop.tap() }

        // Highlights tab, then back to the PDF.
        app.buttons["Highlights"].tap()
        sleep(1)
        snapshot(app, "5-highlights")
        app.buttons["PDF"].tap()
        sleep(1)
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

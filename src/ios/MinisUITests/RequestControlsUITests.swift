import XCTest

@MainActor
final class RequestControlsUITests: XCTestCase {

    func testRequestControlsPreserveTypedComposerText_BitsUT() {
        let app = launchNewChat()
        let composer = app.descendants(matching: .any)[
            "chatComposerTextView"
        ]
        let requestControlsButton = app.descendants(
            matching: .any
        )["requestControlsButton"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        XCTAssertTrue(
            requestControlsButton.waitForExistence(timeout: 5)
        )

        composer.tap()
        composer.typeText("keep this text")
        XCTAssertEqual(composer.value as? String, "keep this text")

        requestControlsButton.tap()
        let panel = app.scrollViews["requestControlsPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "keep this text")
    }

    func testCaptureRequestControlsKeyboardDismissal_BitsUT() {
        let app = launchNewChat()
        let composer = app.descendants(matching: .any)["chatComposerTextView"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        allowLocalNetworkAccessIfNeeded()
        composer.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)

        let attachmentButton = app.descendants(matching: .any)["attachmentMenuButton"]
        let requestControlsButton = app.descendants(matching: .any)["requestControlsButton"]
        XCTAssertTrue(attachmentButton.waitForExistence(timeout: 5))
        XCTAssertTrue(requestControlsButton.waitForExistence(timeout: 5))
        XCTAssertEqual(
            attachmentButton.frame.minY,
            requestControlsButton.frame.minY,
            accuracy: 1
        )

        requestControlsButton.tap()
        var maximumRelativeOffset: CGFloat = 0
        for _ in 0..<10 {
            maximumRelativeOffset = max(
                maximumRelativeOffset,
                abs(
                    attachmentButton.frame.minY
                        - requestControlsButton.frame.minY
                )
            )
            Thread.sleep(forTimeInterval: 0.03)
        }
        XCTAssertLessThanOrEqual(maximumRelativeOffset, 1)

        let panel = app.scrollViews["requestControlsPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        )

        XCTAssertEqual(
            attachmentButton.frame.minY,
            requestControlsButton.frame.minY,
            accuracy: 1
        )

        if panel.exists {
            let start = panel.coordinate(
                withNormalizedOffset: CGVector(dx: 0.25, dy: 0.55)
            )
            let end = panel.coordinate(
                withNormalizedOffset: CGVector(dx: 0.75, dy: 0.55)
            )
            start.press(
                forDuration: 0.05,
                thenDragTo: end,
                withVelocity: .slow,
                thenHoldForDuration: 0
            )
            XCTAssertTrue(panel.exists)
            XCTAssertFalse(app.keyboards.firstMatch.exists)
        }

        composer.tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)

        requestControlsButton.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let slashButton = app.descendants(matching: .any)["slashMenuButton"]
        XCTAssertTrue(slashButton.waitForExistence(timeout: 5))
        slashButton.tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    }

    func testRequestControlsRemainInteractiveInVoiceMode_BitsUT() {
        let app = launchNewChat()
        let requestControlsButton = app.descendants(matching: .any)[
            "requestControlsButton"
        ]
        let voiceInputButton = app.descendants(matching: .any)[
            "voiceInputButton"
        ]
        XCTAssertTrue(requestControlsButton.waitForExistence(timeout: 15))
        XCTAssertTrue(voiceInputButton.waitForExistence(timeout: 5))

        voiceInputButton.tap()
        allowSystemAlertIfNeeded()
        XCTAssertTrue(voiceInputButton.waitForExistence(timeout: 5))

        requestControlsButton.tap()
        let panel = app.scrollViews["requestControlsPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(voiceInputButton.exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)

        requestControlsButton.tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    }

    func testOpenCurrentModelRequestCustomization_BitsUT() {
        let app = launchNewChat()
        let requestControlsButton = app.descendants(matching: .any)[
            "requestControlsButton"
        ]
        XCTAssertTrue(requestControlsButton.waitForExistence(timeout: 15))
        requestControlsButton.tap()

        let configurationButton = app.buttons[
            "requestControlsConfigurationButton"
        ]
        XCTAssertTrue(configurationButton.waitForExistence(timeout: 5))
        configurationButton.tap()

        let editor = app.descendants(matching: .any)[
            "modelRequestCustomizationEditor"
        ]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))

        let saveButton = app.buttons[
            "modelRequestCustomizationSaveButton"
        ]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))

        XCTAssertTrue(requestControlsButton.waitForExistence(timeout: 5))
        requestControlsButton.tap()
        XCTAssertTrue(configurationButton.waitForExistence(timeout: 5))
        configurationButton.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
    }

    func testOpenModelPickerFromRequestControls_BitsUT() {
        let app = launchNewChat()
        let requestControlsButton = app.descendants(matching: .any)[
            "requestControlsButton"
        ]
        XCTAssertTrue(requestControlsButton.waitForExistence(timeout: 15))
        requestControlsButton.tap()

        let modelButton = app.descendants(matching: .any)[
            "requestControlsModelButton"
        ]
        XCTAssertTrue(modelButton.waitForExistence(timeout: 5))
        modelButton.tap()

        let modelPicker = app.descendants(matching: .any)[
            "sessionModelPicker"
        ]
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 5))
    }

    private func allowLocalNetworkAccessIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else { return }

        for title in ["Allow", "允许"] {
            let button = alert.buttons[title]
            if button.exists {
                button.tap()
                return
            }
        }

        let buttons = alert.buttons
        if buttons.count > 1 {
            buttons.element(boundBy: buttons.count - 1).tap()
        }
    }

    private func allowSystemAlertIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else { return }

        for title in [
            "Allow While Using App",
            "Allow",
            "OK",
            "使用 App 时允许",
            "允许",
            "好",
        ] {
            let button = alert.buttons[title]
            if button.exists {
                button.tap()
                return
            }
        }

        if alert.buttons.count > 0 {
            alert.buttons.element(boundBy: alert.buttons.count - 1).tap()
        }
    }

    private func launchNewChat() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-launchScreen", "2"]
        app.launch()
        return app
    }

}

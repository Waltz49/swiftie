import XCTest
@testable import Prowser

final class PreferencesStringMatchingTests: XCTestCase {
    func testEmptyQueryMatchesAll() {
        XCTAssertTrue(PreferencesStringMatching.prefixMatches(query: "", candidate: "General"))
        XCTAssertTrue(
            PreferencesStringMatching.tabMatches(
                tabTitle: "General",
                query: "",
                entries: [PreferencesStringEntry(text: "Behavior", kind: .header)]
            )
        )
    }

    func testPrefixMatchCaseInsensitive() {
        XCTAssertTrue(PreferencesStringMatching.prefixMatches(query: "del", candidate: "Delete confirmation"))
        XCTAssertTrue(PreferencesStringMatching.prefixMatches(query: "DEL", candidate: "delete"))
        XCTAssertFalse(PreferencesStringMatching.prefixMatches(query: "ete", candidate: "Delete"))
    }

    func testWordPrefixMatchWithinLabel() {
        XCTAssertTrue(
            PreferencesStringMatching.prefixMatches(
                query: "gps",
                candidate: "Open GPS locations in"
            )
        )
        XCTAssertFalse(
            PreferencesStringMatching.prefixMatches(
                query: "cation",
                candidate: "Open GPS locations in"
            )
        )
    }

    func testMapsTabMatchesGPSPickerLabel() {
        let entries = [
            PreferencesStringEntry(text: "Open GPS locations in", kind: .label),
        ]
        XCTAssertTrue(
            PreferencesStringMatching.tabMatches(
                tabTitle: "Maps and Editor",
                query: "gps",
                entries: entries
            )
        )
    }

    func testTabMatchesTitleOrEntry() {
        let entries = [
            PreferencesStringEntry(text: "Wrap around", kind: .label),
        ]
        XCTAssertTrue(PreferencesStringMatching.tabMatches(tabTitle: "General", query: "gen", entries: entries))
        XCTAssertTrue(PreferencesStringMatching.tabMatches(tabTitle: "General", query: "wrap", entries: entries))
        XCTAssertFalse(PreferencesStringMatching.tabMatches(tabTitle: "General", query: "lora", entries: entries))
    }
}

final class PreferencesStringsCacheFileTests: XCTestCase {
    func testCacheRoundTripAndValidation() throws {
        let fingerprint = "minBundle=0;imageGenUI=1"
        let original = PreferencesStringsCacheFile(
            visibilityFingerprint: fingerprint,
            tabs: [
                "general": [
                    PreferencesStringEntry(text: "General", kind: .header),
                    PreferencesStringEntry(text: "Behavior", kind: .label),
                ],
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PreferencesStringsCacheFile.self, from: data)
        XCTAssertEqual(decoded.formatVersion, PreferencesStringsCacheFile.formatVersion)
        XCTAssertTrue(decoded.isValid(forFingerprint: fingerprint))
        XCTAssertFalse(decoded.isValid(forFingerprint: "minBundle=1;imageGenUI=1"))
        XCTAssertEqual(decoded.tabs["general"]?.count, 2)
    }

    func testVisibilityFingerprintFormat() {
        let fp = PreferencesStringsCacheFile.visibilityFingerprint(minBundle: true)
        XCTAssertTrue(fp.contains("minBundle=1"))
        XCTAssertTrue(fp.contains("imageGenUI="))
    }
}

final class PreferencesNSViewStringCollectorTests: XCTestCase {
    func testSkipsEditableAndSmallText() {
        let editable = NSTextField(string: "secret value")
        editable.isEditable = true
        XCTAssertFalse(PreferencesNSViewStringCollector.shouldIncludeTextField(editable))

        let note = NSTextField(labelWithString: "subtitle note")
        note.font = NSFont.systemFont(ofSize: 11)
        XCTAssertFalse(PreferencesNSViewStringCollector.shouldIncludeTextField(note))

        let label = NSTextField(labelWithString: "Delete confirmation")
        label.font = NSFont.systemFont(ofSize: 13)
        XCTAssertTrue(PreferencesNSViewStringCollector.shouldIncludeTextField(label))
    }

    func testIncludesPlainOptionButtonTitles() {
        let radio = NSButton(title: "openai/clip-vit-base-patch32 — smaller, faster", target: nil, action: nil)
        radio.bezelStyle = .shadowlessSquare
        radio.isBordered = false
        XCTAssertTrue(PreferencesNSViewStringCollector.shouldIncludeOptionButtonTitle(radio))

        let choose = NSButton(title: "Choose…", target: nil, action: nil)
        choose.isBordered = true
        XCTAssertFalse(PreferencesNSViewStringCollector.shouldIncludeOptionButtonTitle(choose))
    }
}

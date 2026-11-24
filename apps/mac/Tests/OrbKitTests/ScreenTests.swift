import CoreGraphics
import Foundation
import Testing
@testable import OrbKit

@Suite struct TextMatchTests {
    let lines = ["Pricing — 2027", "The beta starts on the third of", "March, for 40 teams.", "Refunds: none."]

    @Test func anExactQuoteIgnoresCaseAndPunctuation() {
        #expect(TextMatch.find("the BETA starts", in: lines) == [.init(line: 1, range: 0..<15)])
        #expect(TextMatch.find("refunds none", in: lines) == [.init(line: 3, range: 0..<13)])
    }

    @Test func aQuoteRunsOverALineBreak() {
        #expect(TextMatch.find("third of March, for 40", in: lines) == [.init(line: 1, range: 23..<31),
                                                                              .init(line: 2, range: 0..<13)])
    }

    @Test func aMisreadLetterStillMatchesButADifferentPhraseDoesNot() {
        #expect(TextMatch.find("the beta stards on", in: lines) == [.init(line: 1, range: 0..<18)])
        #expect(TextMatch.find("the launch is delayed", in: lines) == nil)
        #expect(TextMatch.find("  ", in: lines) == nil)
    }

    @Test func aRepeatedPhrasePicksTheFirstOnScreen() {
        #expect(TextMatch.find("save", in: ["Save as", "Save"]) == [.init(line: 0, range: 0..<4)])
    }

    @Test func offsetsAreInUnicodeScalarsOfTheLine() {  // Devanagari's vowel signs and virama are scalars of their own
        #expect(TextMatch.find("नमस्ते दुनिया", in: ["» नमस्ते दुनिया"]) == [.init(line: 0, range: 2..<15)])
    }
}

@Suite struct ScreenMapTests {
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let left = CGRect(x: -1920, y: -98, width: 1920, height: 1080)

    @Test func aVisionBoxLandsOnItsDisplay() {
        let box = CGRect(x: 0.5, y: 0.25, width: 0.1, height: 0.02)
        let r = ScreenMap.rect(vision: box, display: main)
        #expect(abs(r.minX - 756) < 0.01 && abs(r.minY - 245.5) < 0.01 && abs(r.width - 151.2) < 0.01 && abs(r.height - 19.64) < 0.01)
        #expect(ScreenMap.rect(vision: box, display: left).minX == -960)
    }

    @Test func aGeminiPointHasItsOriginTopLeftAndIsClamped() {
        #expect(ScreenMap.point(x: 0, y: 0, display: main) == CGPoint(x: 0, y: 982))
        #expect(ScreenMap.point(x: 1000, y: 1000, display: left) == CGPoint(x: 0, y: -98))
        #expect(ScreenMap.point(x: 2000, y: -9, display: main) == CGPoint(x: 1512, y: 982))
    }

    @Test func aHighlightStaysInOneColumn() {
        let left1 = CGRect(x: 100, y: 500, width: 400, height: 14), left2 = CGRect(x: 100, y: 484, width: 380, height: 14)
        let right = CGRect(x: 700, y: 500, width: 60, height: 14)  // the same height, the other column
        #expect(ScreenMap.passage([left1, left2]) == [left1, left2])
        #expect(ScreenMap.passage([left1, right, left2]) == [left1])
        #expect(ScreenMap.passage([left1, CGRect(x: 100, y: 300, width: 400, height: 14)]) == [left1])  // far below
        #expect(ScreenMap.passage([]).isEmpty)
    }

    @Test func theDisplayUnderThePointerOrTheNearest() {
        #expect(ScreenChoice.display(pointer: CGPoint(x: -10, y: 10), displays: [main, left]) == 1)
        #expect(ScreenChoice.display(pointer: CGPoint(x: 700, y: 990), displays: [main, left]) == 0)
        #expect(ScreenChoice.display(pointer: .zero, displays: []) == nil)
    }
}

@Suite struct ScreenReadingTests {
    @Test func aHugeDocumentIsCutSoTheAnswerFitsAnRPC() throws {
        let hindi = String(repeating: "नमस्ते ", count: 5_000)  // 3 bytes a letter
        let r = ScreenReading(app: "Preview", window: "a.pdf", selection: String(repeating: "s", count: 9_000),
                              document: .init(name: "a.pdf", kind: "pdf", text: hindi),
                              screenText: String(repeating: "w", count: 20_000)).budgeted()
        let json = try #require(r.encoded())
        #expect(json.utf8.count <= ScreenReading.maxBytes)
        #expect(r.selection?.utf8.count == 1_500 && r.screenText?.utf8.count == 5_000)
        #expect(r.document?.cut == true && (r.document?.text.utf8.count ?? 0) > 3_000)
        #expect(json.contains("\"screen_text\""))
    }

    @Test func escapedTextStillFits() throws {
        let lines = String(repeating: "a/\"b\"\n", count: 4_000)  // each slash, quote and newline doubles in JSON
        let r = ScreenReading(app: "Code", document: .init(name: "x.swift", kind: "code", text: lines)).budgeted()
        #expect(try #require(r.encoded()).utf8.count <= ScreenReading.maxBytes && r.document?.cut == true)
    }

    @Test func aSmallReadingIsWhole() {
        let r = ScreenReading(app: "Notes", document: .init(name: "n.md", kind: "markdown", text: "Hi")).budgeted()
        #expect(r.document?.cut == false && r.document?.text == "Hi")
        #expect(r.seeing == "Notes · n.md" && ScreenReading(app: "Finder").seeing == "Finder")
    }
}

@Suite struct ScreenSettingsTests {
    @Test func anOldSavedSettingsGetsTheScreenAndSearchOn() throws {
        let old = #"{"serviceURL":"http://127.0.0.1:8100","search":false,"personas":false}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        #expect(s.screen && s.webSearch && s.config.geminiScreen == true && s.config.geminiSearch == true)
    }
}

@Suite struct FlightTests {
    @Test func itFollowsThePointerUntilItFlies() {
        #expect(Flight.follow.position(at: 5, pointer: CGPoint(x: 3, y: 4)) == CGPoint(x: 3, y: 4))
    }

    @Test func aFlightArcsAboveTheLineAndLandsOnTime() {
        let f = Flight(to: CGPoint(x: 400, y: 0), from: .zero, start: 10)
        #expect(f.position(at: 10, pointer: .zero) == .zero)
        let mid = f.position(at: 10.25, pointer: .zero)
        #expect(abs(mid.x - 200) < 0.001 && mid.y > 60)  // above the straight line
        #expect(f.position(at: 10.5, pointer: .zero) == CGPoint(x: 400, y: 0) && f.landed(at: 10.5))
    }

    @Test func aFlightBackEndsWhereThePointerIsNow() {
        let back = Flight(to: nil, from: CGPoint(x: 400, y: 0), start: 0, duration: 0.35)
        #expect(back.position(at: 1, pointer: CGPoint(x: 9, y: 9)) == CGPoint(x: 9, y: 9))
    }
}

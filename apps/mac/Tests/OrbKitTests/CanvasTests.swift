import CoreGraphics
import Foundation
import Testing
@testable import OrbKit

struct FakeGrounder: Grounder {
    let source: GroundSource
    var budget: Duration = .seconds(1)
    var answer: [Candidate] = []
    var delay: Duration = .zero
    var fails = false

    func candidates(_ target: Target, in frame: Frame) async throws -> [Candidate] {
        try await Task.sleep(for: delay)
        if fails { throw CocoaError(.featureUnsupported) }
        return answer
    }
}

@Suite struct GroundingTests {
    let frame = Frame(id: 7, displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1500, height: 1000),
                      excluded: [CGRect(x: 650, y: 950, width: 200, height: 40)])
    let here = [CGRect(x: 100, y: 500, width: 200, height: 18)]

    func ground(_ target: Target, _ grounders: [any Grounder], pointer: CGPoint = .zero) async -> Grounded {
        await Grounding(grounders).ground(target, in: frame, pointer: pointer)
    }

    @Test func eachKindGoesToItsGroundersInOrder() {
        #expect(Grounding.route(.text) == [.text, .sight])
        #expect(Grounding.route(.ui) == [.element, .text, .sight])
        #expect(Grounding.route(.visual) == [.sight])
    }

    @Test func aMissFallsThroughToTheNextGrounder() async {
        let result = await ground(Target("Export", kind: .ui), [
            FakeGrounder(source: .element), FakeGrounder(source: .text, fails: true),
            FakeGrounder(source: .sight, answer: [Candidate(rects: here, confidence: 0.8)])])
        #expect(result == .found(anchor: .screen(displayID: 1, rects: here, frameID: 7), by: .sight, matches: 1, confidence: 0.8))
    }

    @Test func aPictureNeverWaitsForText() async {
        let result = await ground(Target("the blue robot", kind: .visual), [
            FakeGrounder(source: .text, answer: [Candidate(rects: here)]), FakeGrounder(source: .sight)])
        #expect(result == .notFound("\"the blue robot\" is not on the screen."))
    }

    @Test func twoEqualMatchesAreCountedAndTheOneNearThePointerWins() async {
        let far = [CGRect(x: 1200, y: 100, width: 100, height: 18)]
        let result = await ground(Target("Save", kind: .text),
                                  [FakeGrounder(source: .text, answer: [Candidate(rects: here), Candidate(rects: far)])],
                                  pointer: CGPoint(x: 1250, y: 110))
        #expect(result == .found(anchor: .screen(displayID: 1, rects: far, frameID: 7), by: .text, matches: 2, confidence: nil))
    }

    @Test func aBetterScoreWinsOverNearness() async {
        let far = [CGRect(x: 1200, y: 100, width: 100, height: 18)]
        let result = await ground(Target("Save", kind: .ui), [FakeGrounder(source: .element, answer: [
            Candidate(rects: far, score: 0.6), Candidate(rects: here, score: 1)])], pointer: CGPoint(x: 1250, y: 110))
        #expect(result == .found(anchor: .screen(displayID: 1, rects: here, frameID: 7), by: .element, matches: 1, confidence: nil))
    }

    @Test func implausibleSightAnswersAreRefused() async {
        let outside = Candidate(rects: [CGRect(x: 1400, y: 900, width: 300, height: 300)])
        let most = Candidate(rects: [CGRect(x: 0, y: 0, width: 1400, height: 900)])
        let island = Candidate(rects: [CGRect(x: 700, y: 955, width: 60, height: 20)])
        let result = await ground(Target("zoom button", kind: .visual), [FakeGrounder(source: .sight, answer: [outside, most, island])])
        #expect(result == .notFound("\"zoom button\" is not on the screen."))
    }

    @Test func aGrounderPastItsBudgetIsNotFoundInTime() async {
        let result = await ground(Target("robot", kind: .visual), [
            FakeGrounder(source: .sight, budget: .milliseconds(20), answer: [Candidate(rects: here)], delay: .seconds(2))])
        #expect(result == .notFound("orb could not find \"robot\" in time."))
    }
}

@Suite struct CanvasReducerTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    func mark(_ id: String) -> Annotation {
        Annotation(id: id, kind: .mark(.box), anchor: .screen(displayID: 1, rects: [CGRect(x: 0, y: 0, width: 9, height: 9)], frameID: 1))
    }

    @Test func aMarkStaysWhileOrbTalksAndGoesSixSecondsAfter() {
        var s = Canvas.reduce(CanvasState(), .add(mark("a"), opID: "o1", at: t0))
        s = Canvas.reduce(s, .orbSpeaking)
        s = Canvas.reduce(s, .tick(t0 + 60))
        #expect(s.annotations.map(\.id) == ["a"])
        s = Canvas.reduce(s, .orbStopped(at: t0 + 61))
        #expect(Canvas.reduce(s, .tick(t0 + 66)).annotations.count == 1)
        #expect(Canvas.reduce(s, .tick(t0 + 67)).annotations.isEmpty)
    }

    @Test func aMarkOrbNeverTalksAboutGoesAfterTwelveSeconds() {
        var s = Canvas.reduce(CanvasState(), .add(mark("a"), opID: "o1", at: t0))
        s = Canvas.reduce(s, .orbStopped(at: t0 + 1))  // a state change before orb spoke does not shorten it
        #expect(Canvas.reduce(s, .tick(t0 + 11)).annotations.count == 1)
        #expect(Canvas.reduce(s, .tick(t0 + 12)).annotations.isEmpty)
    }

    @Test func theSameOpTwiceDrawsOnceAndTheNewestIsTheFocus() {
        var s = Canvas.reduce(CanvasState(), .add(mark("a"), opID: "o1", at: t0))
        s = Canvas.reduce(s, .add(mark("b"), opID: "o2", at: t0))
        s = Canvas.reduce(s, .add(mark("a2"), opID: "o1", at: t0))
        #expect(s.annotations.map(\.id) == ["a", "b"] && s.focus?.id == "b")
        #expect(Canvas.reduce(s, .remove("b")).focus?.id == "a")
    }

    @Test func talkingOrClearingWipesTheCanvas() {
        let s = Canvas.reduce(CanvasState(), .add(mark("a"), opID: "o1", at: t0))
        #expect(Canvas.reduce(s, .youSpoke).annotations.isEmpty && Canvas.reduce(s, .clear).expires == nil)
    }
}

@Suite struct CanvasContractTests {
    struct Contract: Decodable {
        var ops: [CanvasOp]
        var answers: [CanvasAnswer]
    }

    static let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../../contracts/canvas-ops.json").standardized

    @Test func theSharedFixtureDecodesAndEncodesTheSame() throws {
        let data = try Data(contentsOf: Self.url)
        let contract = try JSONDecoder().decode(Contract.self, from: data)
        #expect(contract.ops.map(\.op) == [.mark, .mark, .mark, .clear])
        #expect(contract.ops[1].kind == .visual && contract.ops[1].style == .circle)
        #expect(contract.answers[1] == .found(id: "a2", by: .sight, matches: 1, confidence: 0.9))
        let raw = try JSONSerialization.jsonObject(with: data) as! [String: [[String: Any]]]
        for (op, json) in zip(contract.ops, raw["ops"]!) {
            let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(op)) as! [String: Any]
            #expect(NSDictionary(dictionary: back).isEqual(to: json))
        }
    }

    @Test func anOpOfAnotherVersionOrShapeIsRefused() {
        #expect(CanvasOp.decode(#"{"v":2,"op":"clear","opId":"x"}"#) == nil)
        #expect(CanvasOp.decode(#"{"v":1,"op":"scribble","opId":"x"}"#) == nil)
        #expect(CanvasOp.decode(#"{"v":1,"op":"clear","opId":"x"}"#)?.op == .clear)
    }
}

@Suite struct GroundingPartsTests {
    @Test func everyOccurrenceOfAQuoteIsFound() {
        let lines = ["Save", "File  Save As…", "save"]
        #expect(TextMatch.all("save", in: lines).map(\.spans.first?.line) == [0, 1, 2])
        #expect(TextMatch.all("save as", in: lines).count == 1 && TextMatch.all("export", in: lines).isEmpty)
    }

    @Test func controlNamesScoreExactThenPrefixThenContains() {
        let q = ElementMatch.query("the Export button")
        #expect(q == "export")
        #expect(ElementMatch.score(q, name: "Export") == 1)
        #expect(ElementMatch.score(q, name: "Export as PDF…") == 0.8)
        #expect(ElementMatch.score(q, name: "Quick Export Options") == 0.6)
        #expect(ElementMatch.score(q, name: "Exporter") == nil && ElementMatch.score("save", name: "Save As…") == 0.8)
        #expect(ElementMatch.query("the button") == "the button")
    }

    @Test func aVisionBoxAndAnAccessibilityFrameMapToAppKitPoints() {
        let display = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        #expect(ScreenMap.rect(box2d: [500, 250, 600, 500], display: display)?.integral == CGRect(x: -1440, y: 332, width: 480, height: 108))
        #expect(ScreenMap.rect(box2d: [1, 2], display: display) == nil)
        #expect(ScreenMap.rect(accessibility: CGRect(x: 10, y: 20, width: 30, height: 40), mainHeight: 982) == CGRect(x: 10, y: 922, width: 30, height: 40))
    }
}

import CoreGraphics
import Testing
@testable import OrbKit

@Suite struct RoughTests {
    let word = CGRect(x: 100, y: 500, width: 240, height: 18)

    func bounds(_ strokes: [CGPath]) -> CGRect {
        strokes.map(\.boundingBoxOfPath).reduce(CGRect.null) { $0.union($1) }
    }

    @Test func aBoxSurroundsItsRectWithinTheJitter() {
        let strokes = Rough.strokes(.box, around: [word], seed: 7)
        #expect(strokes.count == 8)  // four sides, twice
        let b = bounds(strokes)
        #expect(b.insetBy(dx: -1, dy: -1).contains(word.insetBy(dx: 2, dy: 2)))
        #expect(word.insetBy(dx: -16, dy: -12).contains(b))
    }

    @Test func theSameSeedDrawsTheSameMarkAndAnotherDoesNot() {
        let a = Rough.strokes(.box, around: [word], seed: 1), b = Rough.strokes(.box, around: [word], seed: 1)
        let c = Rough.strokes(.box, around: [word], seed: 2)
        #expect(a == b && a != c)
    }

    @Test func aCircleIsOneLooseLoopAroundItsRect() {
        let picture = CGRect(x: 600, y: 300, width: 120, height: 90)
        let strokes = Rough.strokes(.circle, around: [picture], seed: 3)
        #expect(strokes.count == 1)
        let b = bounds(strokes)
        #expect(b.contains(CGPoint(x: picture.midX, y: picture.maxY + 4)) && b.width > picture.width)
        #expect(Rough.turns(of: Rough.circlePoints(picture, seed: 3)) > 1.0)  // the pen passes its start
    }

    @Test func anUnderlineSitsUnderEachLineAndAMarkerOverIt() {
        let next = word.offsetBy(dx: 0, dy: -22)
        let under = Rough.strokes(.underline, around: [word, next], seed: 4)
        #expect(under.count == 2)
        #expect(abs(under[0].boundingBoxOfPath.midY - word.minY) < 5)
        let marker = Rough.strokes(.marker, around: [word], seed: 4)
        #expect(abs(marker[0].boundingBoxOfPath.midY - word.midY) < 4)
        #expect(Rough.lineWidth(.marker, around: [word]) > 12 && Rough.lineWidth(.box, around: [word]) < 4)
    }
}

import XCTest
@testable import SystemHealth

final class CPUAverageTests: XCTestCase {
    private let base = ContinuousClock.now

    private func sample(at seconds: Int, user: UInt32 = 0, system: UInt32 = 0,
                        idle: UInt32 = 0, nice: UInt32 = 0) -> CPUSample {
        CPUSample(ticks: CPUTicks(user: user, system: system, idle: idle, nice: nice),
                  time: base + .seconds(seconds))
    }

    /// Counters that grow by 30 busy and 70 idle ticks per 60 s.
    private func steadySample(at seconds: Int) -> CPUSample {
        let steps = UInt32(seconds / 60)
        return sample(at: seconds, user: 30 * steps, idle: 70 * steps)
    }

    func testOneSampleIsNotKnown() {
        var ring = CPURing()
        ring.append(sample(at: 0))
        XCTAssertEqual(ring.average(over: .seconds(300)), .notKnown)
    }

    func testTwoSamplesAreAPartialAverage() {
        var ring = CPURing()
        ring.append(sample(at: 0))
        ring.append(sample(at: 60, user: 20, system: 5, idle: 70, nice: 5))
        guard case let .partial(percent, span) = ring.average(over: .seconds(300)) else {
            return XCTFail("expected partial")
        }
        XCTAssertEqual(percent, 30, accuracy: 0.001)
        XCTAssertEqual(span, .seconds(60))
    }

    func testWindowFullUsesNewestSampleAtLeastOneWindowOld() {
        var ring = CPURing()
        for seconds in stride(from: 0, through: 360, by: 60) {
            ring.append(steadySample(at: seconds))
        }
        guard case let .full(percent, span) = ring.average(over: .seconds(300)) else {
            return XCTFail("expected full")
        }
        XCTAssertEqual(percent, 30, accuracy: 0.001)
        XCTAssertEqual(span, .seconds(300))
    }

    func testUnevenSpacingDividesByRealSpan() {
        var ring = CPURing()
        ring.append(sample(at: 0))
        ring.append(sample(at: 75, user: 10, idle: 90))
        ring.append(sample(at: 190, user: 50, idle: 150))
        ring.append(sample(at: 340, user: 60, idle: 340))
        guard case let .full(percent, span) = ring.average(over: .seconds(300)) else {
            return XCTFail("expected full")
        }
        XCTAssertEqual(percent, 60.0 / 400.0 * 100, accuracy: 0.001)
        XCTAssertEqual(span, .seconds(340))
    }

    func testCounterWrap() {
        let old = CPUTicks(user: UInt32.max - 9, system: 0, idle: 100, nice: 0)
        var ring = CPURing()
        ring.append(CPUSample(ticks: old, time: base))
        ring.append(sample(at: 60, user: 20, idle: 170))
        guard case let .partial(percent, _) = ring.average(over: .seconds(300)) else {
            return XCTFail("expected partial")
        }
        XCTAssertEqual(percent, 30, accuracy: 0.001)
    }

    func testCapacityDropsOldest() {
        var ring = CPURing()
        for index in 0..<20 {
            ring.append(sample(at: index * 50, user: UInt32(index), idle: UInt32(index)))
        }
        guard case let .partial(_, span) = ring.average(over: .seconds(900)) else {
            return XCTFail("expected partial")
        }
        XCTAssertEqual(span, .seconds(800))
    }

    func testASpanUpToTheSlackShortOfTheWindowIsFull() {
        var ring = CPURing()
        ring.append(sample(at: 0))
        ring.append(sample(at: 50, user: 30, idle: 70))
        guard case let .full(percent, span) = ring.average(over: .seconds(60)) else {
            return XCTFail("expected full")
        }
        XCTAssertEqual(percent, 30, accuracy: 0.001)
        XCTAssertEqual(span, .seconds(50))
    }

    func testASpanMoreThanTheSlackShortOfTheWindowIsPartial() {
        var ring = CPURing()
        ring.append(sample(at: 0))
        ring.append(sample(at: 49, user: 30, idle: 70))
        guard case .partial = ring.average(over: .seconds(60)) else {
            return XCTFail("expected partial")
        }
    }

    func testLateFiresStillFillFifteenMinutes() {
        var ring = CPURing()
        ring.append(sample(at: 10))
        for index in 1..<17 {
            ring.append(steadySample(at: index * 60))
        }
        guard case .full = ring.average(over: .seconds(900)) else {
            return XCTFail("expected full")
        }
    }

    func testWindowChangeAppliesAtOnce() {
        var ring = CPURing()
        for index in 0..<17 {
            ring.append(steadySample(at: index * 60))
        }
        guard case .full = ring.average(over: .seconds(180)) else {
            return XCTFail("expected full for 3 min")
        }
        guard case .full = ring.average(over: .seconds(900)) else {
            return XCTFail("expected full for 15 min")
        }
    }

    func testRemoveAllIsNotKnown() {
        var ring = CPURing()
        ring.append(sample(at: 0))
        ring.append(sample(at: 60, user: 1, idle: 1))
        ring.removeAll()
        XCTAssertEqual(ring.average(over: .seconds(300)), .notKnown)
    }
}

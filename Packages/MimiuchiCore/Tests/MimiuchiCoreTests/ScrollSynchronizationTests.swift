import XCTest
@testable import MimiuchiCore

final class ScrollSynchronizationTests: XCTestCase {
    private func metrics(_ offset: Double, height: Double = 1200, viewport: Double = 200) -> ScrollSynchronization.Metrics {
        .init(offset: offset, contentHeight: height, viewportHeight: viewport)
    }

    private func linked() -> ScrollSynchronization {
        var state = ScrollSynchronization()
        _ = state.update(metrics(0), for: .source)
        _ = state.update(metrics(0, height: 2200), for: .translation)
        _ = state.setEnabled(true)
        return state
    }

    func testSourceScrollMapsToTranslationWithDifferentLength() {
        var state = linked()
        XCTAssertEqual(state.update(metrics(500), for: .source), [.translation: 1000])
        XCTAssertEqual(state.progress, 0.5)
    }

    func testTranslationScrollMapsBackToSource() {
        var state = linked()
        XCTAssertEqual(state.update(metrics(1500, height: 2200), for: .translation), [.source: 750])
        XCTAssertEqual(state.leader, .translation)
    }

    func testProgrammaticFollowerMovementDoesNotCauseFeedback() {
        var state = linked()
        _ = state.update(metrics(500), for: .source)
        XCTAssertTrue(state.update(metrics(1000, height: 2200), for: .translation, programmatic: true).isEmpty)
        XCTAssertEqual(state.leader, .source)
        XCTAssertTrue(state.update(metrics(1000, height: 2200), for: .translation).isEmpty)
        XCTAssertEqual(state.update(metrics(1200, height: 2200), for: .translation), [.source: 600])
    }

    func testDisabledScrollIsIndependentAndEnablingUsesLastScrolledPane() {
        var state = linked()
        _ = state.setEnabled(false)
        XCTAssertTrue(state.update(metrics(1000, height: 2200), for: .translation).isEmpty)
        XCTAssertEqual(state.setEnabled(true), [.source: 500, .translation: 1000])
    }

    func testStreamingTranslationGrowthPreservesReadingProgress() {
        var state = linked()
        _ = state.update(metrics(500), for: .source)
        XCTAssertEqual(state.update(metrics(1000, height: 4200), for: .translation), [.source: 500, .translation: 2000])
        XCTAssertEqual(state.leader, .source)
    }

    func testResizeUsesNewScrollableHeight() {
        var state = linked()
        _ = state.update(metrics(500), for: .source)
        XCTAssertEqual(state.update(metrics(500, viewport: 400), for: .source), [.source: 400, .translation: 1000])
    }

    func testShortDocumentDoesNotEraseProgress() {
        var state = linked()
        _ = state.update(metrics(500), for: .source)
        XCTAssertEqual(state.update(metrics(0, height: 100), for: .translation)[.translation], 0)
        XCTAssertEqual(state.progress, 0.5)
        XCTAssertEqual(state.update(metrics(0, height: 2200), for: .translation)[.translation], 1000)
    }

    func testEndpointsAndRubberBandOffsetsAreClamped() {
        XCTAssertEqual(metrics(-50).progress, 0)
        XCTAssertEqual(metrics(1500).progress, 1)
        XCTAssertEqual(metrics(0, height: 100).progress, 0)
        var state = linked()
        XCTAssertEqual(state.update(metrics(1000), for: .source)[.translation], 2000)
        XCTAssertEqual(state.update(metrics(0), for: .source)[.translation], 0)
    }

    func testRemovingAndReattachingPaneRestoresProgress() {
        var state = linked()
        _ = state.update(metrics(500), for: .source)
        state.remove(.source)
        XCTAssertEqual(state.update(metrics(0, height: 1800), for: .source)[.source], 800)
    }

    func testNewDocumentResetsBothPanesEvenWhenDisabled() {
        var state = linked()
        _ = state.update(metrics(500), for: .source)
        _ = state.setEnabled(false)
        XCTAssertEqual(state.reset(), [.source: 0, .translation: 0])
        XCTAssertEqual(state.progress, 0)
        XCTAssertEqual(state.leader, .source)
    }
}

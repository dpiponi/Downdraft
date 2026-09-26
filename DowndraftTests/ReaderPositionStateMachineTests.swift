import XCTest
@testable import Downdraft

final class ReaderPositionStateMachineTests: XCTestCase {
    private let remote = ReaderPositionRevision(
        pageIndex: 113,
        sequence: 42,
        deviceID: "beskar",
        deviceName: "Beskar"
    )

    private func state(
        page: Int = 12,
        linked: Bool = true,
        pending: ReaderPositionRevision? = nil,
        handled: ReaderPositionRevision? = nil
    ) -> ReaderPositionState {
        ReaderPositionState(
            confirmedPage: page,
            localPage: page,
            linked: linked,
            startupProtected: false,
            pendingShared: pending,
            handledShared: handled,
            history: []
        )
    }

    func testRawPDFReportDoesNotChangeStateOrSaveProgress() {
        let original = state(page: 166)
        let result = ReaderPositionStateMachine.transition(
            original,
            event: .pdfReportedPage(0)
        )

        XCTAssertEqual(result.state, original)
        XCTAssertEqual(result.effects, [])
    }

    func testSharedConflictKeepsCurrentPageAndOffersChoice() {
        let result = ReaderPositionStateMachine.transition(
            state(page: 12),
            event: .sharedArrived(remote)
        )

        XCTAssertEqual(result.state.confirmedPage, 12)
        XCTAssertEqual(result.state.pendingShared, remote)
        XCTAssertEqual(result.effects, [.showConflict(remote)])
    }

    func testKeepLocalSuppressesOnlyThatSharedRevision() {
        let pending = state(page: 12, pending: remote)
        let kept = ReaderPositionStateMachine.transition(pending, event: .keepLocal)
        let repeated = ReaderPositionStateMachine.transition(
            kept.state,
            event: .sharedArrived(remote)
        )

        XCTAssertEqual(kept.state.confirmedPage, 12)
        XCTAssertEqual(kept.state.handledShared, remote)
        XCTAssertNil(repeated.state.pendingShared)
        XCTAssertEqual(repeated.effects, [])
    }

    func testRevisionIdentityDoesNotDependOnDeviceDisplayName() {
        let reconstructed = ReaderPositionRevision(
            pageIndex: 113,
            sequence: 42,
            deviceID: "beskar",
            deviceName: nil
        )

        XCTAssertEqual(remote, reconstructed)
        let result = ReaderPositionStateMachine.transition(
            state(page: 12, handled: reconstructed),
            event: .sharedArrived(remote)
        )
        XCTAssertEqual(result.effects, [])
    }

    func testAcceptSharedAddsOneHistoryEntryAndMovesPage() {
        let result = ReaderPositionStateMachine.transition(
            state(page: 12, pending: remote),
            event: .acceptShared
        )

        XCTAssertEqual(result.state.confirmedPage, 113)
        XCTAssertEqual(result.state.localPage, 113)
        XCTAssertEqual(result.state.history, [12])
        XCTAssertEqual(
            result.effects,
            [
                .addHistory(from: 12, to: 113),
                .showPage(113),
                .saveLocal(113)
            ]
        )
    }

    func testLinkedAndDetachedReaderMovesHaveDifferentWriteEffects() {
        let linked = ReaderPositionStateMachine.transition(state(linked: true), event: .readerMoved(20))
        let detached = ReaderPositionStateMachine.transition(state(linked: false), event: .readerMoved(20))

        XCTAssertEqual(linked.effects, [.saveLocal(20), .saveShared(20)])
        XCTAssertEqual(detached.effects, [.saveLocal(20)])
    }

    func testExplicitJumpRecordsHistoryBeforeRequestingPage() {
        let result = ReaderPositionStateMachine.transition(
            state(page: 12),
            event: .explicitJump(113)
        )

        XCTAssertEqual(result.state.confirmedPage, 113)
        XCTAssertEqual(result.state.localPage, 113)
        XCTAssertEqual(result.state.history, [12])
        XCTAssertEqual(
            result.effects,
            [.addHistory(from: 12, to: 113), .showPage(113)]
        )
    }

    func testExplicitJumpToCurrentPageDoesNotCreateHistory() {
        let original = state(page: 12)
        let result = ReaderPositionStateMachine.transition(original, event: .explicitJump(12))

        XCTAssertEqual(result.state, original)
        XCTAssertEqual(result.effects, [])
    }
}

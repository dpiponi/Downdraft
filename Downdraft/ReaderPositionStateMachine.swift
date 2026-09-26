import Foundation

/// The Swift counterpart of `ReaderStateModel/ReaderStateModel.lean`.
///
/// UIKit, PDFKit, and iCloud are adapters around this reducer. They may emit
/// events asynchronously, but only the effects returned here are allowed to
/// change a reading position or shared state.
struct ReaderPositionRevision: Equatable {
    let pageIndex: Int
    let sequence: Int64
    let deviceID: String
    let deviceName: String?

    // The Lean model identifies a shared revision by page, sequence, and
    // device. A device name is only UI decoration and is not retained in the
    // local handled-revision record, so it must not create a false conflict.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pageIndex == rhs.pageIndex
            && lhs.sequence == rhs.sequence
            && lhs.deviceID == rhs.deviceID
    }
}

struct ReaderPositionState: Equatable {
    var confirmedPage: Int
    var localPage: Int
    var linked: Bool
    var startupProtected: Bool
    var pendingShared: ReaderPositionRevision?
    var handledShared: ReaderPositionRevision?
    var history: [Int]
}

enum ReaderPositionEvent: Equatable {
    case initialRestoreConfirmed(Int)
    case startupProtectionExpired
    case pdfReportedPage(Int)
    case readerMoved(Int)
    case explicitJump(Int)
    case sharedArrived(ReaderPositionRevision)
    case acceptShared
    case keepLocal
}

enum ReaderPositionEffect: Equatable {
    case showPage(Int)
    case saveLocal(Int)
    case saveShared(Int)
    case showConflict(ReaderPositionRevision)
    case addHistory(from: Int, to: Int)
}

enum ReaderPositionStateMachine {
    static func transition(
        _ state: ReaderPositionState,
        event: ReaderPositionEvent
    ) -> (state: ReaderPositionState, effects: [ReaderPositionEffect]) {
        switch event {
        case let .initialRestoreConfirmed(page):
            var next = state
            next.confirmedPage = page
            next.localPage = page
            next.startupProtected = true
            next.pendingShared = nil
            return (next, [])

        case .startupProtectionExpired:
            var next = state
            next.startupProtected = false
            return (next, [])

        case .pdfReportedPage:
            // Raw PDFKit reports are observations. The adapter must emit a
            // `.readerMoved` event only after confirming a real user action.
            return (state, [])

        case let .readerMoved(page):
            var next = state
            next.confirmedPage = page
            next.localPage = page
            if state.linked {
                return (next, [.saveLocal(page), .saveShared(page)])
            }
            return (next, [.saveLocal(page)])

        case let .explicitJump(page):
            guard state.localPage != page else { return (state, []) }
            var next = state
            next.confirmedPage = page
            next.localPage = page
            next.history.insert(state.localPage, at: 0)
            return (
                next,
                [.addHistory(from: state.localPage, to: page), .showPage(page)]
            )

        case let .sharedArrived(revision):
            guard state.linked, state.handledShared != revision else {
                return (state, [])
            }
            if state.localPage == revision.pageIndex {
                var next = state
                next.handledShared = revision
                return (next, [])
            }
            var next = state
            next.pendingShared = revision
            return (next, [.showConflict(revision)])

        case .acceptShared:
            guard let revision = state.pendingShared else { return (state, []) }
            var next = state
            next.confirmedPage = revision.pageIndex
            next.localPage = revision.pageIndex
            next.pendingShared = nil
            next.handledShared = revision
            guard state.localPage != revision.pageIndex else {
                return (next, [.saveLocal(revision.pageIndex)])
            }
            next.history.insert(state.localPage, at: 0)
            return (
                next,
                [
                    .addHistory(from: state.localPage, to: revision.pageIndex),
                    .showPage(revision.pageIndex),
                    .saveLocal(revision.pageIndex)
                ]
            )

        case .keepLocal:
            guard let revision = state.pendingShared else { return (state, []) }
            var next = state
            next.pendingShared = nil
            next.handledShared = revision
            return (next, [])
        }
    }
}

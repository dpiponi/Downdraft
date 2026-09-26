import SwiftUI

/// Geometry policy for the reader's floating chrome.
///
/// Portrait preserves the established layout. Compact landscape derives its
/// placement from the physical safe areas so the camera island and Home
/// indicator do not compete with the reader controls.
struct ReaderChromeLayout {
    let isPhone: Bool
    let isLandscape: Bool
    let safeArea: EdgeInsets

    var horizontalLeading: CGFloat { max(28, safeArea.leading + 16) }
    var horizontalTrailing: CGFloat { max(28, safeArea.trailing + 16) }

    var topPadding: CGFloat {
        if isPhone {
            return isLandscape ? max(16, safeArea.top + 10) : 56
        }
        return max(42, safeArea.top + 12)
    }

    var topHitAreaHeight: CGFloat {
        isPhone ? (isLandscape ? 92 : 180) : 140
    }

    var scrubberBottomInset: CGFloat {
        guard isPhone, isLandscape else { return isPhone ? 36 : 42 }
        return max(28, safeArea.bottom + 12)
    }

    var bookmarkBottomInset: CGFloat {
        if isPhone, isLandscape {
            return max(96, scrubberBottomInset + 72)
        }
        let baseline: CGFloat = isPhone ? 176 : 144
        return max(baseline, scrubberBottomInset + 132)
    }

    var bookmarkTopClearance: CGFloat {
        if isPhone { return isLandscape ? 108 : 180 }
        return 140
    }

    var bookmarksUseLeadingEdge: Bool {
        isPhone && isLandscape && safeArea.leading < safeArea.trailing
    }

    var bookmarkEdgeInset: CGFloat {
        bookmarksUseLeadingEdge ? safeArea.leading : safeArea.trailing
    }

    var scrubberMaximumWidth: CGFloat {
        isPhone && isLandscape ? 620 : (isPhone ? 320 : 680)
    }

    var bookmarkPreviewBottomInset: CGFloat {
        if isPhone, isLandscape {
            return bookmarkBottomInset
        }
        return isPhone ? 168 : 130
    }
}

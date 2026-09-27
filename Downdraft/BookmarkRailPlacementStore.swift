import Foundation

/// Device-local placement for the bookmark rail. Values are normalized so a
/// placement remains sensible when the available height changes; they are not
/// part of document or iCloud reading state.
enum BookmarkRailPlacementStore {
    private static let portraitKey = "bookmark-rail-placement-portrait"
    private static let landscapeKey = "bookmark-rail-placement-landscape"
    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    static func placement(isLandscape: Bool) -> CGFloat {
        let value = defaults.object(forKey: key(isLandscape: isLandscape)) as? Double ?? 0
        return CGFloat(min(max(value, 0), 1))
    }

    static func save(_ placement: CGFloat, isLandscape: Bool) {
        defaults.set(Double(min(max(placement, 0), 1)), forKey: key(isLandscape: isLandscape))
    }

    private static func key(isLandscape: Bool) -> String {
        isLandscape ? landscapeKey : portraitKey
    }
}

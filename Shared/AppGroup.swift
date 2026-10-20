import Foundation

/// The App Group container the app and the tunnel extension share: profiles, the selected
/// profile, the tunnel log. Group id comes from Info.plist (`CainAppGroup` = group.<bundle id>).
enum AppGroup {
    static let id: String =
        Bundle.main.object(forInfoDictionaryKey: "CainAppGroup") as? String ?? "group.dev.boringbox.cain"

    /// The group container, or the app's own Application Support when the group is not
    /// provisioned (unit tests, unsigned builds) so nothing crashes; the extension then won't
    /// see the same files, which only matters on a real device.
    static let root: URL = {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CainGroup", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }()
}

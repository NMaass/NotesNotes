import Foundation

/// Storage shared by the app, the widget extension, and the share extension.
///
/// Identifiers come from each target's Info.plist (`ResonoteAppGroup`, which is
/// also the keychain access group) so signing teams can change without code edits. When a
/// build has no App Group entitlement (an unsigned simulator build), everything
/// falls back to per-process storage instead of failing.
public enum AppGroup {
    public static let identifier: String = Bundle.main.object(forInfoDictionaryKey: "ResonoteAppGroup") as? String ?? "group.dev.nmaass.resonote"

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    /// The shared container, or Application Support when the group is unavailable.
    public static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        let fallback = URL.applicationSupportDirectory.appending(path: "Resonote", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    public static func fileURL(_ name: String) -> URL {
        containerURL.appending(path: name, directoryHint: .notDirectory)
    }

    /// The API base URL, overridable per build through `ResonoteAPIBaseURL`.
    public static var apiBaseURL: URL {
        if let value = Bundle.main.object(forInfoDictionaryKey: "ResonoteAPIBaseURL") as? String,
           let url = URL(string: value), url.scheme != nil {
            return url
        }
        return APIClient.defaultBaseURL
    }
}

/// When another process (the share extension) last wrote to the person's journal on the
/// server. The app reads its journal again on its next activation if that is newer than
/// its own last read, so a note saved from the share sheet shows up right away.
public enum ExternalWrites {
    static let key = "external-write-at"

    public static func mark(at date: Date = Date(), in defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(date.timeIntervalSince1970, forKey: key)
    }

    public static func last(in defaults: UserDefaults = AppGroup.defaults) -> Date? {
        let seconds = defaults.double(forKey: key)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// Whether something was written elsewhere after `read` (or ever, when there was no read).
    public static func happened(after read: Date?, in defaults: UserDefaults = AppGroup.defaults) -> Bool {
        guard let last = last(in: defaults) else { return false }
        guard let read else { return true }
        return last > read
    }
}

/// Reads and writes small Codable files in the shared container atomically.
public enum SharedFile {
    public static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: AppGroup.fileURL(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// `read` away from the caller's actor, for files large enough to matter on launch.
    @concurrent
    public static func readInBackground<T: Decodable & Sendable>(_ type: T.Type, from name: String) async -> T? {
        read(type, from: name)
    }

    public static func write(_ value: some Encodable, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: AppGroup.fileURL(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: AppGroup.fileURL(name))
    }
}

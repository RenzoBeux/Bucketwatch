import Foundation

// MARK: - Configuration (written by the app)

enum SyncMode: String, Codable, CaseIterable, Identifiable {
    /// Only adds and updates files in the bucket. Deleting locally never deletes remotely.
    case copy
    /// Mirrors the folder: files deleted locally are removed from the bucket too.
    case sync
    var id: String { rawValue }
}

enum DestinationKind: String, Codable, CaseIterable, Identifiable {
    /// Backblaze B2 with an application key stored in the Keychain.
    case b2
    /// Any remote already configured in rclone (`rclone config`).
    case rcloneRemote
    var id: String { rawValue }
}

struct Destination: Codable, Hashable {
    var kind: DestinationKind = .b2
    var keyID: String = ""
    var bucket: String = ""
    var remote: String = ""
    var path: String = ""
}

enum ScheduleKind: String, Codable, CaseIterable, Identifiable {
    case manual, interval, daily
    var id: String { rawValue }
}

struct Schedule: Codable, Hashable {
    var kind: ScheduleKind = .manual
    var everyHours: Int = 6
    var dailyHour: Int = 3
    var dailyMinute: Int = 0
    var onlyOnPower: Bool = true
    var skipExpensiveNetwork: Bool = true
}

struct Pair: Codable, Hashable, Identifiable {
    static let defaultExcludes = [".DS_Store", "._*", "*.partial"]

    var id = UUID()
    var name: String = "New folder"
    var localPath: String = ""
    var destination = Destination()
    var mode: SyncMode = .copy
    var excludes: [String] = Pair.defaultExcludes
    var checkEveryMinutes: Int = 60
    var schedule = Schedule()
    var enabled: Bool = true

    /// Fields that change what "in sync" means. Editing any of them invalidates the last check.
    var comparisonKey: [String] {
        [localPath, destination.kind.rawValue, destination.keyID, destination.bucket,
         destination.remote, destination.path, mode.rawValue] + excludes
    }
}

// MARK: - Status (shared with the widget)

enum PairState: String, Codable {
    case unknown, checking, inSync, pending, running, error
}

struct PairStatus: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var state: PairState = .unknown
    var pendingFiles: Int = 0
    var pendingBytes: Int64 = 0
    var remoteOnlyFiles: Int = 0
    var lastChecked: Date?
    var lastRun: Date?
    var progress: Double?
    var bytesDone: Int64?
    var bytesTotal: Int64?
    var speed: Double?
    var eta: Double?
    var message: String?
}

struct Snapshot: Codable {
    var updated: Date
    var pairs: [PairStatus]

    static let empty = Snapshot(updated: .distantPast, pairs: [])

    var overall: PairState {
        let states = pairs.map(\.state)
        if states.isEmpty { return .unknown }
        if states.contains(.running) { return .running }
        if states.contains(.error) { return .error }
        if states.contains(.pending) { return .pending }
        if states.contains(.checking) { return .checking }
        if states.allSatisfy({ $0 == .inSync }) { return .inSync }
        return .unknown
    }

    var pendingBytes: Int64 { pairs.filter { $0.state == .pending }.reduce(0) { $0 + $1.pendingBytes } }

    static let sample = Snapshot(updated: .now, pairs: [
        PairStatus(id: UUID(), name: "Trip footage", state: .running, pendingFiles: 12,
                   pendingBytes: 9_000_000_000, progress: 0.43, speed: 2_400_000, eta: 3700),
        PairStatus(id: UUID(), name: "Photos 2026", state: .pending, pendingFiles: 37,
                   pendingBytes: 1_800_000_000, lastChecked: .now),
        PairStatus(id: UUID(), name: "Documents", state: .inSync, lastChecked: .now),
    ])
}

enum SharedStore {
    static var groupID: String {
        Bundle.main.object(forInfoDictionaryKey: "BucketwatchAppGroup") as? String ?? ""
    }

    static var snapshotURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("status.json")
    }

    static func load() -> Snapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    static func save(_ snapshot: Snapshot) {
        guard let url = snapshotURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}

enum Fmt {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: seconds) ?? ""
    }

    static func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }
}

import Foundation

// Old hidden files on B2.
//
// When a file is deleted from a B2 bucket (a Sync, a Sync once), B2 only "hides" it: a hide marker
// becomes the newest version and the data stays stored, and billed, until something deletes the
// versions. Buckets without a lifecycle rule keep them forever.
//
// Bucketwatch scans each B2 pair once a day (read-only) and suggests deleting files that have been
// hidden for at least 30 days. Deleting is permanent, so it only ever happens after the user reviews
// the exact list, and each file is checked again right before its versions are deleted.

enum HiddenFiles {
    static let minimumAge: TimeInterval = 30 * 86_400
    static let minimumDays = 30
}

/// Where a pair's files live on B2, and the key to reach them.
struct B2Target {
    var credentials: B2Client.Credentials
    var bucket: String
    /// The pair's folder inside the bucket, ending in "/" (or "" for the whole bucket).
    var prefix: String

    /// nil when the pair isn't on B2. Throws when it is, but the key can't be found.
    static func resolve(_ pair: Pair, remotes: [String: [String: String]]) throws -> B2Target? {
        guard let location = Rclone.location(pair, remotes: remotes), location.store == "b2",
              let bucket = location.components.first else { return nil }
        let folder = location.components.dropFirst().joined(separator: "/")
        let prefix = folder.isEmpty ? "" : folder + "/"
        var credentials: B2Client.Credentials
        if pair.destination.kind == .b2 {
            credentials = .init(keyID: pair.destination.keyID.trimmingCharacters(in: .whitespaces),
                                appKey: Keychain.get(pair.id.uuidString) ?? "")
        } else {
            guard let remote = location.remote, let conf = remotes[remote] else { return nil }
            credentials = .init(keyID: conf["account"] ?? "", appKey: conf["key"] ?? "")
            if let endpoint = conf["endpoint"], !endpoint.isEmpty {
                credentials.endpoint = endpoint.hasPrefix("http") ? endpoint : "https://" + endpoint
            }
        }
        if credentials.keyID.isEmpty || credentials.appKey.isEmpty {
            throw PlanError("Couldn't find the B2 key for this folder.")
        }
        return B2Target(credentials: credentials, bucket: bucket, prefix: prefix)
    }
}

/// A file whose newest version is a hide marker.
struct HiddenFile: Hashable, Identifiable {
    /// Full name in the bucket.
    var name: String
    /// Path relative to the pair's folder.
    var path: String
    var hiddenAt: Date
    /// The hide marker that is the newest version at review time.
    var markerID: String
    /// Every version of the file, newest first. All of them are deleted.
    var versions: [B2Version]

    var id: String { name }
    var bytes: Int64 { versions.reduce(0) { $0 + $1.size } }
}

struct HiddenPlan {
    var pair: Pair
    var bucket: String
    var prefix: String
    var created = Date()
    /// Hidden for at least 30 days: suggested for deletion.
    var old: [HiddenFile] = []
    /// Hidden more recently: shown only as a count.
    var recentCount = 0
    var recentBytes: Int64 = 0
    /// Old hidden files that are back in the folder. Kept: the next backup uploads them again.
    var backInFolder: [HiddenFile] = []

    var oldBytes: Int64 { old.reduce(0) { $0 + $1.bytes } }
}

enum HiddenScanner {
    /// Groups a listing by name and keeps the files whose newest version is a hide marker. Files with
    /// an unfinished upload, an unknown kind of version or an ambiguous newest version are left alone.
    static func hiddenFiles(_ versions: [B2Version], prefix: String) -> [HiddenFile] {
        var byName: [String: [B2Version]] = [:]
        for version in versions where version.name.hasPrefix(prefix) {
            byName[version.name, default: []].append(version)
        }
        var result: [HiddenFile] = []
        for (name, list) in byName {
            guard list.allSatisfy({ $0.action == "upload" || $0.action == "hide" }) else { continue }
            let sorted = list.sorted { $0.uploaded > $1.uploaded }
            guard let newest = sorted.first, newest.action == "hide" else { continue }
            if sorted.count > 1 && sorted[1].uploaded == newest.uploaded { continue }
            result.append(HiddenFile(name: name, path: String(name.dropFirst(prefix.count)),
                                     hiddenAt: newest.uploaded, markerID: newest.id, versions: sorted))
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Read-only. `strictLocal` (the review) requires the folder and fails if a file can't be checked
    /// in it; the daily scan just skips the folder check when it can't be done.
    static func plan(pair: Pair, target: B2Target, client: B2Client, now: Date = Date(),
                     strictLocal: Bool) async throws -> HiddenPlan {
        let root = URL(fileURLWithPath: pair.localPath)
        var folderReadable = true
        do { try LocalProbe.requireFolder(root) } catch {
            if strictLocal { throw error }
            folderReadable = false
        }
        let bucketID = try await client.bucketID(named: target.bucket)
        let versions = try await client.allVersions(bucketID: bucketID, prefix: target.prefix)
        var plan = HiddenPlan(pair: pair, bucket: target.bucket, prefix: target.prefix)
        for file in hiddenFiles(versions, prefix: target.prefix) {
            guard now.timeIntervalSince(file.hiddenAt) >= HiddenFiles.minimumAge else {
                plan.recentCount += 1
                plan.recentBytes += file.bytes
                continue
            }
            if folderReadable {
                switch LocalProbe.presence(file.path, under: root) {
                case .missing: break
                case .present:
                    plan.backInFolder.append(file)
                    continue
                case .unknown(let reason):
                    if strictLocal { throw PlanError("Couldn't check “\(file.path)” in the folder (\(reason)). Nothing was deleted.") }
                }
            }
            plan.old.append(file)
        }
        plan.created = Date()
        return plan
    }
}

enum HiddenPurger {
    enum Outcome: Equatable {
        case deleted
        /// Restored, uploaded again or otherwise changed since the review: left as it is.
        case changed
    }

    /// Deletes every version of one reviewed hidden file, after checking that nothing about it changed.
    /// Data versions go first and hide markers last, newest marker at the very end: if anything fails
    /// halfway, the file is still hidden rather than brought back.
    static func purge(_ file: HiddenFile, bucketID: String, client: B2Client) async throws -> Outcome {
        guard let current = try await client.versions(of: file.name, bucketID: bucketID),
              let newest = current.max(by: { $0.uploaded < $1.uploaded }),
              newest.id == file.markerID, newest.action == "hide",
              !current.contains(where: { $0.id != newest.id && $0.uploaded >= newest.uploaded }) else {
            return .changed
        }
        let reviewed = Set(file.versions.map(\.id))
        guard current.allSatisfy({ reviewed.contains($0.id) }) else { return .changed }

        let data = current.filter { $0.action != "hide" }.sorted { $0.uploaded < $1.uploaded }
        let markers = current.filter { $0.action == "hide" }.sorted { $0.uploaded < $1.uploaded }
        for version in data + markers {
            try await client.deleteVersion(name: file.name, id: version.id)
        }
        return .deleted
    }

    struct Report {
        var deleted = 0
        var deletedBytes: Int64 = 0
        var changed = 0
        var error: String?
        var stopped = false
    }

    /// Purges the reviewed files one by one. `shouldStop` is checked between files.
    static func run(_ plan: HiddenPlan, target: B2Target, client: B2Client,
                    shouldStop: @escaping () -> Bool, progress: @escaping (Int) -> Void) async -> Report {
        var report = Report()
        let bucketID: String
        do {
            if let caps = try? await client.capabilities(), !caps.isEmpty, !caps.contains("deleteFiles") {
                report.error = "The B2 key isn't allowed to delete files"
                return report
            }
            bucketID = try await client.bucketID(named: target.bucket)
        } catch {
            report.error = error.localizedDescription
            return report
        }
        for (index, file) in plan.old.enumerated() {
            if shouldStop() { report.stopped = true; break }
            do {
                switch try await purge(file, bucketID: bucketID, client: client) {
                case .deleted:
                    report.deleted += 1
                    report.deletedBytes += file.bytes
                case .changed:
                    report.changed += 1
                }
            } catch {
                report.error = "“\(file.path)”: \(error.localizedDescription)"
                break
            }
            progress(index + 1)
        }
        return report
    }
}

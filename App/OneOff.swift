import Foundation

// One-off operations that leave the pair's mode alone:
//   • Download from cloud: copies files that are only in the bucket into the folder. Never
//     overwrites or deletes anything in the folder.
//   • Sync once: uploads what's missing, then removes from the bucket the files that are no
//     longer in the folder.
//
// Both start from a read-only plan the user reviews. Execution acts on exactly the reviewed file
// list (`--files-from-raw`), never on a fresh comparison, so nothing the user didn't see is touched.

enum OneOffKind: String, Identifiable {
    case download, syncOnce
    var id: String { rawValue }
}

struct PlanEntry: Hashable {
    /// Exactly as rclone printed it. Handed back to rclone unchanged, so never normalize it.
    var path: String
    var size: Int64?
}

struct TransferPlan {
    var kind: OneOffKind
    var pair: Pair
    var created = Date()
    /// Only in the bucket: downloaded, or removed from the bucket by a sync.
    var cloudOnly: [PlanEntry] = []
    /// Missing from the bucket or different there: uploaded first by a sync.
    var toUpload: [PlanEntry] = []
    var localFiles = 0
    var remoteFiles = 0
    /// Free space on the folder's disk (downloads).
    var freeBytes: Int64?
    /// What happens to removed files on this destination (syncs).
    var retention: String?
    /// rclone processes Bucketwatch didn't start.
    var otherRclone: [String] = []

    static let headroom: Int64 = 2_000_000_000

    var cloudOnlyBytes: Int64 { cloudOnly.reduce(0) { $0 + ($1.size ?? 0) } }
    var uploadBytes: Int64 { toUpload.reduce(0) { $0 + ($1.size ?? 0) } }
    var unknownSizes: Int { cloudOnly.filter { $0.size == nil }.count }

    var isEmpty: Bool { kind == .download ? cloudOnly.isEmpty : cloudOnly.isEmpty && toUpload.isEmpty }

    /// Bytes missing on disk for a download, keeping some headroom free. nil when it fits.
    var spaceShortfall: Int64? {
        guard kind == .download, !cloudOnly.isEmpty, let freeBytes else { return nil }
        let needed = cloudOnlyBytes + Self.headroom
        return needed > freeBytes ? needed - freeBytes : nil
    }

    /// A sync that would remove at least half of what's in the bucket needs an explicit acknowledgement.
    var removesMostOfBucket: Bool {
        kind == .syncOnce && !cloudOnly.isEmpty && cloudOnly.count * 2 >= remoteFiles
    }
}

struct PlanError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Planning

/// Builds a plan. Read-only: it compares and lists, nothing else. Cancellable from any thread.
final class PlanBuilder: @unchecked Sendable {
    private let lock = NSLock()
    private var current: RcloneCall?
    private var cancelled = false

    func cancel() {
        let call = lock.withLock { () -> RcloneCall? in
            cancelled = true
            return current
        }
        call?.cancel()
    }

    private func run(_ binary: String, _ arguments: [String], _ environment: [String: String]) async throws -> RcloneResult {
        let call = RcloneCall()
        let stop = lock.withLock { () -> Bool in
            if cancelled { return true }
            current = call
            return false
        }
        if stop { throw CancellationError() }
        let result = await call.run(binary: binary, arguments: arguments, environment: environment)
        let stopped = lock.withLock { () -> Bool in
            current = nil
            return cancelled
        }
        if stopped || result.cancelled { throw CancellationError() }
        return result
    }

    func build(kind: OneOffKind, pair: Pair, binary: String,
               remotes: [String: [String: String]]) async throws -> TransferPlan {
        let environment = Rclone.environment(pair)
        let root = URL(fileURLWithPath: pair.localPath)
        var plan = TransferPlan(kind: kind, pair: pair)

        try LocalProbe.requireFolder(root)

        let check = try await run(binary, Rclone.planCheckArguments(pair), environment)
        let problems = Rclone.unexpectedCheckErrors(check.stderr)
        if let first = problems.first {
            let more = problems.count > 1 ? " (and \(problems.count - 1) more)" : ""
            throw PlanError("rclone couldn't compare everything, so there's no safe plan: \(first)\(more)")
        }
        let outcome = Rclone.parseCombined(check.stdout)
        if check.status != 0 && check.stdout.isEmpty {
            throw PlanError(Rclone.lastError(in: check.stderr) ?? "rclone exited with code \(check.status)")
        }
        if let unreadable = outcome.errors.first {
            throw PlanError("\(Fmt.files(outcome.errors.count)) couldn't be read, e.g. “\(unreadable)”.")
        }
        plan.localFiles = outcome.same + outcome.differ.count + outcome.missing.count
        plan.remoteFiles = outcome.same + outcome.differ.count + outcome.remoteOnly.count

        if kind == .syncOnce {
            if plan.localFiles == 0 && plan.remoteFiles > 0 {
                throw PlanError("“\(pair.name)” has no files, so a sync would empty the bucket. Bucketwatch won't do that. If the folder is on a disk that isn't connected, connect it and try again.")
            }
            // Don't take rclone's word for it: every file to remove must really be gone from disk.
            try LocalProbe.verifyMissing(outcome.remoteOnly, under: root)
        }

        if !outcome.remoteOnly.isEmpty {
            let listing = try await run(binary, Rclone.remoteSizesArguments(pair), environment)
            guard listing.status == 0 else {
                throw PlanError("Couldn't list the bucket: " + (Rclone.lastError(in: listing.stderr) ?? "rclone exited with code \(listing.status)"))
            }
            let sizes = Rclone.parseSizes(listing.stdout)
            plan.cloudOnly = outcome.remoteOnly.map { PlanEntry(path: $0, size: sizes[Rclone.sizeKey($0)]) }
        }
        if kind == .syncOnce {
            plan.toUpload = (outcome.missing + outcome.differ).map { PlanEntry(path: $0, size: LocalProbe.size(of: $0, under: root)) }
        }
        let order: (PlanEntry, PlanEntry) -> Bool = { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        plan.cloudOnly.sort(by: order)
        plan.toUpload.sort(by: order)

        if kind == .download { plan.freeBytes = LocalProbe.freeSpace(root) }
        if kind == .syncOnce && !plan.cloudOnly.isEmpty {
            plan.retention = await retention(pair, binary: binary, environment: environment, remotes: remotes)
        }
        plan.otherRclone = ProcessProbe.otherRclone()
        plan.created = Date()
        return plan
    }

    /// What the destination does with removed files, in one sentence.
    func retention(_ pair: Pair, binary: String, environment: [String: String],
                   remotes: [String: [String: String]]) async -> String {
        guard let location = Rclone.location(pair, remotes: remotes), location.store == "b2" else {
            return "Removed files are deleted from the remote. Whether they can be recovered depends on the service (trash or versioning)."
        }
        let generic = "On B2, removed files become hidden versions. How long they're kept depends on the bucket's lifecycle rules."
        guard let remote = location.remote, let bucket = location.components.first,
              let result = try? await run(binary, ["backend", "lifecycle", "\(remote):\(bucket)", "--log-level", "ERROR"], environment),
              result.status == 0,
              let rules = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]] else {
            return generic
        }
        // B2 applies a rule to every file whose name starts with its prefix.
        let folder = location.components.dropFirst().joined(separator: "/")
        let prefix = folder.isEmpty ? "" : folder + "/"
        let covering = rules.filter { prefix.hasPrefix($0["fileNamePrefix"] as? String ?? "") }
        if let days = covering.compactMap({ ($0["daysFromHidingToDeleting"] as? NSNumber)?.intValue }).min() {
            return "On B2, removed files stay as hidden versions for \(days) day\(days == 1 ? "" : "s"), then the bucket's lifecycle rule deletes them for good."
        }
        let partial = rules.contains { ($0["fileNamePrefix"] as? String ?? "").hasPrefix(prefix) && $0["daysFromHidingToDeleting"] is NSNumber }
        if partial {
            return "On B2, removed files become hidden versions. A lifecycle rule deletes some of them for good later; check the bucket's settings."
        }
        return "On B2, removed files become hidden versions you can still restore. The bucket has no lifecycle rule for them, so they keep using storage until you delete old versions."
    }
}

// MARK: - Local checks

enum LocalProbe {
    /// The folder must exist, be a directory and be listable. Otherwise every file would look missing.
    static func requireFolder(_ root: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw PlanError("The folder isn't available: \(root.path)")
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch {
            throw PlanError("Can't read the folder: \(error.localizedDescription)")
        }
    }

    enum Presence { case present, missing, unknown(String) }

    /// lstat with the reason it failed: only "no such file" proves a file is missing. Permission
    /// errors (an unreadable folder, a privacy prompt that was denied) prove nothing.
    static func presence(_ path: String, under root: URL) -> Presence {
        var unknown: String?
        for variant in variants(path) {
            let full = root.appendingPathComponent(variant).path
            var info = stat()
            if lstat(full, &info) == 0 { return .present }
            let code = errno
            if code != ENOENT && code != ENOTDIR { unknown = String(cString: strerror(code)) }
        }
        return unknown.map { .unknown($0) } ?? .missing
    }

    /// Spellings of an rclone path that could be on disk: as printed, in both Unicode forms, and with
    /// rclone's control-character escapes (␀–␟, ␡) turned back into the characters.
    static func variants(_ path: String) -> [String] {
        var decodedScalars = String.UnicodeScalarView()
        for scalar in path.unicodeScalars {
            switch scalar.value {
            case 0x2400...0x241F: decodedScalars.append(Unicode.Scalar(UInt8(scalar.value - 0x2400)))
            case 0x2421: decodedScalars.append(Unicode.Scalar(UInt8(0x7F)))
            default: decodedScalars.append(scalar)
            }
        }
        var seen = Set<[Unicode.Scalar]>()
        var result: [String] = []
        for candidate in [path, String(decodedScalars)] {
            for form in [candidate, candidate.precomposedStringWithCanonicalMapping, candidate.decomposedStringWithCanonicalMapping]
            where seen.insert(Array(form.unicodeScalars)).inserted {
                result.append(form)
            }
        }
        return result
    }

    /// Throws unless every path is provably absent from the folder.
    static func verifyMissing(_ paths: [String], under root: URL) throws {
        for path in paths {
            switch presence(path, under: root) {
            case .missing:
                continue
            case .present:
                throw PlanError("rclone reports “\(path)” as missing from the folder, but a file with that name is there (maybe with different upper/lowercase). Nothing will be removed until that's sorted out.")
            case .unknown(let reason):
                throw PlanError("Couldn't check “\(path)” in the folder (\(reason)). Nothing will be removed.")
            }
        }
    }

    /// Right before removing: the reviewed paths that are still absent. A file that came back since the
    /// review is kept in the bucket. Throws if the folder can't be checked.
    static func stillMissing(_ paths: [String], under root: URL) throws -> [String] {
        try requireFolder(root)
        var missing: [String] = []
        for path in paths {
            switch presence(path, under: root) {
            case .missing: missing.append(path)
            case .present: continue
            case .unknown(let reason):
                throw PlanError("Couldn't check “\(path)” in the folder (\(reason)). Nothing was removed.")
            }
        }
        return missing
    }

    static func size(of path: String, under root: URL) -> Int64? {
        var info = stat()
        guard lstat(root.appendingPathComponent(path).path, &info) == 0 else { return nil }
        return Int64(info.st_size)
    }

    static func freeSpace(_ root: URL) -> Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// True only when the folder could be read completely and holds no files (Finder litter aside).
    /// Syncing such a folder would empty the bucket.
    static func hasNoFiles(_ root: URL) -> Bool {
        var failed = false
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [],
            errorHandler: { _, _ in failed = true; return false }) else { return false }
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { return false }
        }
        return !failed
    }
}

// MARK: - File lists

enum PlanFiles {
    /// Writes one path per line for `--files-from-raw`, which reads lines verbatim (no comments, no trimming).
    static func write(_ paths: [String]) throws -> URL {
        if let bad = paths.first(where: { $0.unicodeScalars.contains { $0 == "\n" || $0 == "\r" } }) {
            throw PlanError("“\(bad)” has a line break in its name, so it can't be passed to rclone safely.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Bucketwatch", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + ".txt")
        try Data((paths.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Other rclone processes

enum ProcessProbe {
    /// Command lines of running rclone processes that aren't Bucketwatch's own children, e.g. a script
    /// uploading to the same bucket.
    static func otherRclone() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "ppid=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let me = ProcessInfo.processInfo.processIdentifier
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard fields.count == 2, let ppid = Int32(fields[0]), ppid != me else { return nil }
            let args = fields[1].trimmingCharacters(in: .whitespaces)
            guard let executable = args.split(separator: " ").first,
                  (String(executable) as NSString).lastPathComponent == "rclone" else { return nil }
            return args.count > 140 ? String(args.prefix(140)) + "…" : args
        }
    }
}

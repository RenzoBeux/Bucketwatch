import Foundation

struct RcloneResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var cancelled: Bool
}

/// One rclone invocation. Collects stdout, streams stderr line by line, and can be cancelled.
final class RcloneCall: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var out = Data()
    private var errAll = Data()
    private var errLine = Data()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
        if process.isRunning { process.terminate() }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func run(binary: String, arguments: [String], environment: [String: String] = [:],
             onStderrLine: ((String) -> Void)? = nil) async -> RcloneResult {
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.withLock { self.out.append(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.consumeStderr(data, onStderrLine, flush: false)
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { [weak self] proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                guard let self else {
                    continuation.resume(returning: RcloneResult(status: proc.terminationStatus, stdout: "", stderr: "", cancelled: false))
                    return
                }
                let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                self.lock.withLock { self.out.append(restOut) }
                self.consumeStderr(restErr, onStderrLine, flush: true)
                let result = self.lock.withLock {
                    RcloneResult(status: proc.terminationStatus,
                                 stdout: String(decoding: self.out, as: UTF8.self),
                                 stderr: String(decoding: self.errAll, as: UTF8.self),
                                 cancelled: self.cancelled)
                }
                continuation.resume(returning: result)
            }
            // A call cancelled before it started never starts.
            if isCancelled {
                process.terminationHandler = nil
                continuation.resume(returning: RcloneResult(status: -1, stdout: "", stderr: "", cancelled: true))
                return
            }
            do {
                try process.run()
                // Cancelled between the check above and the launch: stop it now.
                if isCancelled { process.terminate() }
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: RcloneResult(status: -1, stdout: "",
                                                            stderr: error.localizedDescription, cancelled: false))
            }
        }
    }

    private func consumeStderr(_ data: Data, _ onLine: ((String) -> Void)?, flush: Bool) {
        var lines: [String] = []
        lock.withLock {
            errAll.append(data)
            if errAll.count > 400_000 { errAll.removeFirst(errAll.count - 200_000) }
            errLine.append(data)
            while let newline = errLine.firstIndex(of: 0x0A) {
                lines.append(String(decoding: errLine[errLine.startIndex..<newline], as: UTF8.self))
                errLine.removeSubrange(errLine.startIndex...newline)
            }
            if flush, !errLine.isEmpty {
                lines.append(String(decoding: errLine, as: UTF8.self))
                errLine.removeAll()
            }
        }
        if let onLine { lines.forEach(onLine) }
    }
}

enum Rclone {
    static let candidates = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]

    static func locate(custom: String) -> String? {
        let custom = custom.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return FileManager.default.isExecutableFile(atPath: custom) ? custom : nil }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Name of the on-the-fly remote that B2 pairs use (configured through environment variables,
    /// so the application key never touches rclone.conf or the process arguments).
    static func remoteName(_ pair: Pair) -> String {
        "bw" + pair.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
    }

    private static func cleanPath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    static func target(_ pair: Pair) -> String {
        let path = cleanPath(pair.destination.path)
        switch pair.destination.kind {
        case .b2:
            let bucket = pair.destination.bucket.trimmingCharacters(in: .whitespaces)
            return "\(remoteName(pair)):\(bucket)" + (path.isEmpty ? "" : "/\(path)")
        case .rcloneRemote:
            return "\(pair.destination.remote):\(path)"
        }
    }

    static func displayTarget(_ pair: Pair) -> String {
        let path = cleanPath(pair.destination.path)
        switch pair.destination.kind {
        case .b2:
            let bucket = pair.destination.bucket.trimmingCharacters(in: .whitespaces)
            if bucket.isEmpty { return "—" }
            return "b2://\(bucket)" + (path.isEmpty ? "" : "/\(path)")
        case .rcloneRemote:
            if pair.destination.remote.isEmpty { return "—" }
            return "\(pair.destination.remote):\(path)"
        }
    }

    static func environment(_ pair: Pair) -> [String: String] {
        guard pair.destination.kind == .b2 else { return [:] }
        let name = remoteName(pair).uppercased()
        return [
            "RCLONE_CONFIG_\(name)_TYPE": "b2",
            "RCLONE_CONFIG_\(name)_ACCOUNT": pair.destination.keyID.trimmingCharacters(in: .whitespaces),
            "RCLONE_CONFIG_\(name)_KEY": Keychain.get(pair.id.uuidString) ?? "",
        ]
    }

    static func filterArgs(_ pair: Pair) -> [String] {
        pair.excludes
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .flatMap { ["--exclude", $0] }
    }

    /// Compares both ways, so Copy pairs also learn which files exist only in the bucket.
    static func checkArguments(_ pair: Pair) -> [String] {
        ["check", pair.localPath, target(pair), "--size-only", "--combined", "-",
         "--fast-list", "--log-level", "ERROR"] + filterArgs(pair)
    }

    /// The check behind a one-off plan: JSON log lines, so every error can be classified.
    static func planCheckArguments(_ pair: Pair) -> [String] {
        checkArguments(pair) + ["--use-json-log"]
    }

    private static let progressArgs = ["--use-json-log", "--log-level", "NOTICE",
                                       "--stats", "2s", "--stats-log-level", "NOTICE"]

    /// Folder → bucket. `deleting` picks `sync` (mirror) over `copy` (add and update only).
    static func uploadArguments(_ pair: Pair, deleting: Bool) -> [String] {
        var args = [deleting ? "sync" : "copy", pair.localPath, target(pair),
                    "--fast-list", "--check-first", "--transfers", "4"] + progressArgs
        if pair.destination.kind == .b2 { args += ["--b2-chunk-size", "96M"] }
        return args + filterArgs(pair)
    }

    /// Bucket → folder, only the files named in `list`. Never overwrites or deletes anything in the folder.
    static func downloadArguments(_ pair: Pair, list: String) -> [String] {
        ["copy", target(pair), pair.localPath, "--files-from-raw", list, "--ignore-existing",
         "--check-first", "--transfers", "4"] + progressArgs
    }

    /// Removes exactly the files named in `list` from the bucket. `--max-delete` makes rclone stop
    /// with an error rather than ever delete more than that many files.
    static func deleteArguments(_ pair: Pair, list: String, count: Int) -> [String] {
        ["delete", target(pair), "--files-from-raw", list, "--max-delete", String(count),
         "--use-json-log", "--log-level", "NOTICE", "--stats", "1s", "--stats-log-level", "NOTICE"]
    }

    /// Every file in the bucket with its size in bytes, one `size<TAB>path` per line.
    static func remoteSizesArguments(_ pair: Pair) -> [String] {
        ["lsf", target(pair), "-R", "--files-only", "--format", "sp", "--separator", "\t",
         "--fast-list", "--log-level", "ERROR"] + filterArgs(pair)
    }

    // MARK: Overlap detection

    /// Where a pair's destination really lives, after following rclone aliases.
    /// B2 bucket names are globally unique, so every B2 location shares the "b2" store.
    struct Location: Equatable {
        var store: String
        var components: [String]
        /// For B2: the rclone remote that talks to it (components then start with the bucket).
        var remote: String? = nil
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func location(_ pair: Pair, remotes: [String: [String: String]]) -> Location? {
        switch pair.destination.kind {
        case .b2:
            let bucket = pair.destination.bucket.trimmingCharacters(in: .whitespaces)
            if bucket.isEmpty { return nil }
            return Location(store: "b2", components: [bucket] + components(pair.destination.path),
                            remote: remoteName(pair))
        case .rcloneRemote:
            if pair.destination.remote.isEmpty { return nil }
            return resolve(pair.destination.remote, components(pair.destination.path), remotes, depth: 0)
        }
    }

    private static func resolve(_ name: String, _ path: [String], _ remotes: [String: [String: String]],
                                depth: Int) -> Location {
        guard depth < 8, let conf = remotes[name] else { return Location(store: "remote:\(name)", components: path) }
        switch conf["type"] {
        case "alias":
            guard let target = conf["remote"] else { break }
            if let colon = target.firstIndex(of: ":"), !target.hasPrefix("/") {
                let next = String(target[..<colon])
                let rest = components(String(target[target.index(after: colon)...]))
                return resolve(next, rest + path, remotes, depth: depth + 1)
            }
            return Location(store: "local", components: components(target) + path)
        case "b2":
            return Location(store: "b2", components: path, remote: name)
        default:
            break
        }
        return Location(store: "remote:\(name)", components: path)
    }

    /// True when one destination is the same as, or nested inside, the other.
    static func overlaps(_ a: Location, _ b: Location) -> Bool {
        a.store == b.store && (a.components.starts(with: b.components) || b.components.starts(with: a.components))
    }

    static func remoteConfig(_ binary: String) -> [String: [String: String]] {
        guard let out = Rclone.quick(binary, ["config", "dump"]),
              let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: [String: Any]] else { return [:] }
        return obj.mapValues { conf in conf.compactMapValues { $0 as? String } }
    }

    // MARK: Parsing

    struct CheckOutcome {
        var missing: [String] = []     // "+" only in the local folder
        var differ: [String] = []      // "*" in both, but different
        var remoteOnly: [String] = []  // "-" only in the bucket
        var errors: [String] = []      // "!" could not be read
        var same = 0                   // "=" identical on both sides
    }

    static func parseCombined(_ output: String) -> CheckOutcome {
        var outcome = CheckOutcome()
        // Split on "\n" scalars, not Characters: "\r\n" is one Character in Swift. Paths keep their
        // exact scalars because they are handed back to rclone (never Unicode-normalize them).
        for line in output.unicodeScalars.split(separator: "\n") where line.count > 2 && line.dropFirst().first == " " {
            let path = String(String.UnicodeScalarView(line.dropFirst(2)))
            switch line.first {
            case "=": outcome.same += 1
            case "+": outcome.missing.append(path)
            case "*": outcome.differ.append(path)
            case "-": outcome.remoteOnly.append(path)
            case "!": outcome.errors.append(path)
            default: break
            }
        }
        return outcome
    }

    struct Stats {
        var bytes: Int64
        var totalBytes: Int64
        var speed: Double
        var eta: Double?
        var deletes: Int = 0
    }

    /// Parses one `--use-json-log` line into progress stats and/or an error message.
    static func parseLogLine(_ line: String) -> (stats: Stats?, error: String?) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        var stats: Stats?
        if let s = obj["stats"] as? [String: Any] {
            stats = Stats(bytes: (s["bytes"] as? NSNumber)?.int64Value ?? 0,
                          totalBytes: (s["totalBytes"] as? NSNumber)?.int64Value ?? 0,
                          speed: (s["speed"] as? NSNumber)?.doubleValue ?? 0,
                          eta: (s["eta"] as? NSNumber)?.doubleValue,
                          deletes: (s["deletes"] as? NSNumber)?.intValue ?? 0)
        }
        let level = obj["level"] as? String
        let error = (level == "error" || level == "critical") ? (obj["msg"] as? String) : nil
        return (stats, error)
    }

    /// Problems in a `planCheckArguments` log other than the differences themselves.
    /// "file not in …" and "sizes differ" are the differences; anything else at error level (a folder
    /// that couldn't be listed, a network failure) means the comparison is incomplete, and a file
    /// that wasn't seen would look deleted. Unparseable lines count as problems too.
    static func unexpectedCheckErrors(_ stderr: String) -> [String] {
        var problems: [String] = []
        for line in stderr.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                problems.append(text)
                continue
            }
            let level = obj["level"] as? String ?? ""
            guard level == "error" || level == "critical" || level == "emergency" || level == "alert" else { continue }
            let msg = obj["msg"] as? String ?? ""
            if msg.hasPrefix("file not in ") || msg == "sizes differ" { continue }
            if msg.range(of: #"^[0-9]+ differences found$"#, options: .regularExpression) != nil { continue }
            let object = (obj["object"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            problems.append(object.map { "\($0): \(msg)" } ?? msg)
        }
        return problems
    }

    /// Size lookups key on NFC so a name rclone printed in another Unicode form still matches.
    static func sizeKey(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }

    /// Parses `remoteSizesArguments` output.
    static func parseSizes(_ output: String) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for line in output.unicodeScalars.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"),
                  let size = Int64(String(String.UnicodeScalarView(line[line.startIndex..<tab]))) else { continue }
            let path = String(String.UnicodeScalarView(line[line.index(after: tab)...]))
            sizes[sizeKey(path)] = size
        }
        return sizes
    }

    /// Last meaningful ERROR line from plain (non-JSON) rclone stderr.
    static func lastError(in stderr: String) -> String? {
        let lines = stderr.split(separator: "\n").map(String.init)
        guard let line = lines.last(where: { $0.contains("ERROR") || $0.contains("CRITICAL") || $0.contains("Failed") })
                ?? lines.last else { return nil }
        if let range = line.range(of: "ERROR : ") ?? line.range(of: "CRITICAL: ") {
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Small synchronous helper for quick commands (`version`, `listremotes`).
    static func quick(_ binary: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

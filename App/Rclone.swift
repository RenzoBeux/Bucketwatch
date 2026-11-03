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
            do {
                try process.run()
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

    static func checkArguments(_ pair: Pair) -> [String] {
        var args = ["check", pair.localPath, target(pair), "--size-only", "--combined", "-",
                    "--fast-list", "--log-level", "ERROR"]
        if pair.mode == .copy { args.append("--one-way") }
        return args + filterArgs(pair)
    }

    static func transferArguments(_ pair: Pair) -> [String] {
        var args = [pair.mode == .copy ? "copy" : "sync", pair.localPath, target(pair),
                    "--fast-list", "--check-first", "--transfers", "4",
                    "--use-json-log", "--log-level", "NOTICE",
                    "--stats", "2s", "--stats-log-level", "NOTICE"]
        if pair.destination.kind == .b2 { args += ["--b2-chunk-size", "96M"] }
        return args + filterArgs(pair)
    }

    // MARK: Overlap detection

    /// Where a pair's destination really lives, after following rclone aliases.
    /// B2 bucket names are globally unique, so every B2 location shares the "b2" store.
    struct Location: Equatable {
        var store: String
        var components: [String]
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func location(_ pair: Pair, remotes: [String: [String: String]]) -> Location? {
        switch pair.destination.kind {
        case .b2:
            let bucket = pair.destination.bucket.trimmingCharacters(in: .whitespaces)
            if bucket.isEmpty { return nil }
            return Location(store: "b2", components: [bucket] + components(pair.destination.path))
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
            return Location(store: "b2", components: path)
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
    }

    static func parseCombined(_ output: String) -> CheckOutcome {
        var outcome = CheckOutcome()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) where line.count > 2 {
            let path = String(line.dropFirst(2))
            switch line.first {
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
                          eta: (s["eta"] as? NSNumber)?.doubleValue)
        }
        let level = obj["level"] as? String
        let error = (level == "error" || level == "critical") ? (obj["msg"] as? String) : nil
        return (stats, error)
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

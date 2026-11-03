import AppKit
import Combine
import IOKit.ps
import Network
import ServiceManagement
import SwiftUI
import WidgetKit

enum SidebarItem: Hashable {
    case pair(UUID)
    case general
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var config: Config {
        didSet {
            guard config != oldValue else { return }
            ConfigStore.save(config)
            reconcile(old: oldValue)
        }
    }
    @Published private(set) var statuses: [UUID: PairStatus] = [:]
    @Published var selection: SidebarItem?

    private var calls: [UUID: RcloneCall] = [:]
    private var timer: Timer?
    private var lastWidgetReload = Date.distantPast
    private let pathMonitor = NWPathMonitor()
    private var networkIsExpensive = false
    private var started = false

    private init() {
        config = ConfigStore.load()
        if let snapshot = SharedStore.load() {
            for var status in snapshot.pairs where config.pairs.contains(where: { $0.id == status.id }) {
                if status.state == .running || status.state == .checking { status.state = .unknown }
                status.progress = nil
                statuses[status.id] = status
            }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in self?.networkIsExpensive = expensive }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                self?.tick()
            }
        }
        publish(force: true)
        Task {
            try? await Task.sleep(for: .seconds(2))
            tick()
        }
    }

    var rcloneBinary: String? { Rclone.locate(custom: config.rclonePath) }

    // MARK: Status helpers

    func status(for id: UUID) -> PairStatus {
        let name = config.pairs.first { $0.id == id }?.name ?? ""
        var status = statuses[id] ?? PairStatus(id: id, name: name)
        status.name = name
        return status
    }

    var snapshot: Snapshot {
        Snapshot(updated: .now, pairs: config.pairs.map { status(for: $0.id) })
    }

    var overallState: PairState { snapshot.overall }

    func isBusy(_ id: UUID) -> Bool { calls[id] != nil }

    private func update(_ id: UUID, _ change: (inout PairStatus) -> Void) {
        var status = status(for: id)
        let before = status.state
        change(&status)
        statuses[id] = status
        publish(force: status.state != before)
    }

    private func publish(force: Bool = false) {
        SharedStore.save(snapshot)
        if force || Date().timeIntervalSince(lastWidgetReload) > 60 {
            WidgetCenter.shared.reloadAllTimelines()
            lastWidgetReload = .now
        }
    }

    /// When the definition of a pair changes, its last comparison no longer means anything.
    private func reconcile(old: Config) {
        let ids = Set(config.pairs.map(\.id))
        for id in statuses.keys where !ids.contains(id) {
            calls[id]?.cancel()
            statuses[id] = nil
        }
        for pair in config.pairs {
            guard let previous = old.pairs.first(where: { $0.id == pair.id }) else { continue }
            if previous.comparisonKey != pair.comparisonKey, !isBusy(pair.id) {
                update(pair.id) { $0.state = .unknown; $0.lastChecked = nil; $0.message = nil }
            }
        }
        publish(force: true)
    }

    // MARK: Pairs

    func binding(for id: UUID) -> Binding<Pair>? {
        guard config.pairs.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.config.pairs.first { $0.id == id } ?? Pair(id: id) },
            set: { newValue in
                if let i = self.config.pairs.firstIndex(where: { $0.id == id }) { self.config.pairs[i] = newValue }
            })
    }

    func addPair() {
        let pair = Pair()
        config.pairs.append(pair)
        selection = .pair(pair.id)
    }

    func removePair(_ id: UUID) {
        calls[id]?.cancel()
        Keychain.set("", for: id.uuidString)
        config.pairs.removeAll { $0.id == id }
        if selection == .pair(id) { selection = config.pairs.first.map { .pair($0.id) } ?? .general }
    }

    // MARK: Overlap

    private var remoteConfig: [String: [String: String]] = [:]
    private var remoteConfigLoaded = Date.distantPast

    func refreshRemoteConfig(force: Bool = false) {
        guard force || Date().timeIntervalSince(remoteConfigLoaded) > 300, let bin = rcloneBinary else { return }
        remoteConfig = Rclone.remoteConfig(bin)
        remoteConfigLoaded = .now
    }

    /// Another pair whose destination is the same as, contains, or is inside this pair's destination.
    /// Such pairs would see each other's files (and a Sync would delete them), so they never run.
    func overlappingPair(for pair: Pair) -> Pair? {
        refreshRemoteConfig()
        guard let location = Rclone.location(pair, remotes: remoteConfig) else { return nil }
        return config.pairs.first { other in
            guard other.id != pair.id, let otherLocation = Rclone.location(other, remotes: remoteConfig) else { return false }
            return Rclone.overlaps(location, otherLocation)
        }
    }

    private func validate(_ pair: Pair) -> String? {
        if rcloneBinary == nil { return "rclone not found — install it with Homebrew (brew install rclone)" }
        if let other = overlappingPair(for: pair) { return "Destination overlaps with “\(other.name)”" }
        if pair.localPath.isEmpty { return "Choose a local folder" }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: pair.localPath, isDirectory: &isDir) || !isDir.boolValue {
            return "Folder not available"
        }
        switch pair.destination.kind {
        case .b2:
            if pair.destination.bucket.isEmpty || pair.destination.keyID.isEmpty { return "Set the bucket and key ID" }
            if (Keychain.get(pair.id.uuidString) ?? "").isEmpty { return "Missing application key" }
        case .rcloneRemote:
            if pair.destination.remote.isEmpty { return "Choose an rclone remote" }
        }
        return nil
    }

    // MARK: Check

    func checkAll() {
        for pair in config.pairs where pair.enabled { check(pair.id) }
    }

    func check(_ id: UUID) {
        guard let pair = config.pairs.first(where: { $0.id == id }), !isBusy(id) else { return }
        if let problem = validate(pair) {
            update(id) { $0.state = .error; $0.message = problem; $0.lastChecked = .now }
            return
        }
        let call = RcloneCall()
        calls[id] = call
        update(id) { $0.state = .checking }

        Task {
            let result = await call.run(binary: rcloneBinary!, arguments: Rclone.checkArguments(pair),
                                        environment: Rclone.environment(pair))
            if calls[id] === call { calls[id] = nil }
            guard config.pairs.contains(where: { $0.id == id }) else { return }
            if result.cancelled {
                // Stopped by the user, or replaced by an upload that now owns the status.
                if !isBusy(id) { update(id) { $0.state = .unknown } }
                return
            }
            applyCheck(pair, result)
        }
    }

    private func applyCheck(_ pair: Pair, _ result: RcloneResult) {
        let outcome = Rclone.parseCombined(result.stdout)
        let pendingPaths = outcome.missing + outcome.differ
        let remoteOnly = pair.mode == .sync ? outcome.remoteOnly.count : 0
        let root = URL(fileURLWithPath: pair.localPath)
        let pendingBytes = pendingPaths.reduce(Int64(0)) { total, path in
            let size = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.size]) as? NSNumber
            return total + (size?.int64Value ?? 0)
        }
        let comparedSomething = !result.stdout.isEmpty

        update(pair.id) { s in
            s.progress = nil
            s.lastChecked = .now
            s.pendingFiles = pendingPaths.count
            s.pendingBytes = pendingBytes
            s.remoteOnlyFiles = remoteOnly
            if !outcome.errors.isEmpty {
                s.state = .error
                s.message = "\(Fmt.files(outcome.errors.count)) could not be read"
            } else if result.status != 0 && !comparedSomething {
                s.state = .error
                s.message = Rclone.lastError(in: result.stderr) ?? "rclone exited with code \(result.status)"
            } else if !pendingPaths.isEmpty || remoteOnly > 0 {
                s.state = .pending
                s.message = nil
            } else {
                s.state = .inSync
                s.message = nil
            }
        }
    }

    // MARK: Transfer

    func backUp(_ id: UUID) {
        guard let pair = config.pairs.first(where: { $0.id == id }) else { return }
        if isBusy(id) {
            // A check is running: replace it with the upload.
            guard status(for: id).state == .checking else { return }
            calls[id]?.cancel()
            calls[id] = nil
        }
        if let problem = validate(pair) {
            update(id) { $0.state = .error; $0.message = problem }
            return
        }
        let call = RcloneCall()
        calls[id] = call
        update(id) { s in
            s.state = .running; s.message = nil
            s.progress = nil; s.bytesDone = nil; s.bytesTotal = nil; s.speed = nil; s.eta = nil
        }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Bucketwatch is uploading \(pair.name)")
        let lastError = LastValue()

        Task {
            let result = await call.run(
                binary: rcloneBinary!, arguments: Rclone.transferArguments(pair),
                environment: Rclone.environment(pair),
                onStderrLine: { line in
                    let parsed = Rclone.parseLogLine(line)
                    if let message = parsed.error { lastError.set(message) }
                    guard let stats = parsed.stats else { return }
                    Task { @MainActor in self.applyStats(id, stats) }
                })
            ProcessInfo.processInfo.endActivity(activity)
            if calls[id] === call { calls[id] = nil }
            guard config.pairs.contains(where: { $0.id == id }) else { return }

            update(id) { s in
                s.progress = nil; s.speed = nil; s.eta = nil
                if result.cancelled {
                    s.state = .pending
                    s.message = "Upload stopped"
                } else if result.status == 0 {
                    s.lastRun = .now
                    s.message = nil
                } else {
                    s.state = .error
                    s.message = lastError.get() ?? Rclone.lastError(in: result.stderr)
                        ?? "rclone exited with code \(result.status)"
                }
            }
            if !result.cancelled && result.status == 0 { check(id) }
        }
    }

    private func applyStats(_ id: UUID, _ stats: Rclone.Stats) {
        guard isBusy(id), status(for: id).state == .running else { return }
        var status = status(for: id)
        status.bytesDone = stats.bytes
        status.bytesTotal = stats.totalBytes
        status.progress = stats.totalBytes > 0 ? min(1, Double(stats.bytes) / Double(stats.totalBytes)) : nil
        status.speed = stats.speed
        status.eta = stats.eta
        statuses[id] = status
        publish()
    }

    func stop(_ id: UUID) { calls[id]?.cancel() }

    // MARK: Scheduler

    private var onACPower: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() else { return true }
        return (type as String) == "AC Power"
    }

    /// Why a scheduled upload can't start right now, or nil when it can.
    func scheduleBlocker(_ pair: Pair) -> String? {
        if pair.schedule.onlyOnPower && !onACPower { return "Waiting for power adapter" }
        if pair.schedule.skipExpensiveNetwork && networkIsExpensive { return "Waiting for a non-metered network" }
        return nil
    }

    private func uploadIsDue(_ pair: Pair, _ status: PairStatus, now: Date) -> Bool {
        switch pair.schedule.kind {
        case .manual:
            return false
        case .interval:
            guard let last = status.lastRun else { return true }
            return now.timeIntervalSince(last) >= Double(pair.schedule.everyHours) * 3600
        case .daily:
            let calendar = Calendar.current
            guard let slot = calendar.date(bySettingHour: pair.schedule.dailyHour, minute: pair.schedule.dailyMinute,
                                           second: 0, of: now), now >= slot else { return false }
            return (status.lastRun ?? .distantPast) < slot
        }
    }

    func tick() {
        let now = Date()
        let anyUploading = config.pairs.contains { status(for: $0.id).state == .running }
        for pair in config.pairs where pair.enabled && !isBusy(pair.id) {
            let status = status(for: pair.id)
            let checkAge = status.lastChecked.map { now.timeIntervalSince($0) } ?? .infinity

            if uploadIsDue(pair, status, now: now) {
                if checkAge > 15 * 60 { check(pair.id); continue }
                if status.state == .pending {
                    if let blocker = scheduleBlocker(pair) {
                        if status.message != blocker { update(pair.id) { $0.message = blocker } }
                    } else if !anyUploading {
                        backUp(pair.id)
                    }
                    continue
                }
            }
            if checkAge >= Double(pair.checkEveryMinutes) * 60 { check(pair.id) }
        }
    }

    // MARK: Misc

    func listRemotes() -> [String] {
        refreshRemoteConfig(force: true)
        guard let bin = rcloneBinary, let out = Rclone.quick(bin, ["listremotes"]) else { return [] }
        return out.split(separator: "\n").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ": ")) }
            .filter { !$0.isEmpty }
    }

    func rcloneVersion() -> String? {
        guard let bin = rcloneBinary, let out = Rclone.quick(bin, ["version"]) else { return nil }
        return out.split(separator: "\n").first.map(String.init)
    }

    func testConnection(_ pair: Pair) async -> String {
        if rcloneBinary == nil { return "rclone not found" }
        let result = await RcloneCall().run(
            binary: rcloneBinary!,
            arguments: ["lsf", Rclone.target(pair), "--max-depth", "1", "--fast-list", "--log-level", "ERROR"],
            environment: Rclone.environment(pair))
        if result.status == 0 {
            let count = result.stdout.split(separator: "\n").count
            return count == 0 ? "Connected ✓ (empty)" : "Connected ✓ (\(count) items at the top level)"
        }
        if result.stderr.contains("directory not found") {
            return "Connected ✓ — the folder will be created on the first upload"
        }
        return Rclone.lastError(in: result.stderr) ?? "Failed (code \(result.status))"
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }

    func handle(_ url: URL) {
        guard url.scheme == "bucketwatch" else { return }
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "id" }?.value.flatMap(UUID.init(uuidString:))
        switch url.host {
        case "run": if let id { backUp(id) }
        case "check": if let id { check(id) } else { checkAll() }
        default: SettingsWindow.show(select: id)
        }
    }
}

/// Thread-safe holder for the last error line reported by a running rclone.
final class LastValue: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ v: String) { lock.withLock { value = v } }
    func get() -> String? { lock.withLock { value } }
}

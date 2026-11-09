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
                AppModel.clearProgress(&status)
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

    private static func clearProgress(_ status: inout PairStatus) {
        status.progress = nil; status.bytesDone = nil; status.bytesTotal = nil
        status.speed = nil; status.eta = nil
        status.activity = nil; status.itemsDone = nil; status.itemsTotal = nil
    }

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
                update(pair.id) { s in
                    s.state = .unknown; s.lastChecked = nil; s.message = nil; s.cloudOnlyFiles = nil
                    s.oldHiddenFiles = nil; s.oldHiddenBytes = nil; s.hiddenScanned = nil
                }
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

    /// rclone's remotes, for resolving aliases (refreshed at most every 5 minutes).
    func remotesForPlanning() -> [String: [String: String]] {
        refreshRemoteConfig()
        return remoteConfig
    }

    /// Why this pair can't be checked or transferred right now, or nil.
    func validate(_ pair: Pair) -> String? {
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
        update(id) { $0.state = .checking; AppModel.clearProgress(&$0) }

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
            // Copy pairs keep cloud-only files on purpose: informational, never "pending".
            s.cloudOnlyFiles = pair.mode == .copy ? outcome.remoteOnly.count : nil
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
        if pair.mode == .sync && LocalProbe.hasNoFiles(URL(fileURLWithPath: pair.localPath)) {
            update(id) {
                $0.state = .error
                $0.message = "The folder is empty, so it wasn't synced (that would empty the bucket)"
            }
            return
        }
        let call = RcloneCall()
        calls[id] = call
        update(id) { s in
            s.state = .running; s.message = nil
            AppModel.clearProgress(&s)
            s.activity = .upload
        }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Bucketwatch is uploading \(pair.name)")
        let lastError = LastValue()

        Task {
            let result = await call.run(
                binary: rcloneBinary!, arguments: Rclone.uploadArguments(pair, deleting: pair.mode == .sync),
                environment: Rclone.environment(pair),
                onStderrLine: { line in
                    let parsed = Rclone.parseLogLine(line)
                    if let message = parsed.error { lastError.set(message) }
                    guard let stats = parsed.stats else { return }
                    Task { @MainActor in self.applyStats(id, stats, for: call) }
                })
            ProcessInfo.processInfo.endActivity(activity)
            if calls[id] === call { calls[id] = nil }
            guard config.pairs.contains(where: { $0.id == id }) else { return }

            update(id) { s in
                AppModel.clearProgress(&s)
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

    private func applyStats(_ id: UUID, _ stats: Rclone.Stats, for call: RcloneCall) {
        // Ignore late stats from a phase that has already finished.
        guard calls[id] === call, status(for: id).state == .running else { return }
        var status = status(for: id)
        if status.activity == .delete {
            let total = status.itemsTotal ?? 0
            status.itemsDone = min(stats.deletes, total)
            status.progress = total > 0 ? min(1, Double(stats.deletes) / Double(total)) : nil
        } else {
            status.bytesDone = stats.bytes
            status.bytesTotal = stats.totalBytes
            status.progress = stats.totalBytes > 0 ? min(1, Double(stats.bytes) / Double(stats.totalBytes)) : nil
            status.speed = stats.speed
            status.eta = stats.eta
        }
        statuses[id] = status
        publish()
    }

    func stop(_ id: UUID) { calls[id]?.cancel() }

    // MARK: One-off download / sync

    /// Why a reviewed plan can't start right now, or nil.
    func planBlocker(_ plan: TransferPlan, acknowledged: Bool) -> String? {
        guard let pair = config.pairs.first(where: { $0.id == plan.pair.id }) else {
            return "This folder is no longer in Bucketwatch."
        }
        if pair.comparisonKey != plan.pair.comparisonKey {
            return "The folder's settings changed since this preview. Refresh it."
        }
        if isBusy(pair.id) { return "“\(pair.name)” is busy. Wait until it finishes." }
        if Date().timeIntervalSince(plan.created) > 30 * 60 {
            return "This preview is more than 30 minutes old. Refresh it."
        }
        if plan.removesMostOfBucket && !acknowledged {
            return "Confirm that you want to remove most of the bucket."
        }
        if let problem = validate(pair) { return problem }
        if plan.kind == .download {
            var now = plan
            now.freeBytes = LocalProbe.freeSpace(URL(fileURLWithPath: pair.localPath))
            if now.spaceShortfall != nil { return "Not enough free space on the folder's disk." }
        }
        return nil
    }

    /// Starts a plan the user reviewed and confirmed. Returns why it couldn't start, or nil.
    func start(_ plan: TransferPlan, acknowledged: Bool) -> String? {
        if let blocker = planBlocker(plan, acknowledged: acknowledged) { return blocker }
        guard let pair = config.pairs.first(where: { $0.id == plan.pair.id }), let binary = rcloneBinary else {
            return "rclone not found"
        }
        switch plan.kind {
        case .download: return startDownload(plan, pair: pair, binary: binary)
        case .syncOnce: startSyncOnce(plan, pair: pair, binary: binary); return nil
        }
    }

    private func startDownload(_ plan: TransferPlan, pair: Pair, binary: String) -> String? {
        let id = pair.id
        let list: URL
        do { list = try PlanFiles.write(plan.cloudOnly.map(\.path)) } catch { return error.localizedDescription }
        let call = RcloneCall()
        calls[id] = call
        update(id) { s in
            s.state = .running; s.message = nil
            AppModel.clearProgress(&s)
            s.activity = .download
        }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Bucketwatch is downloading \(pair.name)")
        Task {
            let outcome = await runTransfer(call, id: id, binary: binary,
                                            arguments: Rclone.downloadArguments(pair, list: list.path),
                                            environment: Rclone.environment(pair))
            ProcessInfo.processInfo.endActivity(activity)
            try? FileManager.default.removeItem(at: list)
            finishOneOff(id, call, error: outcome.ok || outcome.cancelled ? nil : "Download failed: \(outcome.error)")
        }
        return nil
    }

    /// Upload first (copy, never deletes); only if that fully succeeds, remove the reviewed files that are
    /// still missing from the folder, and nothing else.
    private func startSyncOnce(_ plan: TransferPlan, pair: Pair, binary: String) {
        let id = pair.id
        let environment = Rclone.environment(pair)
        let root = URL(fileURLWithPath: pair.localPath)
        // Holding a call for the whole run keeps checks and scheduled uploads away from this pair.
        let upload = RcloneCall()
        calls[id] = upload
        update(id) { s in
            s.state = .running; s.message = nil
            AppModel.clearProgress(&s)
            s.activity = .upload
        }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Bucketwatch is syncing \(pair.name)")
        Task {
            defer { ProcessInfo.processInfo.endActivity(activity) }

            if !plan.toUpload.isEmpty {
                let outcome = await runTransfer(upload, id: id, binary: binary,
                                                arguments: Rclone.uploadArguments(pair, deleting: false),
                                                environment: environment)
                if !outcome.ok {
                    finishOneOff(id, upload, error: outcome.cancelled ? nil
                                 : "Upload failed, so nothing was removed from the bucket: \(outcome.error)")
                    return
                }
                update(id) { $0.lastRun = .now }
            }
            // Stopped, or removed from Bucketwatch, before the removal started.
            guard !upload.isCancelled, calls[id] === upload,
                  let current = config.pairs.first(where: { $0.id == id }) else {
                finishOneOff(id, upload, error: nil)
                return
            }
            if current.comparisonKey != plan.pair.comparisonKey {
                finishOneOff(id, upload, error: "Settings changed during the sync, so nothing was removed from the bucket")
                return
            }
            if let problem = validate(current) {
                finishOneOff(id, upload, error: "\(problem). Nothing was removed from the bucket")
                return
            }
            let toRemove: [String]
            let list: URL
            do {
                // A file restored since the review stays in the bucket.
                toRemove = try LocalProbe.stillMissing(plan.cloudOnly.map(\.path), under: root)
                if toRemove.isEmpty {
                    finishOneOff(id, upload, error: nil)
                    return
                }
                list = try PlanFiles.write(toRemove)
            } catch {
                finishOneOff(id, upload, error: error.localizedDescription)
                return
            }

            let remover = RcloneCall()
            calls[id] = remover
            update(id) { s in
                AppModel.clearProgress(&s)
                s.activity = .delete
                s.itemsTotal = toRemove.count
                s.itemsDone = 0
                s.progress = 0
            }
            let outcome = await runTransfer(remover, id: id, binary: binary,
                                            arguments: Rclone.deleteArguments(pair, list: list.path, count: toRemove.count),
                                            environment: environment)
            try? FileManager.default.removeItem(at: list)
            let removed = outcome.lastStats?.deletes ?? 0
            finishOneOff(id, remover, error: outcome.ok || outcome.cancelled ? nil
                         : "Removed \(removed) of \(Fmt.files(toRemove.count)) from the bucket, then rclone failed: \(outcome.error)")
        }
    }

    private struct TransferOutcome {
        var ok: Bool
        var cancelled: Bool
        var error: String
        var lastStats: Rclone.Stats?
    }

    private func runTransfer(_ call: RcloneCall, id: UUID, binary: String, arguments: [String],
                             environment: [String: String]) async -> TransferOutcome {
        let lastError = LastValue()
        let result = await call.run(
            binary: binary, arguments: arguments, environment: environment,
            onStderrLine: { line in
                let parsed = Rclone.parseLogLine(line)
                if let message = parsed.error { lastError.set(message) }
                guard let stats = parsed.stats else { return }
                Task { @MainActor in self.applyStats(id, stats, for: call) }
            })
        let lastStats = result.stderr.split(separator: "\n").reversed()
            .lazy.compactMap { Rclone.parseLogLine(String($0)).stats }.first
        return TransferOutcome(ok: !result.cancelled && result.status == 0, cancelled: result.cancelled,
                               error: lastError.get() ?? Rclone.lastError(in: result.stderr)
                                   ?? "rclone exited with code \(result.status)",
                               lastStats: lastStats)
    }

    /// Ends a one-off. Success or a stop runs a fresh check so the row shows the real state; a failure
    /// leaves its message visible.
    private func finishOneOff(_ id: UUID, _ call: RcloneCall, error: String?) {
        if calls[id] === call { calls[id] = nil }
        guard config.pairs.contains(where: { $0.id == id }) else { return }
        if let error {
            update(id) { s in
                AppModel.clearProgress(&s)
                s.state = .error
                s.message = error
            }
        } else {
            update(id) { s in
                AppModel.clearProgress(&s)
                s.state = .unknown
            }
            check(id)
        }
    }

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
        for pair in config.pairs where pair.enabled && hiddenScanIsDue(pair, now: now) {
            scanHidden(pair.id)
        }
    }

    // MARK: Old hidden files (B2)

    private var hiddenScans: [UUID: Task<Void, Never>] = [:]
    private var hiddenScanAttempts: [UUID: Date] = [:]

    /// The pair's B2 bucket, folder and key. nil when the pair isn't on B2.
    func hiddenTarget(_ pair: Pair) throws -> B2Target? {
        try B2Target.resolve(pair, remotes: remotesForPlanning())
    }

    /// Whether the pair is on B2 (no Keychain access, so views can ask).
    func supportsHiddenCleanup(_ pair: Pair) -> Bool {
        Rclone.location(pair, remotes: remotesForPlanning())?.store == "b2"
    }

    /// Once a day per B2 pair, retried at most hourly when it fails, and never on a metered network.
    private func hiddenScanIsDue(_ pair: Pair, now: Date) -> Bool {
        guard hiddenScans[pair.id] == nil, supportsHiddenCleanup(pair) else { return false }
        if pair.schedule.skipExpensiveNetwork && networkIsExpensive { return false }
        if let attempt = hiddenScanAttempts[pair.id], now.timeIntervalSince(attempt) < 3600 { return false }
        guard let scanned = status(for: pair.id).hiddenScanned else { return true }
        return now.timeIntervalSince(scanned) >= 86_400
    }

    /// Read-only: counts the files that have been hidden on B2 for at least 30 days, for the suggestion.
    func scanHidden(_ id: UUID) {
        guard hiddenScans[id] == nil, let pair = config.pairs.first(where: { $0.id == id }),
              let target = try? hiddenTarget(pair) else { return }
        hiddenScanAttempts[id] = .now
        hiddenScans[id] = Task {
            defer { hiddenScans[id] = nil }
            let client = B2Client(target.credentials)
            guard let plan = try? await HiddenScanner.plan(pair: pair, target: target, client: client,
                                                           strictLocal: false) else { return }
            recordHiddenScan(plan)
        }
    }

    /// A fresh review is a scan too: keep the menu's suggestion in line with it.
    func recordHiddenScan(_ plan: HiddenPlan) {
        guard let pair = config.pairs.first(where: { $0.id == plan.pair.id }),
              pair.comparisonKey == plan.pair.comparisonKey else { return }
        update(pair.id) { s in
            s.oldHiddenFiles = plan.old.count
            s.oldHiddenBytes = plan.oldBytes
            s.hiddenScanned = .now
        }
    }

    /// Why a reviewed cleanup can't start right now, or nil.
    func purgeBlocker(_ plan: HiddenPlan) -> String? {
        guard let pair = config.pairs.first(where: { $0.id == plan.pair.id }) else {
            return "This folder is no longer in Bucketwatch."
        }
        if pair.comparisonKey != plan.pair.comparisonKey {
            return "The folder's settings changed since this review. Refresh it."
        }
        if isBusy(pair.id) { return "“\(pair.name)” is busy. Wait until it finishes." }
        if Date().timeIntervalSince(plan.created) > 30 * 60 {
            return "This review is more than 30 minutes old. Refresh it."
        }
        if plan.old.isEmpty { return "There's nothing to delete." }
        return nil
    }

    /// Permanently deletes the reviewed old hidden files. Returns why it couldn't start, or nil.
    func startPurge(_ plan: HiddenPlan) -> String? {
        if let blocker = purgeBlocker(plan) { return blocker }
        guard let pair = config.pairs.first(where: { $0.id == plan.pair.id }) else { return "Folder not found" }
        let target: B2Target
        do {
            guard let resolved = try hiddenTarget(pair) else { return "This folder isn't on B2." }
            target = resolved
        } catch {
            return error.localizedDescription
        }
        guard target.bucket == plan.bucket, target.prefix == plan.prefix else {
            return "The folder's destination changed since this review. Refresh it."
        }
        let id = pair.id
        let total = plan.old.count
        // Never runs a process: it holds the pair (no checks or uploads meanwhile) and carries Stop.
        let token = RcloneCall()
        calls[id] = token
        update(id) { s in
            s.state = .running; s.message = nil
            AppModel.clearProgress(&s)
            s.activity = .purge
            s.itemsTotal = total
            s.itemsDone = 0
            s.progress = 0
        }
        Task {
            let client = B2Client(target.credentials)
            let report = await HiddenPurger.run(
                plan, target: target, client: client,
                shouldStop: { token.isCancelled },
                progress: { done in
                    Task { @MainActor in
                        guard self.calls[id] === token else { return }
                        self.update(id) { s in
                            s.itemsDone = done
                            s.progress = min(1, Double(done) / Double(max(total, 1)))
                        }
                    }
                })
            update(id) { s in
                s.oldHiddenFiles = max(0, (s.oldHiddenFiles ?? total) - report.deleted)
                s.oldHiddenBytes = max(0, (s.oldHiddenBytes ?? 0) - report.deletedBytes)
            }
            finishOneOff(id, token, error: report.error.map {
                "Deleted \(report.deleted) of \(Fmt.files(total)) for good, then stopped. \($0)"
            })
            hiddenScanAttempts[id] = nil
            scanHidden(id)
        }
        return nil
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
        // These only open the review window. Nothing runs until the user confirms there.
        case "download": if let id { ReviewWindow.show(id, kind: .download) }
        case "sync-once": if let id { ReviewWindow.show(id, kind: .syncOnce) }
        case "hidden": if let id { HiddenFilesWindow.show(id) }
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

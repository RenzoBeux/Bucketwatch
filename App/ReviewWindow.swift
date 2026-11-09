import AppKit
import SwiftUI

/// The review step for a one-off download or sync. It always starts with a read-only preview,
/// and nothing runs until the user confirms it.
@MainActor
enum ReviewWindow {
    private static var window: NSWindow?
    private static var current: ReviewModel?
    private static let delegate = Delegate()

    static func show(_ id: UUID, kind: OneOffKind) {
        let app = AppModel.shared
        guard let pair = app.config.pairs.first(where: { $0.id == id }) else { return }
        current?.cancel()
        let model = ReviewModel(pair: pair, kind: kind, app: app)
        current = model
        let host = NSHostingController(rootView: ReviewView(model: model, app: app))
        if let window {
            let frame = window.frame
            window.contentViewController = host
            window.setFrame(frame, display: true)
        } else {
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .resizable]
            w.setContentSize(NSSize(width: 640, height: 600))
            w.minSize = NSSize(width: 560, height: 460)
            w.isReleasedWhenClosed = false
            w.delegate = delegate
            w.center()
            window = w
        }
        window?.title = kind == .download ? "Download from Cloud" : "Sync Once"
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.load()
    }

    static func close() { window?.close() }

    private final class Delegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                ReviewWindow.current?.cancel()
                ReviewWindow.current = nil
            }
        }
    }
}

struct FolderGroup: Identifiable {
    /// Unique across the whole list: the same folder can appear in two sections.
    let id: String
    let folder: String
    let files: [PlanEntry]
    var bytes: Int64 { files.reduce(0) { $0 + ($1.size ?? 0) } }

    static func make(_ entries: [PlanEntry], section: String) -> [FolderGroup] {
        Dictionary(grouping: entries) { ($0.path as NSString).deletingLastPathComponent }
            .map { FolderGroup(id: section + "/" + $0.key, folder: $0.key, files: $0.value) }
            .sorted { $0.folder.localizedStandardCompare($1.folder) == .orderedAscending }
    }
}

@MainActor
final class ReviewModel: ObservableObject {
    struct Prepared {
        let plan: TransferPlan
        let cloudGroups: [FolderGroup]
        let uploadGroups: [FolderGroup]
    }

    enum Phase {
        case loading
        case failed(String)
        case ready(Prepared)
    }

    @Published var phase: Phase = .loading
    @Published var acknowledged = false
    @Published var startError: String?
    let kind: OneOffKind
    @Published private(set) var pair: Pair
    private let app: AppModel
    private var builder: PlanBuilder?

    init(pair: Pair, kind: OneOffKind, app: AppModel) {
        self.pair = pair
        self.kind = kind
        self.app = app
    }

    func load() {
        cancel()
        acknowledged = false
        startError = nil
        phase = .loading
        guard let pair = app.config.pairs.first(where: { $0.id == self.pair.id }) else {
            phase = .failed("This folder is no longer in Bucketwatch.")
            return
        }
        self.pair = pair
        if let problem = app.validate(pair) {
            phase = .failed(problem)
            return
        }
        guard let binary = app.rcloneBinary else {
            phase = .failed("rclone not found")
            return
        }
        let builder = PlanBuilder()
        self.builder = builder
        let remotes = app.remotesForPlanning()
        let kind = kind
        Task {
            do {
                let plan = try await builder.build(kind: kind, pair: pair, binary: binary, remotes: remotes)
                guard self.builder === builder else { return }
                phase = .ready(Prepared(plan: plan, cloudGroups: FolderGroup.make(plan.cloudOnly, section: "cloud"),
                                        uploadGroups: FolderGroup.make(plan.toUpload, section: "upload")))
            } catch is CancellationError {
                // Closed or refreshed.
            } catch {
                guard self.builder === builder else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        builder?.cancel()
        builder = nil
    }

    func start(_ plan: TransferPlan) {
        if let problem = app.start(plan, acknowledged: acknowledged) {
            startError = problem
        } else {
            ReviewWindow.close()
        }
    }
}

struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    @ObservedObject var app: AppModel
    @State private var confirmingRemoval = false

    private var isDownload: Bool { model.kind == .download }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(minWidth: 560, minHeight: 460)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: isDownload ? "icloud.and.arrow.down" : "arrow.triangle.2.circlepath.icloud")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(isDownload ? Color.blue : Color.orange)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(isDownload ? "Download from cloud" : "Sync once")
                    .font(.title2.weight(.semibold))
                Text(model.pair.name).font(.headline).foregroundStyle(.secondary)
                Text(route)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(explanation)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private var route: String {
        let local = (model.pair.localPath as NSString).abbreviatingWithTildeInPath
        let remote = Rclone.displayTarget(model.pair)
        return isDownload ? "\(remote)  →  \(local)" : "\(local)  →  \(remote)"
    }

    private var explanation: String {
        if isDownload {
            return "Copies the files that are only in the bucket into the folder, so you can review them. Files already in the folder are never overwritten, and nothing is deleted anywhere."
        }
        let stays = model.pair.mode == .copy
            ? " This runs once: afterwards “\(model.pair.name)” keeps backing up in Copy mode."
            : ""
        return "Makes the bucket match the folder this one time: uploads what's missing, then removes from the bucket the files that are no longer in the folder.\(stays)"
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Comparing the folder with the bucket…")
                Text("Nothing changes until you confirm.").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.red)
                Text("Nothing was changed").font(.headline)
                Text(message)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
                Button("Try Again") { model.load() }
            }
            .padding(20)
        case .ready(let prepared):
            if prepared.plan.isEmpty {
                ContentUnavailableView(
                    isDownload ? "Nothing to download" : "Already in sync",
                    systemImage: "checkmark.icloud",
                    description: Text(isDownload
                                      ? "Every file in the bucket is already in the folder."
                                      : "The bucket already matches the folder."))
            } else {
                ready(prepared)
            }
        }
    }

    private func ready(_ prepared: ReviewModel.Prepared) -> some View {
        let plan = prepared.plan
        return VStack(alignment: .leading, spacing: 0) {
            summary(plan)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            List {
                if !prepared.cloudGroups.isEmpty {
                    Section(isDownload ? "Will be downloaded" : "Will be removed from the bucket") {
                        groupRows(prepared.cloudGroups)
                    }
                }
                if !isDownload && !prepared.uploadGroups.isEmpty {
                    Section("Will be uploaded first") {
                        groupRows(prepared.uploadGroups)
                    }
                }
            }
            .listStyle(.inset)
            notes(plan)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
    }

    @ViewBuilder private func summary(_ plan: TransferPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if isDownload {
                Label {
                    Text("\(Fmt.files(plan.cloudOnly.count)) · \(Fmt.bytes(plan.cloudOnlyBytes)) to download")
                        + Text(plan.unknownSizes > 0 ? " (\(plan.unknownSizes) of unknown size)" : "")
                } icon: { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue) }
                .font(.headline)
                if let free = plan.freeBytes {
                    if let shortfall = plan.spaceShortfall {
                        Label("Not enough space: \(Fmt.bytes(free)) free on this disk, \(Fmt.bytes(shortfall)) short (keeping \(Fmt.bytes(TransferPlan.headroom)) free).",
                              systemImage: "externaldrive.badge.exclamationmark")
                            .foregroundStyle(.red)
                    } else {
                        Label("\(Fmt.bytes(free)) free on this disk", systemImage: "internaldrive")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                if !plan.cloudOnly.isEmpty {
                    Label("\(Fmt.files(plan.cloudOnly.count)) · \(Fmt.bytes(plan.cloudOnlyBytes)) to remove from the bucket",
                          systemImage: "trash.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                }
                if !plan.toUpload.isEmpty {
                    Label("\(Fmt.files(plan.toUpload.count)) · \(Fmt.bytes(plan.uploadBytes)) to upload first",
                          systemImage: "arrow.up.circle.fill")
                        .font(.headline)
                }
                Text("The bucket has \(Fmt.files(plan.remoteFiles)) here; the folder has \(Fmt.files(plan.localFiles)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func groupRows(_ groups: [FolderGroup]) -> some View {
        ForEach(groups) { group in
            DisclosureGroup {
                ForEach(Array(group.files.enumerated()), id: \.offset) { _, file in
                    HStack {
                        Text((file.path as NSString).lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(file.size.map(Fmt.bytes) ?? "—")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .help(file.path)
                }
            } label: {
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(group.folder.isEmpty ? "(top level)" : group.folder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(Fmt.files(group.files.count)) · \(Fmt.bytes(group.bytes))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .help(group.folder)
            }
        }
    }

    @ViewBuilder private func notes(_ plan: TransferPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let retention = plan.retention {
                Label(retention, systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !plan.otherRclone.isEmpty {
                Label {
                    Text("Another rclone is running: \(plan.otherRclone.joined(separator: "; ")). If it's transferring to this bucket, wait until it finishes.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            if app.isBusy(model.pair.id) {
                Label("“\(model.pair.name)” is busy right now. Wait until it finishes.", systemImage: "hourglass")
                    .foregroundStyle(.orange)
            }
            if plan.removesMostOfBucket {
                Toggle(isOn: $model.acknowledged) {
                    Text("I understand this removes \(plan.cloudOnly.count) of the \(plan.remoteFiles) files in the bucket")
                        .foregroundStyle(.red)
                }
                .toggleStyle(.checkbox)
            }
        }
        .font(.callout)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if case .ready(let prepared) = model.phase {
                Text("Compared \(Text(prepared.plan.created, style: .relative)) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Refresh") { model.load() }
            }
            if let error = model.startError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { ReviewWindow.close() }
                .keyboardShortcut(.cancelAction)
            if case .ready(let prepared) = model.phase, !prepared.plan.isEmpty {
                primary(prepared.plan)
            }
        }
    }

    @ViewBuilder private func primary(_ plan: TransferPlan) -> some View {
        let disabled = app.isBusy(plan.pair.id)
            || plan.spaceShortfall != nil
            || (plan.removesMostOfBucket && !model.acknowledged)
        if isDownload {
            Button("Download \(Fmt.files(plan.cloudOnly.count))") { model.start(plan) }
                .keyboardShortcut(.defaultAction)
                .disabled(disabled)
        } else if plan.cloudOnly.isEmpty {
            Button("Upload \(Fmt.files(plan.toUpload.count))") { model.start(plan) }
                .keyboardShortcut(.defaultAction)
                .disabled(disabled)
        } else {
            // Destructive: no Return shortcut, and a second confirmation.
            Button(plan.toUpload.isEmpty
                   ? "Remove \(Fmt.files(plan.cloudOnly.count)) from Bucket…"
                   : "Upload \(plan.toUpload.count), Remove \(plan.cloudOnly.count)…") {
                confirmingRemoval = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(disabled)
            .alert("Remove \(Fmt.files(plan.cloudOnly.count)) (\(Fmt.bytes(plan.cloudOnlyBytes))) from the bucket?",
                   isPresented: $confirmingRemoval) {
                Button("Remove", role: .destructive) { model.start(plan) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text((plan.toUpload.isEmpty ? "" : "\(Fmt.files(plan.toUpload.count)) will be uploaded first. ")
                     + "Only the files listed in the review are removed, and only if they're still missing from the folder. "
                     + (plan.retention ?? ""))
            }
        }
    }
}

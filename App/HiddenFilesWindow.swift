import AppKit
import SwiftUI

/// Review of files hidden on B2 for at least 30 days. Starts with a read-only listing; nothing is
/// deleted until the user confirms twice.
@MainActor
enum HiddenFilesWindow {
    private static var window: NSWindow?
    private static var current: HiddenReviewModel?
    private static let delegate = Delegate()

    static func show(_ id: UUID) {
        let app = AppModel.shared
        guard let pair = app.config.pairs.first(where: { $0.id == id }) else { return }
        current?.cancel()
        let model = HiddenReviewModel(pair: pair, app: app)
        current = model
        let host = NSHostingController(rootView: HiddenReviewView(model: model, app: app))
        if let window {
            let frame = window.frame
            window.contentViewController = host
            window.setFrame(frame, display: true)
        } else {
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .resizable]
            w.setContentSize(NSSize(width: 640, height: 580))
            w.minSize = NSSize(width: 560, height: 440)
            w.isReleasedWhenClosed = false
            w.delegate = delegate
            w.center()
            window = w
        }
        window?.title = "Old Hidden Files"
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.load()
    }

    static func close() { window?.close() }

    private final class Delegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                HiddenFilesWindow.current?.cancel()
                HiddenFilesWindow.current = nil
            }
        }
    }
}

struct HiddenGroup: Identifiable {
    let id: String
    let files: [HiddenFile]
    var folder: String { id }
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    static func make(_ files: [HiddenFile]) -> [HiddenGroup] {
        Dictionary(grouping: files) { ($0.path as NSString).deletingLastPathComponent }
            .map { HiddenGroup(id: $0.key, files: $0.value) }
            .sorted { $0.folder.localizedStandardCompare($1.folder) == .orderedAscending }
    }
}

@MainActor
final class HiddenReviewModel: ObservableObject {
    enum Phase {
        case loading
        case failed(String)
        case ready(HiddenPlan, [HiddenGroup])
    }

    @Published var phase: Phase = .loading
    @Published var startError: String?
    @Published private(set) var pair: Pair
    private let app: AppModel
    private var task: Task<Void, Never>?

    init(pair: Pair, app: AppModel) {
        self.pair = pair
        self.app = app
    }

    func load() {
        cancel()
        startError = nil
        phase = .loading
        guard let pair = app.config.pairs.first(where: { $0.id == self.pair.id }) else {
            phase = .failed("This folder is no longer in Bucketwatch.")
            return
        }
        self.pair = pair
        let target: B2Target
        do {
            guard let resolved = try app.hiddenTarget(pair) else {
                phase = .failed("This folder isn't backed up to Backblaze B2.")
                return
            }
            target = resolved
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        task = Task {
            do {
                let plan = try await HiddenScanner.plan(pair: pair, target: target,
                                                        client: B2Client(target.credentials), strictLocal: true)
                try Task.checkCancellation()
                phase = .ready(plan, HiddenGroup.make(plan.old))
                // Keep the menu's suggestion in line with what the review found.
                app.recordHiddenScan(plan)
            } catch is CancellationError {
                // Closed or refreshed.
            } catch let error as URLError where error.code == .cancelled {
                // Closed or refreshed.
            } catch {
                if !Task.isCancelled { phase = .failed(error.localizedDescription) }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func start(_ plan: HiddenPlan) {
        if let problem = app.startPurge(plan) {
            startError = problem
        } else {
            HiddenFilesWindow.close()
        }
    }
}

struct HiddenReviewView: View {
    @ObservedObject var model: HiddenReviewModel
    @ObservedObject var app: AppModel
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(minWidth: 560, minHeight: 440)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "trash.circle")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("Old hidden files").font(.title2.weight(.semibold))
                Text(model.pair.name).font(.headline).foregroundStyle(.secondary)
                Text(Rclone.displayTarget(model.pair))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("These files were deleted from the bucket at least \(HiddenFiles.minimumDays) days ago. B2 still keeps them as hidden versions, and you pay for that storage. Deleting them is permanent: they can't be restored afterwards.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Listing hidden versions on B2…")
                Text("Nothing changes until you confirm.").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.red)
                Text("Nothing was deleted").font(.headline)
                Text(message)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
                Button("Try Again") { model.load() }
            }
            .padding(20)
        case .ready(let plan, let groups):
            if plan.old.isEmpty {
                VStack(spacing: 0) {
                    ContentUnavailableView(
                        "Nothing to clean up",
                        systemImage: "checkmark.icloud",
                        description: Text("No file in this folder has been hidden on B2 for \(HiddenFiles.minimumDays) days or more."))
                    notes(plan)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Label("\(Fmt.files(plan.old.count)) · \(Fmt.bytes(plan.oldBytes)) to delete for good",
                          systemImage: "trash.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    List {
                        Section("Hidden on B2 for \(HiddenFiles.minimumDays)+ days") { rows(groups) }
                    }
                    .listStyle(.inset)
                    notes(plan)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    private func rows(_ groups: [HiddenGroup]) -> some View {
        ForEach(groups) { group in
            DisclosureGroup {
                ForEach(group.files) { file in
                    HStack {
                        Text((file.path as NSString).lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("hidden \(file.hiddenAt.formatted(date: .abbreviated, time: .omitted))")
                            .foregroundStyle(.secondary)
                        Text(Fmt.bytes(file.bytes))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 70, alignment: .trailing)
                    }
                    .font(.callout)
                    .help(file.versions.count == 1 ? file.path : "\(file.path) · \(file.versions.count) versions")
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

    @ViewBuilder private func notes(_ plan: HiddenPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if plan.recentCount > 0 {
                Label("\(Fmt.files(plan.recentCount)) (\(Fmt.bytes(plan.recentBytes))) were hidden less than \(HiddenFiles.minimumDays) days ago. They stay restorable for now and will show up here later.",
                      systemImage: "clock")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !plan.backInFolder.isEmpty {
                Label("\(Fmt.files(plan.backInFolder.count)) hidden on B2 are back in the folder, so they're kept. The next backup uploads them again.",
                      systemImage: "folder.badge.questionmark")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if app.isBusy(model.pair.id) {
                Label("“\(model.pair.name)” is busy right now. Wait until it finishes.", systemImage: "hourglass")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if case .ready(let plan, _) = model.phase {
                Text("Listed \(Text(plan.created, style: .relative)) ago")
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
            Button("Cancel") { HiddenFilesWindow.close() }
                .keyboardShortcut(.cancelAction)
            if case .ready(let plan, _) = model.phase, !plan.old.isEmpty {
                // Destructive: no Return shortcut, and a second confirmation.
                Button("Delete \(Fmt.files(plan.old.count)) for Good…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(app.isBusy(plan.pair.id))
                    .alert("Permanently delete \(Fmt.files(plan.old.count)) (\(Fmt.bytes(plan.oldBytes))) from B2?",
                           isPresented: $confirming) {
                        Button("Delete for Good", role: .destructive) { model.start(plan) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Every stored version of the files listed is deleted, so they can't be restored. Each file is checked again right before: one that was restored or uploaded again since this review is left alone. Nothing in the folder is touched.")
                    }
            }
        }
    }
}

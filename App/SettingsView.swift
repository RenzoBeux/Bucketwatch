import AppKit
import SwiftUI

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func showDashboard() {
        AppModel.shared.selection = .dashboard
        show()
    }

    static func show(select id: UUID? = nil) {
        let model = AppModel.shared
        if let id, model.config.pairs.contains(where: { $0.id == id }) {
            model.selection = .pair(id)
        } else if model.selection == nil {
            model.selection = .dashboard
        }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = "Bucketwatch"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.setContentSize(NSSize(width: 780, height: 600))
            w.minSize = NSSize(width: 640, height: 460)
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("BucketwatchSettings")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var pairToRemove: Pair?

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Label("Dashboard", systemImage: "square.grid.2x2").tag(SidebarItem.dashboard)
                Section("Folders") {
                    ForEach(model.config.pairs) { pair in
                        let state = model.status(for: pair.id).state
                        Label {
                            Text(pair.name)
                        } icon: {
                            Image(systemName: state.symbol).foregroundStyle(state.tint)
                        }
                        .tag(SidebarItem.pair(pair.id))
                    }
                    .onMove { model.config.pairs.move(fromOffsets: $0, toOffset: $1) }
                }
                Section {
                    Label("General", systemImage: "gearshape").tag(SidebarItem.general)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 4) {
                    Button { model.addPair() } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
                        .help("Add folder")
                    Button {
                        if case .pair(let id) = model.selection {
                            pairToRemove = model.config.pairs.first { $0.id == id }
                        }
                    } label: { Image(systemName: "minus").frame(width: 20, height: 20) }
                        .help("Remove folder")
                        .disabled({ if case .pair = model.selection { return false }; return true }())
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch model.selection {
            case .dashboard:
                DashboardView(model: model)
            case .pair(let id):
                if let binding = model.binding(for: id) {
                    PairEditor(pair: binding, model: model).id(id)
                }
            case .general:
                GeneralSettings(model: model)
            case nil:
                ContentUnavailableView("No folder selected", systemImage: "folder",
                                       description: Text("Add a folder with the + button."))
            }
        }
        .alert("Remove “\(pairToRemove?.name ?? "")”?",
               isPresented: Binding(get: { pairToRemove != nil }, set: { if !$0 { pairToRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let pair = pairToRemove { model.removePair(pair.id) }
                pairToRemove = nil
            }
            Button("Cancel", role: .cancel) { pairToRemove = nil }
        } message: {
            Text(removeMessage)
        }
    }

    private var removeMessage: String {
        var text = "Bucketwatch stops watching this folder. Nothing is deleted from the folder or the bucket."
        if pairToRemove?.destination.kind == .b2 { text += " Its B2 application key is removed from the Keychain." }
        return text
    }
}

// MARK: - Pair editor

private struct PairEditor: View {
    @Binding var pair: Pair
    @ObservedObject var model: AppModel

    @State private var appKey = ""
    @State private var excludesText = ""
    @State private var remotes: [String] = []
    @State private var testing = false
    @State private var testResult: String?
    @State private var confirmSync = false
    @State private var confirmRemove = false

    var body: some View {
        Form {
            actions

            Section("Folder") {
                TextField("Name", text: $pair.name)
                LabeledContent("Local folder") {
                    HStack {
                        Text(pair.localPath.isEmpty ? "None" : (pair.localPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(pair.localPath.isEmpty ? .secondary : .primary)
                            .help(pair.localPath)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }

            Section("Destination") {
                Picker("Service", selection: $pair.destination.kind) {
                    Text("Backblaze B2").tag(DestinationKind.b2)
                    Text("rclone remote").tag(DestinationKind.rcloneRemote)
                }
                if pair.destination.kind == .b2 {
                    TextField("Key ID", text: $pair.destination.keyID)
                        .font(.body.monospaced())
                    SecureField("Application key", text: $appKey)
                        .font(.body.monospaced())
                        .onChange(of: appKey) { _, value in Keychain.set(value, for: pair.id.uuidString) }
                    TextField("Bucket", text: $pair.destination.bucket)
                } else {
                    Picker("Remote", selection: $pair.destination.remote) {
                        Text("Choose…").tag("")
                        ForEach(remotesIncludingCurrent, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Path", text: $pair.destination.path, prompt: Text("optional/sub/folder"))
                LabeledContent("Uploads to") {
                    Text(Rclone.displayTarget(pair)).textSelection(.enabled).foregroundStyle(.secondary)
                }
                if let other = model.overlappingPair(for: pair) {
                    Label {
                        Text("This destination overlaps with “\(other.name)” (\(Rclone.displayTarget(other))). Two folders can't share a destination or be nested inside each other, so neither will be checked or backed up until you change the path.")
                    } icon: {
                        Image(systemName: "exclamationmark.octagon.fill")
                    }
                    .font(.callout)
                    .foregroundStyle(.red)
                }
                HStack {
                    Button("Test connection") {
                        testing = true
                        testResult = nil
                        Task {
                            testResult = await model.testConnection(pair)
                            testing = false
                        }
                    }
                    .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult {
                        Text(testResult).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }

            Section {
                Picker("Mode", selection: modeBinding) {
                    Text("Copy").tag(SyncMode.copy)
                    Text("Sync (mirror)").tag(SyncMode.sync)
                }
                .pickerStyle(.segmented)
                Label {
                    Text(pair.mode == .copy
                         ? "Only adds and updates files in the bucket. Deleting files here never deletes them from the bucket."
                         : "The bucket mirrors this folder: files you delete here are removed from the bucket on the next sync. On B2 they are hidden as old versions until your lifecycle rules purge them.")
                } icon: {
                    Image(systemName: pair.mode == .copy ? "plus.square.on.square" : "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(pair.mode == .copy ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            } header: {
                Text("Mode")
            }

            Section("Schedule") {
                Picker("Check for changes", selection: $pair.checkEveryMinutes) {
                    Text("Every 15 minutes").tag(15)
                    Text("Every 30 minutes").tag(30)
                    Text("Every hour").tag(60)
                    Text("Every 3 hours").tag(180)
                    Text("Every 6 hours").tag(360)
                    Text("Every 12 hours").tag(720)
                    Text("Once a day").tag(1440)
                }
                Picker("Upload automatically", selection: $pair.schedule.kind) {
                    Text("Never (manual)").tag(ScheduleKind.manual)
                    Text("Every few hours").tag(ScheduleKind.interval)
                    Text("Daily at a set time").tag(ScheduleKind.daily)
                }
                if pair.schedule.kind == .interval {
                    Stepper(value: $pair.schedule.everyHours, in: 1...72) {
                        Text("At most every \(pair.schedule.everyHours) hour\(pair.schedule.everyHours == 1 ? "" : "s")")
                    }
                }
                if pair.schedule.kind == .daily {
                    DatePicker("Time", selection: dailyTime, displayedComponents: .hourAndMinute)
                }
                if pair.schedule.kind != .manual {
                    Toggle("Only when connected to power", isOn: $pair.schedule.onlyOnPower)
                    Toggle("Skip on Personal Hotspot or Low Data Mode", isOn: $pair.schedule.skipExpensiveNetwork)
                }
            }

            Section {
                TextField("Patterns", text: $excludesText, prompt: Text("*.LRF"), axis: .vertical)
                    .lineLimit(3...8)
                    .font(.body.monospaced())
                    .onChange(of: excludesText) { _, value in
                        pair.excludes = value.split(separator: "\n").map(String.init)
                    }
            } header: {
                Text("Exclude")
            } footer: {
                Text("One rclone filter pattern per line, e.g. `*.LRF` or `Proxies/**`.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Watch this folder", isOn: $pair.enabled)
                HStack {
                    Spacer()
                    Button("Remove Folder…", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(pair.name.isEmpty ? "Folder" : pair.name)
        .onAppear {
            appKey = Keychain.get(pair.id.uuidString) ?? ""
            excludesText = pair.excludes.joined(separator: "\n")
            remotes = model.listRemotes()
        }
        .alert("Switch to Sync?", isPresented: $confirmSync) {
            Button("Use Sync", role: .destructive) { pair.mode = .sync }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files deleted from “\(pair.name)” will also be removed from the bucket on the next sync.")
        }
        .alert("Remove “\(pair.name)”?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.removePair(pair.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bucketwatch stops watching this folder. Nothing is deleted from the folder or the bucket."
                 + (pair.destination.kind == .b2 ? " Its B2 application key is removed from the Keychain." : ""))
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        let status = model.status(for: pair.id)
        let busy = model.isBusy(pair.id)
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    if busy {
                        Button("Stop") { model.stop(pair.id) }
                    } else {
                        Button("Check Now") { model.check(pair.id) }
                        Button(pair.mode == .sync ? "Sync Now" : "Back Up Now") { model.backUp(pair.id) }
                    }
                }
            } label: {
                Label {
                    Text(status.summary)
                        .foregroundStyle(status.state == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                } icon: {
                    Image(systemName: status.symbol).foregroundStyle(status.state.tint)
                }
            }
            actionRow("Download from Cloud…", symbol: "icloud.and.arrow.down",
                      detail: "Copies the files that are only in the bucket into this folder, so you can review them.") {
                ReviewWindow.show(pair.id, kind: .download)
            }
            if pair.mode == .copy {
                actionRow("Sync Once…", symbol: "arrow.triangle.2.circlepath.icloud",
                          detail: "Removes from the bucket the files you deleted here, this one time. The folder stays in Copy mode.") {
                    ReviewWindow.show(pair.id, kind: .syncOnce)
                }
            }
            if model.supportsHiddenCleanup(pair) {
                actionRow("Old Hidden Files…", symbol: "trash.circle",
                          detail: status.hiddenSuggestion
                              ?? "Files deleted from B2 at least \(HiddenFiles.minimumDays) days ago that still use storage. None right now.") {
                    HiddenFilesWindow.show(pair.id)
                }
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("Each action opens a review first. Nothing changes until you confirm.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(pair.localPath.isEmpty)
    }

    private func actionRow(_ title: String, symbol: String, detail: String,
                           action: @escaping () -> Void) -> some View {
        LabeledContent {
            Button(title, action: action)
                .disabled(model.isBusy(pair.id))
        } label: {
            Label {
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol).foregroundStyle(.tint)
            }
        }
    }

    private var remotesIncludingCurrent: [String] {
        let current = pair.destination.remote
        return current.isEmpty || remotes.contains(current) ? remotes : remotes + [current]
    }

    private var modeBinding: Binding<SyncMode> {
        Binding(get: { pair.mode }, set: { newValue in
            if newValue == .sync && pair.mode != .sync { confirmSync = true } else { pair.mode = newValue }
        })
    }

    private var dailyTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: pair.schedule.dailyHour, minute: pair.schedule.dailyMinute,
                                      second: 0, of: .now) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                pair.schedule.dailyHour = parts.hour ?? 3
                pair.schedule.dailyMinute = parts.minute ?? 0
            })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch Folder"
        if !pair.localPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: pair.localPath) }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pair.localPath = url.path
        if pair.name == "New folder" || pair.name.isEmpty { pair.name = url.lastPathComponent }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @State private var version: String?

    var body: some View {
        Form {
            Section("rclone") {
                TextField("Path", text: $model.config.rclonePath, prompt: Text(Rclone.locate(custom: "") ?? "/opt/homebrew/bin/rclone"))
                    .font(.body.monospaced())
                LabeledContent("Status") {
                    if let version {
                        Text(version).foregroundStyle(.secondary)
                    } else {
                        Text("Not found — install with `brew install rclone`").foregroundStyle(.red)
                    }
                }
            }
            Section("App") {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                LabeledContent("Settings file") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url])
                    }
                }
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Add the Bucketwatch widget from the desktop: right-click the wallpaper → Edit Widgets.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear { version = model.rcloneVersion() }
        .onChange(of: model.config.rclonePath) { _, _ in version = model.rcloneVersion() }
    }
}

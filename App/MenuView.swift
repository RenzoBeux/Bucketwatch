import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let snapshot = model.snapshot
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: snapshot.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(snapshot.overall.tint)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.headline).font(.headline)
                    Text(snapshot.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Check all folders") { model.checkAll() }
                    .disabled(model.config.pairs.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if model.config.pairs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("Pick a folder and a bucket to watch.").font(.callout).foregroundStyle(.secondary)
                    Button("Add folder…") {
                        model.addPair()
                        SettingsWindow.show()
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.config.pairs) { pair in
                        PairRow(pair: pair, status: model.status(for: pair.id), busy: model.isBusy(pair.id), model: model)
                    }
                }
                .padding(8)
            }

            Divider()

            HStack {
                Button("Settings…") { SettingsWindow.show() }
                    .keyboardShortcut(",")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(width: 370)
    }
}

private struct PairRow: View {
    let pair: Pair
    let status: PairStatus
    let busy: Bool
    let model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(status.state.tint)
                .symbolEffect(.pulse, isActive: status.state == .checking || status.state == .running)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(pair.name).font(.system(.body, weight: .semibold)).lineLimit(1)
                    if pair.mode == .sync {
                        Text("SYNC")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(.orange.opacity(0.18)))
                            .foregroundStyle(.orange)
                    }
                    if !pair.enabled {
                        Text("PAUSED")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(.secondary.opacity(0.18)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(status.summary)
                    .font(.caption)
                    .foregroundStyle(status.state == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if status.state == .running {
                    ProgressView(value: status.progress ?? 0)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(.blue)
                    if let detail = status.progressDetail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    footnote
                    if let suggestion = status.hiddenSuggestion {
                        Button { HiddenFilesWindow.show(pair.id) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "trash.circle")
                                Text(suggestion)
                                Text("· Review…").foregroundStyle(.tint)
                            }
                            .font(.caption2)
                            .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Deleted from the bucket \(HiddenFiles.minimumDays)+ days ago and still billed. Review before anything is deleted.")
                    }
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                if busy {
                    IconButton(symbol: "stop.circle", help: "Stop") { model.stop(pair.id) }
                } else {
                    IconButton(symbol: "arrow.clockwise", help: "Check now") { model.check(pair.id) }
                    IconButton(symbol: "icloud.and.arrow.up", help: pair.mode == .sync ? "Sync now" : "Back up now",
                               prominent: status.state == .pending) { model.backUp(pair.id) }
                }
                Menu { menuItems } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 26, height: 26)
                .help("More")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.07) : Color.primary.opacity(0.035))
        )
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    /// The one-off actions only open a review window. Nothing runs from the menu itself.
    @ViewBuilder private var menuItems: some View {
        Button("Download from Cloud…") { ReviewWindow.show(pair.id, kind: .download) }
        if pair.mode == .copy {
            Button("Sync Once…") { ReviewWindow.show(pair.id, kind: .syncOnce) }
        }
        if model.supportsHiddenCleanup(pair) {
            Button("Old Hidden Files…") { HiddenFilesWindow.show(pair.id) }
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: pair.localPath)
        }
        Button("Edit…") { SettingsWindow.show(select: pair.id) }
    }

    @ViewBuilder private var footnote: some View {
        HStack(spacing: 4) {
            if let checked = status.lastChecked {
                Text("Checked \(Text(checked, style: .relative)) ago")
            } else {
                Text(Rclone.displayTarget(pair))
            }
            if let note = status.message, status.state == .pending {
                Text("· \(note)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: prominent ? symbol + ".fill" : symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(prominent ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .background(Circle().fill(hovering ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

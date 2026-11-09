import AppKit
import SwiftUI

/// The main view of the app window: every folder → bucket pair at a glance.
struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var tilesWidth: CGFloat = 0

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 16, alignment: .top)]

    var body: some View {
        let snapshot = model.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(snapshot)
                if model.config.pairs.isEmpty {
                    empty
                } else {
                    GlassGroup(spacing: 16) { tiles(snapshot) }
                    GlassGroup(spacing: 16) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(model.config.pairs) { pair in
                                PairCard(pair: pair, status: model.status(for: pair.id),
                                         busy: model.isBusy(pair.id), model: model)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background { DashboardBackground(state: snapshot.overall) }
        .navigationTitle("Dashboard")
    }

    // MARK: Header

    private func header(_ snapshot: Snapshot) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: snapshot.symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(snapshot.overall.tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 60, height: 60)
                .glassCard(cornerRadius: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.headline).font(.largeTitle.weight(.bold))
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(snapshot.detail).font(.title3).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer()
            Button { model.checkAll() } label: { Label("Check All", systemImage: "arrow.clockwise") }
                .glassButton()
                .fixedSize()
                .disabled(model.config.pairs.isEmpty)
            Button { model.addPair() } label: { Label("Add Folder", systemImage: "plus") }
                .glassButton(prominent: true)
                .fixedSize()
        }
        .controlSize(.large)
    }

    // MARK: Tiles

    private func tiles(_ snapshot: Snapshot) -> some View {
        let pairs = snapshot.pairs
        let inSync = pairs.filter { $0.state == .inSync }.count
        let pending = pairs.filter { $0.state == .pending }
        let pendingFiles = pending.reduce(0) { $0 + $1.pendingFiles }
        let lastRun = pairs.compactMap(\.lastRun).max()
        let hiddenBytes = pairs.reduce(Int64(0)) { $0 + ($1.oldHiddenBytes ?? 0) }
        let hiddenFiles = pairs.reduce(0) { $0 + ($1.oldHiddenFiles ?? 0) }
        let all = [
            StatTile(title: "Folders", symbol: "folder.fill", tint: .blue,
                     value: "\(pairs.count)", caption: "\(inSync) up to date"),
            StatTile(title: "Pending", symbol: "exclamationmark.icloud.fill",
                     tint: pendingFiles > 0 ? .orange : .green,
                     value: pendingFiles > 0 ? Fmt.bytes(snapshot.pendingBytes) : "Nothing",
                     caption: pendingFiles > 0 ? "\(Fmt.files(pendingFiles)) to upload" : "All in the cloud"),
            StatTile(title: "Last backup", symbol: "clock.fill", tint: .purple,
                     value: lastRun.map { $0.formatted(.relative(presentation: .named)) } ?? "Never",
                     caption: lastRun.map { $0.formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? "—"),
            StatTile(title: "B2 cleanup", symbol: "trash.circle.fill",
                     tint: hiddenFiles > 0 ? .orange : .secondary,
                     value: hiddenFiles > 0 ? Fmt.bytes(hiddenBytes) : "None",
                     caption: hiddenFiles > 0 ? "\(Fmt.files(hiddenFiles)) to review" : "No old hidden files"),
        ]
        // One row when there's room for four comfortable tiles, otherwise two by two.
        return Group {
            if tilesWidth >= 4 * 185 + 3 * 16 {
                HStack(spacing: 16) { ForEach(0..<4, id: \.self) { all[$0] } }
            } else {
                Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                    GridRow { all[0]; all[1] }
                    GridRow { all[2]; all[3] }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { tilesWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in tilesWidth = width }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No folders yet").font(.title2.weight(.semibold))
            Text("Pick a folder on your Mac and the bucket it backs up to.").foregroundStyle(.secondary)
            Button("Add Folder…") { model.addPair() }
                .glassButton(prominent: true)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(48)
        .glassCard(cornerRadius: 28)
    }
}

// MARK: - Tile

private struct StatTile: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(value)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 22)
    }
}

// MARK: - Pair card

private struct PairCard: View {
    let pair: Pair
    let status: PairStatus
    let busy: Bool
    @ObservedObject var model: AppModel

    private var isActive: Bool { status.state == .checking || status.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: status.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(status.state.tint)
                    .symbolEffect(.pulse, isActive: isActive)
                    .frame(width: 44, height: 44)
                    .glassCard(cornerRadius: 22, tint: status.state.tint.opacity(0.18))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(pair.name).font(.title3.weight(.semibold)).lineLimit(1)
                        if pair.mode == .sync { Badge(text: "SYNC", tint: .orange) }
                        if !pair.enabled { Badge(text: "PAUSED", tint: .secondary) }
                    }
                    Text(status.summary)
                        .font(.callout)
                        .foregroundStyle(status.state == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Menu { PairActionItems(pair: pair, model: model) } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .glassCard(cornerRadius: 15)
                .help("More actions")
            }

            VStack(alignment: .leading, spacing: 5) {
                route(symbol: "folder", text: (pair.localPath as NSString).abbreviatingWithTildeInPath,
                      placeholder: "No folder chosen")
                route(symbol: "icloud", text: Rclone.displayTarget(pair), placeholder: "No destination")
            }

            if status.state == .running {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: status.progress ?? 0).progressViewStyle(.linear).tint(.blue)
                    if let detail = status.progressDetail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }

            if let suggestion = status.hiddenSuggestion {
                Button { HiddenFilesWindow.show(pair.id) } label: {
                    Label {
                        Text(suggestion) + Text(" · Review…").foregroundColor(.accentColor)
                    } icon: {
                        Image(systemName: "trash.circle.fill").foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Deleted from the bucket \(HiddenFiles.minimumDays)+ days ago and still billed. Review before anything is deleted.")
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if let checked = status.lastChecked {
                        Text("Checked \(Text(checked, style: .relative)) ago")
                    }
                    if let run = status.lastRun {
                        Text("Backed up \(run.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                Spacer()
                if busy {
                    Button { model.stop(pair.id) } label: { Label("Stop", systemImage: "stop.fill") }
                        .glassButton()
                } else {
                    Button { model.check(pair.id) } label: { Image(systemName: "arrow.clockwise") }
                        .glassButton()
                        .help("Check now")
                    Button { model.backUp(pair.id) } label: {
                        Label(pair.mode == .sync ? "Sync" : "Back Up", systemImage: "icloud.and.arrow.up")
                    }
                    .glassButton(prominent: status.state == .pending)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 26, tint: cardTint)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .contextMenu { PairActionItems(pair: pair, model: model) }
        .onTapGesture(count: 2) { SettingsWindow.show(select: pair.id) }
    }

    private var cardTint: Color? {
        switch status.state {
        case .error: .red.opacity(0.10)
        case .pending: .orange.opacity(0.08)
        case .running: .blue.opacity(0.08)
        default: nil
        }
    }

    private func route(symbol: String, text: String, placeholder: String) -> some View {
        let missing = text.isEmpty || text == "—"
        return Label {
            Text(missing ? placeholder : text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: symbol).frame(width: 16)
        }
        .font(.caption)
        .foregroundStyle(missing ? .tertiary : .secondary)
        .help(text)
    }
}

private struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
    }
}

// MARK: - Background

/// Soft color behind the glass, tinted by the overall state.
private struct DashboardBackground: View {
    let state: PairState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let strength = scheme == .dark ? 0.32 : 0.22
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [accent.opacity(strength), .clear], center: .topLeading,
                           startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Color.teal.opacity(strength * 0.8), .clear], center: .bottomTrailing,
                           startRadius: 0, endRadius: 650)
            RadialGradient(colors: [Color.indigo.opacity(strength * 0.6), .clear], center: .topTrailing,
                           startRadius: 0, endRadius: 500)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: state)
    }

    private var accent: Color {
        switch state {
        case .error: .red
        case .pending: .orange
        case .running: .blue
        case .inSync: .green
        default: .blue
        }
    }
}

// MARK: - Liquid Glass, with a material fallback before macOS 26

struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder func glassCard(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular,
                        in: .rect(cornerRadius: cornerRadius))
        } else {
            background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(tint)
                        }
                    }
            }
        }
    }

    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

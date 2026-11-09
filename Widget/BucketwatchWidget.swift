import SwiftUI
import WidgetKit

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        let stored = SharedStore.load()
        let snapshot = (stored?.pairs.isEmpty == false ? stored : nil) ?? (context.isPreview ? .sample : .empty)
        completion(StatusEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // The app reloads the widget whenever a status changes; this is only a fallback.
        let entry = StatusEntry(date: .now, snapshot: SharedStore.load() ?? .empty)
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

@main
struct BucketwatchWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BucketwatchStatus", provider: StatusProvider()) { entry in
            StatusWidgetView(snapshot: entry.snapshot)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Backup Status")
        .description("See which folders still have files that aren't in your bucket.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: Snapshot

    var body: some View {
        switch family {
        case .systemSmall: small
        default: list(limit: family == .systemLarge ? 7 : 3)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top) {
                Image(systemName: snapshot.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(snapshot.overall.tint)
                    .widgetAccentable()
                Spacer()
                if let percent = snapshot.pairs.first(where: { $0.state == .running })?.percent {
                    Text("\(percent)%")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.blue)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            Text(snapshot.headline)
                .font(.system(.headline, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(snapshot.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            updatedLine
        }
        .widgetURL(URL(string: "bucketwatch://open"))
    }

    private func list(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: snapshot.symbol)
                    .foregroundStyle(snapshot.overall.tint)
                    .widgetAccentable()
                Text(snapshot.headline).font(.system(.headline, design: .rounded))
                Spacer()
                updatedLine
            }
            if snapshot.pairs.isEmpty {
                Spacer()
                Text("Open Bucketwatch to add a folder and a bucket.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(snapshot.pairs.prefix(limit)) { status in
                    Row(status: status)
                }
                if snapshot.pairs.count > limit {
                    Text("+\(snapshot.pairs.count - limit) more").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .widgetURL(URL(string: "bucketwatch://open"))
    }

    @ViewBuilder private var updatedLine: some View {
        if snapshot.updated > .distantPast {
            Text("Updated \(Text(snapshot.updated, style: .relative)) ago")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

private struct Row: View {
    let status: PairStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(status.state.tint)
                .widgetAccentable()
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(status.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing
        }
    }

    @ViewBuilder private var trailing: some View {
        switch status.state {
        case .running:
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(status.percent ?? 0)%")
                    .font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.blue)
                ProgressView(value: status.progress ?? 0).tint(.blue).frame(width: 54)
            }
        case .pending:
            Link(destination: URL(string: "bucketwatch://run?id=\(status.id.uuidString)")!) {
                Text("Back up")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.orange.opacity(0.18)))
                    .foregroundStyle(.orange)
            }
        case .inSync:
            if let checked = status.lastChecked {
                Text(checked, style: .relative).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    .frame(maxWidth: 60, alignment: .trailing)
            }
        default:
            EmptyView()
        }
    }
}

#Preview(as: .systemMedium) {
    StatusWidget()
} timeline: {
    StatusEntry(date: .now, snapshot: .sample)
}

import SwiftUI

extension PairState {
    var symbol: String {
        switch self {
        case .unknown: "icloud"
        case .checking: "arrow.clockwise.icloud.fill"
        case .inSync: "checkmark.icloud.fill"
        case .pending: "exclamationmark.icloud.fill"
        case .running: "icloud.and.arrow.up.fill"
        case .error: "xmark.icloud.fill"
        }
    }

    var tint: Color {
        switch self {
        case .unknown, .checking: .secondary
        case .inSync: .green
        case .pending: .orange
        case .running: .blue
        case .error: .red
        }
    }
}

extension PairStatus {
    var percent: Int? { progress.map { Int(($0 * 100).rounded(.down)) } }

    var symbol: String {
        state == .running && activity == .download ? "icloud.and.arrow.down.fill" : state.symbol
    }

    private var cloudOnlyNote: String? {
        guard let cloudOnlyFiles, cloudOnlyFiles > 0 else { return nil }
        return "\(cloudOnlyFiles) only in cloud"
    }

    var summary: String {
        switch state {
        case .unknown: return "Not checked yet"
        case .checking: return "Checking…"
        case .inSync: return ["Up to date", cloudOnlyNote].compactMap { $0 }.joined(separator: " · ")
        case .pending:
            var parts: [String] = []
            if pendingFiles > 0 {
                parts.append("\(Fmt.files(pendingFiles)) · \(Fmt.bytes(pendingBytes)) not backed up")
            }
            if remoteOnlyFiles > 0 {
                parts.append("\(remoteOnlyFiles) to remove from bucket")
            }
            if let cloudOnlyNote { parts.append(cloudOnlyNote) }
            return parts.isEmpty ? "Changes pending" : parts.joined(separator: " · ")
        case .running:
            switch activity ?? .upload {
            case .upload:
                if let percent { return "Uploading · \(percent)%" }
                return "Preparing upload…"
            case .download:
                if let percent { return "Downloading · \(percent)%" }
                return "Preparing download…"
            case .delete:
                if let percent { return "Removing from bucket · \(percent)%" }
                return "Removing from bucket…"
            case .purge:
                if let percent { return "Deleting old hidden files · \(percent)%" }
                return "Deleting old hidden files…"
            }
        case .error:
            return message ?? "Something went wrong"
        }
    }

    /// The cleanup suggestion, e.g. "12 deleted files · 8,4 GB still stored on B2". nil when there's none.
    var hiddenSuggestion: String? {
        guard let count = oldHiddenFiles, count > 0 else { return nil }
        let size = (oldHiddenBytes ?? 0) > 0 ? " · \(Fmt.bytes(oldHiddenBytes ?? 0))" : ""
        return "\(count == 1 ? "1 deleted file" : "\(count) deleted files")\(size) still stored on B2"
    }

    var progressDetail: String? {
        guard state == .running else { return nil }
        if activity == .delete || activity == .purge, let done = itemsDone, let total = itemsTotal {
            return "\(done) of \(Fmt.files(total))"
        }
        guard let done = bytesDone, let total = bytesTotal, total > 0 else { return nil }
        var text = "\(Fmt.bytes(done)) of \(Fmt.bytes(total))"
        if let speed, speed > 0 { text += " · \(Fmt.speed(speed))" }
        if let eta, eta > 0 { text += " · \(Fmt.duration(eta)) left" }
        return text
    }
}

extension Snapshot {
    private var runningActivity: PairActivity? {
        pairs.first { $0.state == .running }.map { $0.activity ?? .upload }
    }

    var symbol: String {
        overall == .running && runningActivity == .download ? "icloud.and.arrow.down.fill" : overall.symbol
    }

    var headline: String {
        let pending = pairs.filter { $0.state == .pending }.count
        switch overall {
        case _ where pairs.isEmpty: return "No folders yet"
        case .inSync: return "All backed up"
        case .running:
            switch runningActivity ?? .upload {
            case .upload: return "Uploading"
            case .download: return "Downloading"
            case .delete: return "Removing files"
            case .purge: return "Deleting old versions"
            }
        case .error: return "Needs attention"
        case .pending: return pending == 1 ? "1 folder pending" : "\(pending) folders pending"
        case .checking: return "Checking…"
        case .unknown: return "Not checked yet"
        }
    }

    var detail: String {
        switch overall {
        case _ where pairs.isEmpty: return "Add one in Bucketwatch"
        case .inSync: return pairs.count == 1 ? "1 folder" : "\(pairs.count) folders"
        case .running:
            let running = pairs.first { $0.state == .running }
            return [running?.percent.map { "\($0)%" }, running?.name].compactMap { $0 }.joined(separator: " · ")
        case .error: return pairs.first { $0.state == .error }?.name ?? ""
        case .pending: return "\(Fmt.bytes(pendingBytes)) to upload"
        default: return ""
        }
    }
}

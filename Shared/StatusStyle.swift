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

    var summary: String {
        switch state {
        case .unknown: return "Not checked yet"
        case .checking: return "Checking…"
        case .inSync: return "Up to date"
        case .pending:
            var parts: [String] = []
            if pendingFiles > 0 {
                parts.append("\(Fmt.files(pendingFiles)) · \(Fmt.bytes(pendingBytes)) not backed up")
            }
            if remoteOnlyFiles > 0 {
                parts.append("\(remoteOnlyFiles) to remove from bucket")
            }
            return parts.isEmpty ? "Changes pending" : parts.joined(separator: " · ")
        case .running:
            if let percent { return "Uploading · \(percent)%" }
            return "Preparing upload…"
        case .error:
            return message ?? "Something went wrong"
        }
    }

    var progressDetail: String? {
        guard state == .running, let done = bytesDone, let total = bytesTotal, total > 0 else { return nil }
        var text = "\(Fmt.bytes(done)) of \(Fmt.bytes(total))"
        if let speed, speed > 0 { text += " · \(Fmt.speed(speed))" }
        if let eta, eta > 0 { text += " · \(Fmt.duration(eta)) left" }
        return text
    }
}

extension Snapshot {
    var headline: String {
        let pending = pairs.filter { $0.state == .pending }.count
        switch overall {
        case _ where pairs.isEmpty: return "No folders yet"
        case .inSync: return "All backed up"
        case .running: return "Uploading"
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

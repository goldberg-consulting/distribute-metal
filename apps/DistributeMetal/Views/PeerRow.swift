import SwiftUI

struct PeerRow: View {
    let peer: Peer
    var isBenchmarking = false
    var onBenchmark: (() -> Void)?
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(peer.displayAddress)
                    if let chip = peer.chip {
                        Text("·")
                        Text(chip)
                    }
                    if let mem = peer.memoryGB {
                        Text("·")
                        Text("\(mem)GB")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if let detail = detailText {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Text(peer.statusLabel)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusColor.opacity(0.15))
                .foregroundStyle(statusColor)
                .clipShape(Capsule())
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let onBenchmark {
                Button(isBenchmarking ? "Testing Link..." : "Test Link", action: onBenchmark)
                    .disabled(isBenchmarking)
            }
            if let onRemove {
                Button("Remove", role: .destructive, action: onRemove)
            }
        }
    }

    private var detailText: String? {
        if let throughput = peer.lastBenchmarkMbps {
            let latency = peer.lastBenchmarkLatencyMs.map { String(format: "%.1f ms", $0) } ?? "n/a"
            return String(format: "%.0f Mbps • %@", throughput, latency)
        }
        return peer.statusDetail
    }

    private var statusColor: Color {
        switch peer.status {
        case .discovered: return .yellow
        case .unreachable: return .gray
        case .agentFailed: return .red
        case .ready: return .green
        case .busy: return .orange
        }
    }
}

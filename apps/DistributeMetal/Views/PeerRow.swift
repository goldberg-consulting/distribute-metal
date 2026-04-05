import SwiftUI

struct PeerRow: View {
    let peer: Peer
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
            }

            Spacer()

            Text(peer.status.rawValue)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusColor.opacity(0.15))
                .foregroundStyle(statusColor)
                .clipShape(Capsule())
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let onRemove {
                Button("Remove", role: .destructive, action: onRemove)
            }
        }
    }

    private var statusColor: Color {
        switch peer.status {
        case .discovered: return .yellow
        case .paired, .ready: return .green
        case .preflight: return .blue
        case .busy: return .orange
        case .offline: return .gray
        }
    }
}

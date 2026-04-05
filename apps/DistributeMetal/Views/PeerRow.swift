import SwiftUI

struct PeerRow: View {
    let peer: Peer

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(peer.displayAddress)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let chip = peer.chip {
                Text(chip)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(peer.status.rawValue)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusColor.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.vertical, 2)
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

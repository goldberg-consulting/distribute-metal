import SwiftUI

struct JobStatusView: View {
    let job: Job
    @EnvironmentObject var orchestrator: JobOrchestrator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.name)
                    .font(.caption.weight(.semibold))
                Spacer()
                phaseLabel
            }

            HStack(spacing: 16) {
                Label("\(job.assignedPeers.count)", systemImage: "desktopcomputer")
                Label("\(job.worldSize)", systemImage: "cpu")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if !job.logs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(job.logs.suffix(10), id: \.self) { line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxHeight: 80)
            }

            HStack {
                switch job.phase {
                case .draft, .ready:
                    Button("Run") {
                        Task { await orchestrator.run() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                case .syncing, .provisioning, .launching, .running:
                    Button("Stop") {
                        Task { await orchestrator.stop() }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                case .succeeded, .failed, .cancelled:
                    Button("Clean") {
                        Task { await orchestrator.cleanJob() }
                    }
                    .buttonStyle(.bordered)

                case .cleaning, .cleaned:
                    EmptyView()
                }

                Spacer()
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var phaseLabel: some View {
        Text(job.phase.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(phaseColor.opacity(0.15))
            .foregroundStyle(phaseColor)
            .clipShape(Capsule())
    }

    private var phaseColor: Color {
        switch job.phase {
        case .draft: return .gray
        case .syncing, .provisioning: return .blue
        case .ready: return .green
        case .launching: return .orange
        case .running: return .green
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .yellow
        case .cleaning, .cleaned: return .gray
        }
    }
}

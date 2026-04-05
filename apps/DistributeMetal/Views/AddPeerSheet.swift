import SwiftUI

struct AddPeerSheet: View {
    @ObservedObject var discovery: DiscoveryService
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var ip = ""
    @State private var port = "8477"

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Peer")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField("IP Address", text: $ip)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", text: $port)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    let p = Int(port) ?? 8477
                    discovery.addManualPeer(name: name, ip: ip, port: p)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || ip.isEmpty)
            }
        }
        .padding()
        .frame(width: 280)
    }
}

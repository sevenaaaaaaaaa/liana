import SwiftUI

struct WatchContentView: View {
    @StateObject private var sender = WatchSender()
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TextField("说一句…", text: $text, axis: .vertical)
                    .focused($focused)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never)

                Button {
                    sender.send(text)
                    if sender.phase == .sent {
                        text = ""
                        focused = false
                    }
                } label: {
                    Label("发到 iPhone", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Text(sender.note).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("松萝")
    }
}

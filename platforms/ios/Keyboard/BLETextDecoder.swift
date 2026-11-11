import Foundation

/// Deliberate text protocol, not an audio or HID decoder. Frames end in LF.
struct BLETextDecoder {
    enum Format: Int { case lines, json }
    enum Event: Equatable { case partial(String), final(String) }
    enum Failure: Error { case oversized, malformed }
    var format: Format = .lines
    private var buffer = Data()
    private var seen: [String] = []

    mutating func reset() { buffer.removeAll(); seen.removeAll() }

    mutating func append(_ data: Data) throws -> [Event] {
        guard buffer.count + data.count <= 65_536 else { reset(); throw Failure.oversized }
        buffer.append(data)
        var events: [Event] = []
        while let newline = buffer.firstIndex(of: 10) {
            let frame = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard frame.count <= 16_384, let line = String(data: frame, encoding: .utf8) else {
                reset(); throw Failure.malformed
            }
            let value = line.hasSuffix("\r") ? String(line.dropLast()) : line
            guard !value.isEmpty else { continue }
            if format == .lines {
                events.append(.final(value))
            } else {
                guard let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
                      let kind = object["type"] as? String, let text = object["text"] as? String,
                      kind == "partial" || kind == "final" else { reset(); throw Failure.malformed }
                if kind == "final", let id = object["id"] as? String {
                    guard !seen.contains(id) else { continue }
                    seen.append(id)
                    if seen.count > 32 { seen.removeFirst() }
                }
                events.append(kind == "partial" ? .partial(text) : .final(text))
            }
        }
        return events
    }
}

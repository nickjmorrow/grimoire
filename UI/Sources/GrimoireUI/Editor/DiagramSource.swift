import CryptoKit
import Foundation

/// Finds fenced ```mermaid blocks in a block's text.
public enum DiagramSource {
    /// The Mermaid source of the first fenced `mermaid` block in `text`, if it has one and the fence is closed.
    public static func mermaid(in text: String) -> String? {
        let t = text.replacingOccurrences(of: "\u{2028}", with: "\n")
        let lines = t.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "```mermaid" }),
              let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "```" }) else { return nil }
        let body = lines[(start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// Cache key for a rendered diagram: the source and the theme it was drawn in.
    public static func key(source: String, theme: String) -> String {
        SHA256.hash(data: Data((theme + "\n" + source).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

import CryptoKit
import Foundation

/// Name-based UUIDs, so every device derives the same id for the same page, tag or property.
enum UUIDv5 {
    static let page = UUID(uuidString: "398663a1-8a21-4151-9ae8-f5be5d7ce800")!
    static let tag = UUID(uuidString: "a9667720-7ff8-4008-803d-f6c06c8cd65d")!
    static let property = UUID(uuidString: "d405175a-e3f0-4145-bbd1-e01355bdd472")!

    static func make(namespace: UUID, name: String) -> String {
        var data = Data()
        withUnsafeBytes(of: namespace.uuid) { data.append(contentsOf: $0) }
        data.append(Data(name.utf8))
        var b = Array(Insecure.SHA1.hash(data: data).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
            .uuidString.lowercased()
    }
}

extension Graph {
    /// The id every device gives an ordinary page with this title (journals use `JournalDate.pageID`).
    public static func pageID(forTitle title: String) -> String { UUIDv5.make(namespace: UUIDv5.page, name: titleKey(title)) }

    /// Case- and normalization-insensitive key for page titles and tag names.
    static func titleKey(_ title: String) -> String { title.lowercased().precomposedStringWithCanonicalMapping }
}

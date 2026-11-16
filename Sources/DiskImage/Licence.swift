import CoreFoundation
import ReaderCore

/// A software licence agreement (SLA) stored in the image's resources. macOS shows it before
/// mounting; Drop shows it before installing. This type only reports it: nothing here
/// accepts, skips or otherwise acts on it.
public struct LicenceAgreement: Sendable, Hashable {
    /// The language shown first: an index into `languages`, from the `LPic` header.
    public let defaultLanguageIndex: Int
    public let languages: [Language]

    public struct Language: Sendable, Hashable {
        /// Classic Mac OS region code (0 = US English, 14 = Japan, ...).
        public let regionCode: UInt16
        /// The resource ID holding this language's text and buttons (5000 + offset).
        public let resourceID: Int
        /// The `LPic` flag saying the text uses a two-byte script (Japanese, Chinese, Korean).
        public let isMultiByte: Bool
        public let body: Body
        /// The `STR#` strings when present, decoded: language name, Agree, Disagree, Print,
        /// Save, then the prompt shown above the buttons. Empty when the image has none.
        public let buttons: [String]
    }

    public enum Body: Sendable, Hashable {
        /// RTF document bytes (`RTF ` resource).
        case rtf([UInt8])
        /// Plain text bytes (`TEXT` resource) in the region's classic Mac encoding;
        /// `text` is the best-effort decode.
        case plain(bytes: [UInt8], text: String)
        /// The `LPic` lists the language but no text resource exists.
        case missing
    }

    static let baseResourceID = 5000
    private static let lpicHeaderSize = 4
    private static let lpicEntrySize = 6

    /// Reads the SLA from a `resource-fork` dictionary. Nil when there is no `LPic`.
    init?(resources: [String: [[String: Any]]]) throws {
        guard
            let lpic = Self.resource(resources, type: "LPic", id: Self.baseResourceID)
                ?? resources["LPic"]?.first.flatMap({ $0["Data"] as? [UInt8] })
        else { return nil }
        let reader = ByteReader(lpic)
        defaultLanguageIndex = Int(try reader.be16(0))
        let count = Int(try reader.be16(2))
        var languages: [Language] = []
        for i in 0..<count {
            let base = Self.lpicHeaderSize + i * Self.lpicEntrySize
            let region = try reader.be16(base)
            let id = Self.baseResourceID + Int(Int16(bitPattern: try reader.be16(base + 2)))
            let multiByte = try reader.be16(base + 4) != 0
            let encoding = Self.encoding(region: region)
            let body: Body
            if let rtf = Self.resource(resources, type: "RTF ", id: id) {
                body = .rtf(rtf)
            } else if let text = Self.resource(resources, type: "TEXT", id: id) {
                body = .plain(bytes: text, text: Self.decode(text, encoding))
            } else {
                body = .missing
            }
            let buttons =
                try Self.resource(resources, type: "STR#", id: id).map { try Self.stringList($0, encoding) } ?? []
            languages.append(
                Language(regionCode: region, resourceID: id, isMultiByte: multiByte, body: body, buttons: buttons))
        }
        self.languages = languages
    }

    private static func resource(_ resources: [String: [[String: Any]]], type: String, id: Int) -> [UInt8]? {
        guard let entries = resources[type] else { return nil }
        for entry in entries where (entry["ID"] as? String).flatMap({ Int($0) }) == id || (entry["ID"] as? Int) == id {
            if let data = entry["Data"] as? [UInt8] { return data }
        }
        return nil
    }

    /// `STR#`: a big-endian count, then that many Pascal strings.
    private static func stringList(_ data: [UInt8], _ encoding: CFStringEncoding) throws -> [String] {
        let reader = ByteReader(data)
        let count = Int(try reader.be16(0))
        var offset = 2
        var strings: [String] = []
        for _ in 0..<count {
            let length = Int(try reader.u8(offset))
            strings.append(decode(try reader.slice(offset + 1, length), encoding))
            offset += 1 + length
        }
        return strings
    }

    private static func decode(_ bytes: [UInt8], _ encoding: CFStringEncoding) -> String {
        let string = bytes.withUnsafeBufferPointer { buffer in
            CFStringCreateWithBytes(nil, buffer.baseAddress, buffer.count, encoding, false)
        }
        if let string { return string as String }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Region codes whose text isn't Mac Roman. Everything else (Western languages) is.
    private static let regionEncodings: [UInt16: CFStringEncodings] = [
        14: .macJapanese,
        51: .macKorean,
        52: .macChineseSimp,
        53: .macChineseTrad,
        19: .macChineseTrad,  // Taiwan
        30: .macCentralEurRoman,  // Poland
        49: .macCyrillic,  // Russia
        20: .macGreek,
        24: .macTurkish,
    ]

    private static func encoding(region: UInt16) -> CFStringEncoding {
        if let special = regionEncodings[region] { return CFStringEncoding(special.rawValue) }
        return CFStringEncoding(CFStringBuiltInEncodings.macRoman.rawValue)
    }
}

import Foundation

/// Parameter hints for the call around the caret (`textDocument/signatureHelp`).
public struct SignatureHelp: Sendable, Hashable {
    public struct Signature: Sendable, Hashable {
        public let label: String
        public let documentation: String?
        /// UTF-16 ranges of each parameter inside `label`.
        public let parameters: [NSRange]
        public let activeParameter: Int?
    }

    public let signatures: [Signature]
    public let activeSignature: Int
    public let activeParameter: Int

    public var active: Signature? {
        signatures.indices.contains(activeSignature) ? signatures[activeSignature] : signatures.first
    }

    /// Range of the parameter being typed, within `active.label`.
    public var activeParameterRange: NSRange? {
        guard let active else { return nil }
        let index = active.activeParameter ?? activeParameter
        return active.parameters.indices.contains(index) ? active.parameters[index] : nil
    }

    public static func parse(_ value: JSONValue) -> SignatureHelp? {
        let signatures = (value["signatures"]?.arrayValue ?? []).compactMap(parseSignature)
        guard !signatures.isEmpty else { return nil }
        return SignatureHelp(signatures: signatures,
                             activeSignature: value["activeSignature"]?.intValue ?? 0,
                             activeParameter: value["activeParameter"]?.intValue ?? 0)
    }

    private static func parseSignature(_ value: JSONValue) -> Signature? {
        guard let label = value["label"]?.stringValue else { return nil }
        let ns = label as NSString
        var searchFrom = 0
        var ranges: [NSRange] = []
        for parameter in value["parameters"]?.arrayValue ?? [] {
            let paramLabel = parameter["label"]
            if let offsets = paramLabel?.arrayValue, offsets.count == 2,
               let start = offsets[0].intValue, let end = offsets[1].intValue {
                ranges.append(NSRange(location: start, length: max(0, end - start)))
            } else if let text = paramLabel?.stringValue {
                let found = ns.range(of: text, range: NSRange(location: searchFrom, length: ns.length - searchFrom))
                ranges.append(found.location == NSNotFound ? NSRange(location: 0, length: 0) : found)
                if found.location != NSNotFound { searchFrom = NSMaxRange(found) }
            }
        }
        let documentation = value["documentation"]?.stringValue ?? value["documentation"]?["value"]?.stringValue
        return Signature(label: label, documentation: documentation, parameters: ranges,
                         activeParameter: value["activeParameter"]?.intValue)
    }
}

import Foundation

/// A function or method in a call hierarchy (`textDocument/prepareCallHierarchy`).
public struct CallHierarchyItem: Sendable, Hashable {
    public let name: String
    public let kind: Int
    public let detail: String?
    public let uri: String
    /// Start of the item's name.
    public let position: TextPosition
    /// The item as the server sent it — echoed back in incoming/outgoing requests.
    public let raw: JSONValue

    public static func parse(_ value: JSONValue) -> CallHierarchyItem? {
        guard let name = value["name"]?.stringValue, let uri = value["uri"]?.stringValue,
              let position = TextPosition(json: (value["selectionRange"] ?? value["range"])?["start"])
        else { return nil }
        return CallHierarchyItem(name: name, kind: value["kind"]?.intValue ?? 12, detail: value["detail"]?.stringValue,
                                 uri: uri, position: position, raw: value)
    }

    public static func parseAll(_ result: JSONValue) -> [CallHierarchyItem] {
        (result.arrayValue ?? []).compactMap(parse)
    }
}

/// One edge of a call hierarchy: the other function, plus where the call happens.
public struct CallHierarchyCall: Sendable, Hashable {
    public let item: CallHierarchyItem
    /// Call sites (in the caller's file for incoming calls, in the selected item's file for outgoing).
    public let callSites: [TextPosition]

    /// Parses `callHierarchy/incomingCalls` (`from`) or `outgoingCalls` (`to`) results.
    public static func parseAll(_ result: JSONValue) -> [CallHierarchyCall] {
        (result.arrayValue ?? []).compactMap { value in
            guard let item = (value["from"] ?? value["to"]).flatMap(CallHierarchyItem.parse) else { return nil }
            let sites = (value["fromRanges"]?.arrayValue ?? []).compactMap { TextPosition(json: $0["start"]) }
            return CallHierarchyCall(item: item, callSites: sites)
        }
    }
}

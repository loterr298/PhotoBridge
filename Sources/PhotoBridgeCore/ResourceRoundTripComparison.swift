import Foundation
import CryptoKit

public struct ResourceRoundTripResult: Codable {
    public let strictBytesIdentical: Bool
    public let authorizedAdjustmentTimestampDifferences: Int
}

public enum ResourceRoundTripComparison {
    /// Foundation collapses duplicate plist keys. Validate the observed XML wrapper before parsing it.
    /// Other changed plist formats stay strict until an ambiguity-safe inspector exists for them.
    private final class UniqueXMLKeys: NSObject, XMLParserDelegate {
        var dictionaries: [Set<String>] = []
        var key: String?
        var valid = true
        var depth = 0
        var elements: [String] = []
        var childCounts: [Int] = []
        var roots = 0
        var scalar: String?
        var leafText = ""
        var rootKey: String?
        var signature: [String] = []
        let scalarTags: Set<String> = ["data", "date", "integer", "real", "true", "false"]
        func reject(_ parser: XMLParser) { valid = false; parser.abortParsing() }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            depth += 1
            let tags: Set<String> = ["plist", "dict", "array", "key", "string", "data", "date", "integer", "real", "true", "false"]
            guard depth <= 256, tags.contains(elementName),
                  elementName == "plist" ? attributeDict == ["version": "1.0"] : attributeDict.isEmpty,
                  scalar == nil else { reject(parser); return }
            let valueTags = tags.subtracting(["plist", "key"])
            if let parent = elements.last, let count = childCounts.last {
                let allowed = parent == "plist" ? (count == 0 && elementName == "dict") :
                    parent == "dict" ? (count % 2 == 0 ? elementName == "key" : valueTags.contains(elementName)) :
                    parent == "array" && valueTags.contains(elementName)
                guard allowed else { reject(parser); return }
                childCounts[childCounts.count - 1] += 1
            } else {
                roots += 1
                guard roots == 1, elementName == "plist" else { reject(parser); return }
            }
            elements.append(elementName)
            childCounts.append(0)
            leafText = ""
            if ["plist", "dict", "array"].contains(elementName) { signature.append("start:" + elementName) }
            if scalarTags.contains(elementName) { scalar = "" }
            if elementName == "dict" { dictionaries.append([]) }
            if elementName == "key" {
                guard key == nil, !dictionaries.isEmpty else { reject(parser); return }
                key = ""
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if key != nil { key! += string; if key!.utf8.count > 1024 * 1024 { reject(parser) } }
            if scalar != nil { scalar! += string }
            if let element = elements.last, !["plist", "dict", "array"].contains(element) { leafText += string }
            if let element = elements.last, ["plist", "dict", "array"].contains(element),
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reject(parser) }
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            reject(parser)
        }
        func parser(_ parser: XMLParser, foundComment comment: String) { reject(parser) }
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { reject(parser) }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let count = childCounts.last, elements.last == elementName,
                  !(elementName == "dict" && count % 2 != 0), !(elementName == "plist" && count != 1) else { reject(parser); return }
            if scalarTags.contains(elementName) {
                guard let text = scalar else { reject(parser); return }
                let pattern: String?
                switch elementName {
                case "date": pattern = "\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z"
                case "integer": pattern = "\\A[+-]?[0-9]+\\z"
                case "real": pattern = "\\A[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?\\z"
                default: pattern = nil
                }
                if let pattern = pattern, text.range(of: pattern, options: .regularExpression) == nil { reject(parser); return }
                if elementName == "date" {
                    let format = ISO8601DateFormatter()
                    guard let date = format.date(from: text), format.string(from: date) == text else { reject(parser); return }
                }
                if elementName == "integer", Int64(text) == nil && UInt64(text) == nil { reject(parser); return }
                if elementName == "real", Double(text)?.isFinite != true { reject(parser); return }
                if elementName == "data" {
                    let encoded = text.filter { ![" ", "\t", "\r", "\n"].contains($0) }
                    guard let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded else { reject(parser); return }
                }
                if ["true", "false"].contains(elementName), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reject(parser); return }
                scalar = nil
            }
            if elementName == "key" {
                guard let text = key, !dictionaries.isEmpty,
                      dictionaries[dictionaries.count - 1].insert(text).inserted else { reject(parser); return }
                key = nil
            }
            if elementName == "dict" {
                guard !dictionaries.isEmpty else { reject(parser); return }
                dictionaries.removeLast()
            }
            if ["plist", "dict", "array"].contains(elementName) { signature.append("end:" + elementName) }
            else {
                if elementName == "key", depth == 3 { rootKey = leafText }
                signature.append("leaf:" + elementName)
                signature.append(elementName == "date" && depth == 3 && rootKey == "adjustmentTimestamp" ? "<authorized-time>" : leafText)
            }
            depth -= 1
            elements.removeLast()
            childCounts.removeLast()
        }
    }
    private static func unambiguousXML(_ data: Data) -> [String]? {
        let delegate = UniqueXMLKeys(); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.valid, delegate.dictionaries.isEmpty, delegate.key == nil, delegate.scalar == nil, delegate.depth == 0 else { return nil }
        return delegate.signature
    }
    private static func equalValues(_ left: Any, _ right: Any) -> Bool {
        if let a = left as? Data, let b = right as? Data { return a == b }
        if let a = left as? Date, let b = right as? Date { return a == b }
        if let a = left as? String, let b = right as? String { return a == b }
        if let a = left as? NSNumber, let b = right as? NSNumber {
            return String(cString: a.objCType) == String(cString: b.objCType) && a == b
        }
        if let a = left as? [Any], let b = right as? [Any] {
            return a.count == b.count && zip(a, b).allSatisfy { equalValues($0, $1) }
        }
        if let a = left as? [String: Any], let b = right as? [String: Any] {
            return a.keys.count == b.keys.count && a.allSatisfy { key, value in
                guard let other = b[key] else { return false }
                return equalValues(value, other)
            }
        }
        return false
    }
    private static func onlyEditTimestampChanged(_ original: Data, _ restored: Data) -> Bool {
        guard original.count <= 4 * 1024 * 1024, restored.count <= 4 * 1024 * 1024,
              let beforeXML = unambiguousXML(original), let afterXML = unambiguousXML(restored), beforeXML == afterXML,
              var before = (try? PropertyListSerialization.propertyList(from: original, options: [], format: nil)) as? [String: Any],
              var after = (try? PropertyListSerialization.propertyList(from: restored, options: [], format: nil)) as? [String: Any],
              let oldTime = before.removeValue(forKey: "adjustmentTimestamp") as? Date,
              let newTime = after.removeValue(forKey: "adjustmentTimestamp") as? Date,
              oldTime != newTime else { return false }
        return equalValues(before, after)
    }
    private static func metadataMatches(_ a: ExportResource, _ b: ExportResource) -> Bool {
        a.resourceType == b.resourceType && a.originalFilename == b.originalFilename &&
        a.uniformTypeIdentifier == b.uniformTypeIdentifier && a.byteCount == b.byteCount
    }
    private static func bytesMatch(_ data: Data, _ resource: ExportResource) -> Bool {
        data.count == resource.byteCount && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == resource.sha256
    }

    /// The sole exception is an explicitly permitted top-level timestamp in a type-7 edit sidecar.
    /// Every opaque payload, unknown field/type, filename, UTI and media resource remains strict.
    public static func verify(expected: [ExportResource], observed: [ExportResource],
                              allowAdjustmentTimestampRewrite: Bool,
                              loadOriginal: (ExportResource) throws -> Data,
                              loadObserved: (ExportResource) throws -> Data) throws -> ResourceRoundTripResult {
        guard !expected.isEmpty, expected.count == observed.count else {
            throw ExportError.invalidManifest("导回资源数量不一致")
        }
        var remaining = observed; var differences = 0
        for original in expected {
            if let index = remaining.firstIndex(where: { metadataMatches(original, $0) && original.sha256 == $0.sha256 }) {
                remaining.remove(at: index); continue
            }
            let candidates = remaining.indices.filter { metadataMatches(original, remaining[$0]) }
            guard allowAdjustmentTimestampRewrite, original.resourceType == 7,
                  original.byteCount <= 4 * 1024 * 1024, candidates.count == 1 else {
                throw ExportError.invalidManifest("导回资源的类型、名称、UTI、长度或 SHA-256 不一致；未忽略差异")
            }
            let index = candidates[0]; let candidate = remaining[index]
            let before = try loadOriginal(original); let after = try loadObserved(candidate)
            guard bytesMatch(before, original), bytesMatch(after, candidate), onlyEditTimestampChanged(before, after) else {
                throw ExportError.invalidManifest("编辑附件变化超出已授权的 adjustmentTimestamp，恢复校验未通过")
            }
            differences += 1; remaining.remove(at: index)
        }
        return ResourceRoundTripResult(strictBytesIdentical: differences == 0, authorizedAdjustmentTimestampDifferences: differences)
    }
}

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
        func reject(_ parser: XMLParser) { valid = false; parser.abortParsing() }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            depth += 1
            if depth > 256 { reject(parser); return }
            if elementName == "dict" { dictionaries.append([]) }
            if elementName == "key" {
                guard key == nil, !dictionaries.isEmpty else { reject(parser); return }
                key = ""
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if key != nil { key! += string; if key!.utf8.count > 1024 * 1024 { reject(parser) } }
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if key != nil { reject(parser) }
        }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "key" {
                guard let text = key, !dictionaries.isEmpty,
                      dictionaries[dictionaries.count - 1].insert(text).inserted else { reject(parser); return }
                key = nil
            }
            if elementName == "dict" {
                guard !dictionaries.isEmpty else { reject(parser); return }
                dictionaries.removeLast()
            }
            depth -= 1
        }
    }
    private static func unambiguousXML(_ data: Data) -> Bool {
        let delegate = UniqueXMLKeys(); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        return parser.parse() && delegate.valid && delegate.dictionaries.isEmpty && delegate.key == nil && delegate.depth == 0
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
              unambiguousXML(original), unambiguousXML(restored),
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

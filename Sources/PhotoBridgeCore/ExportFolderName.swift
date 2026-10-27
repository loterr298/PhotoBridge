import Foundation

/// Converts a user label into one safe, readable folder component. The label
/// never carries a request ID: the manifest remains the identity for resume.
public enum ExportFolderName {
    public static func sanitize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return "PhotoBridge-相册" }
        let forbidden = CharacterSet(charactersIn: "/:").union(.newlines).union(.controlCharacters)
        let replaced = String(trimmed.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
        let collapsed = replaced.split(whereSeparator: { $0 == " " || $0 == "-" }).joined(separator: "-")
        let result = String(collapsed.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
        return result.isEmpty || result == "." || result == ".." ? "PhotoBridge-相册" : result
    }

    public static func continuationName(for previous: String) -> String {
        sanitize(previous + "-继续")
    }
}

import Foundation

public enum DiagnosticError: Error { case invalidComparison, invalidSize, destinationExists }
public enum OrderComparison {
    /// Expected IDs must be transcribed from Photos, never copied as a claimed independent baseline.
    public static func compare(observed: [String], expected: [String]) throws -> [Int] {
        guard observed.count == 20, expected.count == 20,
              Set(expected).count == 20, Set(observed).count == 20,
              !expected.contains(where: { $0.isEmpty }) else { throw DiagnosticError.invalidComparison }
        return zip(observed, expected).enumerated().compactMap { $0.element.0 == $0.element.1 ? nil : $0.offset + 1 }
    }
}

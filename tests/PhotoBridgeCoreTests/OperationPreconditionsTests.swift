import XCTest
@testable import PhotoBridgeCore

final class OperationPreconditionsTests: XCTestCase {
    func testResumeBudgetIncludesExistingCopiesInFreshReadback() throws {
        let budget = try RestoreWriteBudget(resourceBytesByAsset: [[30], [40]], recordedAssets: 1, verifiedThisRun: 0, reserveBytes: 100)
        XCTAssertEqual(budget.requiredBytes, 210)
        XCTAssertThrowsError(try OperationPreconditions.requireCapacity(209, budget: budget))
        XCTAssertNoThrow(try OperationPreconditions.requireCapacity(210, budget: budget))
        XCTAssertThrowsError(try OperationPreconditions.requireFullAccess(.limited))
    }
}

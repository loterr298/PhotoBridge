import XCTest
@testable import PhotoBridgeCore

final class RestoreRecoveryTests: XCTestCase {
    func testPlanRoundTripBindsOriginalPolicyAndSourceIdentities() throws {
        let plan = RestoreRecoveryPlan(inboxSessionID: UUID().uuidString,
            manifestSHA256: String(repeating: "a", count: 64), requestSHA256: String(repeating: "b", count: 64),
            sourceAlbumID: "album", sourceAssetIDs: ["one", "two"], title: "Recovery", allowTimestampRewrite: false)
        try plan.validate()
        let decoded = try JSONDecoder().decode(RestoreRecoveryPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded, plan)
        XCTAssertFalse(decoded.allowTimestampRewrite)
        XCTAssertEqual(decoded.sourceAssetIDs, ["one", "two"])
    }
}

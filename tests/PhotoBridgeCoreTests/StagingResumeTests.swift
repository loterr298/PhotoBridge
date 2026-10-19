import XCTest
@testable import PhotoBridgeCore

final class StagingResumeTests: XCTestCase {
    func testStagingRecoveryBindsExactEditVersionAndOrderedResources() throws {
        let descriptor = StagingResourceSource(resourceType: 1, originalFilename: "same.HEIC", uniformTypeIdentifier: "public.heic")
        func asset(_ date: Double) -> StagingAssetSource {
            StagingAssetSource(identifier: "a", modificationDate: Date(timeIntervalSinceReferenceDate: date),
                creationDate: nil, pixelWidth: 10, pixelHeight: 20, mediaType: 1, mediaSubtypes: 0, resources: [descriptor])
        }
        let source = OrderSnapshot(albumName: "test", albumIdentifier: "album", authorization: "full", fetchMode: "nil-options", identifiers: ["a"], systemVersion: "fixture", build: "test")
        let plan = StagingPlan(sessionID: UUID().uuidString, sourceOrder: source, assets: [asset(123.1234567)])
        let decoded = try JSONDecoder().decode(StagingPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded, plan)
        XCTAssertNoThrow(try decoded.validateCurrent(albumIdentifier: "album", albumName: "test", assets: [asset(123.1234567)]))
        XCTAssertThrowsError(try decoded.validateCurrent(albumIdentifier: "album", albumName: "test", assets: [asset(123.1234568)]))
        XCTAssertThrowsError(try decoded.validateCurrent(albumIdentifier: "album", albumName: "test", assets: []))
    }
}

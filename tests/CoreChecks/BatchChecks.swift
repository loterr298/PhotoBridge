import Foundation
import PhotoBridgeCore

func runBatchChecks() throws {
    let plan = try BatchQueuePlan(identifiers: ["album-a", "album-b"])
    try require(plan.identifiers == ["album-a", "album-b"] && plan.identifiers.count == 2, "batch queue preserves explicit album order")
    try rejects("batch queue rejects duplicate albums") { _ = try BatchQueuePlan(identifiers: ["album-a", "album-a"]) }
    try rejects("batch queue rejects empty albums") { _ = try BatchQueuePlan(identifiers: []) }
}

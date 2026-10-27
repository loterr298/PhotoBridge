import Foundation
import PhotoBridgeCore

func runExportFolderNameChecks() throws {
    try require(ExportFolderName.sanitize("  家庭照片  ") == "家庭照片", "custom folder name keeps readable text")
    try require(ExportFolderName.sanitize("旅行/2026:秋") == "旅行-2026-秋", "folder name removes path separators")
    try require(ExportFolderName.sanitize("   ") == "PhotoBridge-相册", "blank folder name receives a clear fallback")
    try require(ExportFolderName.sanitize(".") == "PhotoBridge-相册", "dot folder name cannot target the parent")
    let longName = String(repeating: "照片", count: 100)
    try require(ExportFolderName.sanitize(longName).count <= 80, "folder name has a bounded length")
    try require(ExportFolderName.continuationName(for: "家庭照片") == "家庭照片-继续", "resume uses a new readable folder")
}

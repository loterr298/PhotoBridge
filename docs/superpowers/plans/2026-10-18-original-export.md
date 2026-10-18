# Original-resource export implementation plan

> **For agentic workers:** Use executing-plans inline, as requested by the user. Follow test-first checks and stage commits.

**Goal:** Export every PhotoKit-exposed resource of a selected ordinary album without encoding or editing media, then copy and verify it through USB on Intel Mac.

**Architecture:** A versioned album manifest groups resources by original ordinal and localIdentifier. iOS exports one resource at a time into a new UUID session with working manifest and failure journal. Mac validates paths and resource declarations before streaming AFC download into a new local directory and independently checking every SHA-256. Only the committed manifest means the entire export was verified.

**Tech Stack:** Existing Swift Package, PhotoKit, SwiftUI, CryptoKit, Python standard library and separately installed libimobiledevice.

**Spec:** PROJECT_PROMPT.md sections 2–4; docs/TECHNICAL_ARCHITECTURE.md. M0 evidence docs/evidence/device-usb-20261018.json.

## Global constraints

- Preserve all original bytes, EXIF/GPS/MakerNotes/private data; no deletion, overwrite, transcoding or photo-library writes.
- Public PhotoKit only. PHAssetResourceManager.writeData exports underlying resources; no thumbnail/ImageCaptureCore export. Preserve unknown resource type numbers.
- Source order is nil-options PhotoKit order. Reading another album does not automatically certify its displayed custom order.
- Full permission required for complete album export. iCloud network option defaults off, with explicit toggle and real errors.
- New UUID paths, no reuse. A partial or failed resource/session must never produce a completed manifest.
- 5-second times only on newly copied Mac files after byte verification, with old/new attribute log; original media bytes untouched.
- Private manifests/assets remain local. GitHub receives source, synthetic tests and build logs only.

## Review focus

- Missing/zero resources, truncated content or hash mismatch cannot commit an album.
- Same filenames, path traversal, duplicate resource destinations and symlink targets cannot overwrite files.
- Live Photo still/video and edited/unknown resources stay grouped; no assumption that first resource is the original.
- Permission revocation, iCloud offline, disk full and cancellation leave explicit incomplete state.
- Source album membership/order changes during export invalidate completion.

## Tasks

### 1: Shared export manifest and file integrity

Files: Sources/PhotoBridgeCore/AlbumManifest.swift; tests/CoreChecks/main.swift; tests/PhotoBridgeCoreTests/ExportTests.swift.

- [x] Write failing checks for valid resource groups/JSON, duplicate/traversing paths, missing hashes/resources, ordinal gaps and 5-second UTC logical times.
- [x] Run CoreChecks and observe missing API failure before implementing.
- [x] Implement Codable manifest types, validation, version and explicit stage/restore verification fields. All paths generated from ordinals and resource indices; original filenames only metadata.
- [x] Verify all local checks; commit with status updated.

### 2: iOS real original-resource staging

Files: apps/iOS/OriginalExportView.swift; apps/iOS/PhotoBridgeApp.swift.

- [x] Add native export sheet to selected album; full permission, current count, default-off iCloud toggle, start, true completed resource count, stop-after-current-resource.
- [x] Use PHAssetResource.assetResources and writeData sequentially to unique .part paths. On successful callback hash file, exclusive commit, record originalFilename/UTI/type and grouping.
- [x] Working manifest/journal survives failure; final staged manifest only after all resources and fresh source identifiers match initial order.
- [ ] Cloud compile against actual SDK and record failure/repair. Device photo export stays NOT_RUN until newly built App installed and run.

### 3: USB album download with integrity and filesystem times

Files: scripts/album_export.py; tests/test_album_export.py; optional native timestamp helper.

- [x] Write failing synthetic tests for manifest rejection, unknown roles, same filenames, successful stream copy, truncated/corrupt data, existing local target and failure before completion.
- [x] Implement CLI list/download under Exports/UUID with bounded manifest and streaming resource reads, exclusive local paths, full hash before completion and final transfer report.
- [x] Apply 5-second mtime only on new copies; record original and logical FS attributes, creation-time unsupported status if unavailable. Re-hash after attributes.
- [x] Run complete Python and Swift checks and rebuild Intel app; commit.

### 4: Cloud, delivery and truthful status

- [ ] Upload exact committed source to private GitHub using existing authorized session; run existing CI and inspect actual tests/iOS/Intel output.
- [ ] Verify downloadable archive CRC and checksums. Deliver updated unsigned IPA and Mac app with signing/install instructions.
- [ ] Update IMPLEMENTATION_STATUS with actual evidence, remaining original-media/Live Photo/metadata/restore/continuation gaps. Do not mark M1 passed from compilation alone.

Primary API references: https://developer.apple.com/documentation/photos/phassetresourcemanager and https://developer.apple.com/documentation/photos/phassetresource . Underlying resource bytes are the preservation target; binary PhotoKit reimport is a later separate check.

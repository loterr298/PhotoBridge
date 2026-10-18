# Verified USB return and new-album restore

> Use executing-plans inline. The user already authorized implementation and asked not to pause for design approval.

**Goal:** Return a committed original backup via USB, import every supported resource into a new album, and independently re-export bytes and read order before reporting success.

**Architecture:** Mac validates a local committed backup before creating a fresh RestoreInbox UUID. Each uploaded resource is read back and hashed; an inbox request commits last. iPhone preflights the entire manifest, resource files and PhotoKit resource combinations before allowing the user to create a new album. Sequential PhotoKit changes append each complete resource group at its ordinal. A permanent one-attempt marker prevents ambiguous crash replay. A local mapping/report records source-to-created IDs, errors, and re-export comparison.

**Tech Stack:** Existing Swift core / SwiftUI / PhotoKit, Python standard library and external USB-only AFC.

**Spec:** PROJECT_PROMPT.md sections 2–4, docs/TECHNICAL_ARCHITECTURE.md. This is the first restore slice; robust resumption and high-volume optimization remain subsequent tasks.

## Constraints and review focus

- New album only; no removal, existing-album mutation, source deletion or overwrite. shouldMoveFile=false for every resource.
- Preserve resource bytes, filename, UTI and type. Reject unsupported complete groups before any Photos write; never omit adjustment/unknown resources to force success.
- No logical five-second dates in Photos. Retain the original library creation date rather than Mac auxiliary times.
- Hash and size checks at both USB endpoints; reject symlink files or ancestors and malformed manifests.
- A one-attempt marker precedes any Photos transaction. Failed/ambiguous imports remain visible and are not retried automatically.
- Re-exported complete resource multiset must match type/name/UTI/size/hash; added, missing or changed resources fail verification. nil-options album order must match new-ID mapping.
- Machine verification does not certify manual Photos display or Live playback; both remain manual NOT_RUN until observed.
- Private media, identifiers and reports stay local; only synthetic tests and sanitized evidence go to GitHub.

## Tasks

1. Shared restore safety: tests first for real resource integrity, symlink rejection, one-attempt claim, complete resource multiset and strict mapped order. Run CoreChecks red, implement Sources/PhotoBridgeCore/RestoreSafety.swift, then green and commit.
2. Mac USB return: tests first with real local fixture files and a filesystem-backed external AFC boundary. Reject corrupt/noncommitted backups before any remote write; preserve all unknown roles; verify remote reads; never publish ready request on corruption/failure; refuse reused UUID. Implement scripts/album_restore.py. Run complete Python suite and commit.
3. Native restore: apps/iOS/RestoreView.swift shows inbox/preflight counts and destination preview. User explicitly starts a new album. Validate every group with supportsAssetResourceTypes, sequentially add all resources, insert placeholders at exact positions, journal each mapping. Re-export every new asset and compare resource sets plus final album order. Stop at transaction boundaries and retain all data on failure.
4. Version 0.3.0/build4, unchanged bundle ID. Cloud compile all Swift/iOS/Intel and Python tests, fix actual failures, download/verify payload, update Mac app and send real Live Photo backup into fresh inbox. Deliver unsigned IPA for the user's existing signing flow. Device Photos import/playback/order acceptance stays NOT_RUN until installed and exercised.

## Primary API checks

- https://developer.apple.com/documentation/photos/phassetcreationrequest
- https://developer.apple.com/documentation/photos/phassetcreationrequest/supportsassetresourcetypes(_:)
- https://developer.apple.com/documentation/photos/phassetresourcecreationoptions/shouldmovefile
- https://developer.apple.com/documentation/photos/phassetcollectionchangerequest/insertassets(_:at:)

Resource-type preflight validates combinations, not bytes; actual import and post-import resource verification remain mandatory. No edits or deletions are used to conceal a failed import.


## Execution state

Software tasks 1–4 implemented and committed (99df580, b0ad5ba); review fix binds exact manifest bytes and rejects stale preview. Local 32 CoreChecks / 18 Python tests pass. Final cloud run #13 SUCCESS with 4 XCTest / 32 CoreChecks / 18 Python, iOS arm64 and Intel App. Package CRC, checksums, versions and bundled transfer source verified; Mac updated after backup. Actual USB return of 3 HEIC/MOV groups verified. User has received 0.3.0 IPA and device procedure; phone preflight, Photos resource/order re-read and Live playback remain NOT_RUN until real records arrive. No completion assertion for the full project or recovery/bulk work.

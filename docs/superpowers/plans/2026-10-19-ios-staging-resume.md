# iPhone resource staging recovery

> Execute inline, tests first, under the user's standing instruction to implement and verify without another approval pause. Reuse the current clean feature checkout. One independent code review before delivery.

**Goal:** Recover a stopped/interrupted PhotoKit resource export without changing the source library or old staging session.

**Architecture:** Freeze album order, per-asset creation/modification dates, dimensions/media fields and the complete ordered resource catalog in a versioned plan. Write a bound checkpoint after each fully hashed, committed resource. Recovery first checks unchanged PhotoKit state and every checkpoint's actual bytes, then uses a new UUID session: copy verified resources, re-read incomplete resources in full, publish the final manifest last. Old sessions and partials remain read-only. No PhotoKit byte-offset claim, automatic retry or Photos write.

**Tech:** Existing Swift/Foundation/CryptoKit/PhotoKit; native Form controls. No dependencies. Source dates in the internal plan use lossless Foundation Codable dates, separately from the existing ISO8601 exchange manifest.

**Spec:** PROJECT_PROMPT.md sections 2–4,8–10; docs/TECHNICAL_ARCHITECTURE.md consistency and recovery; docs/PRESERVATION_POLICY.md.

**Review focus:** changed/reordered source or resource catalog; subsecond modification dates; corrupt/missing/foreign checkpoint or resource/symlink; crash after media commit but before checkpoint; stop/permission loss while a write is in flight; completed sessions and nested recovery paths; correct counters and final-manifest publication.

- [x] Write failing executable Swift checks for exact plan roundtrip/current-source binding; per-resource reuse after an incomplete second resource; original directory bytes/mtime untouched; corruption/changed dates/order/catalog/foreign checkpoints/symlink/completed/nested refusal.
- [x] Implement minimal StagingResume core and run checks; preserve old incomplete resources and repeat them rather than appending PhotoKit data.
- [x] Integrate OriginalExportService checkpoints and new-session recovery, source checks before/after resource work and final publish. Add selection of eligible unfinished sessions, actual reuse counts and explicit partial-resource restart wording. Existing legacy sessions without plans cannot resume.
- [x] Run full local core/Python/build checks, independent review, fix important findings with regression evidence; commit and update IMPLEMENTATION_STATUS.
- [ ] Build 0.3.5/build9 in GitHub Actions; verify artifacts and bundled code; deliver phone update for a real stop/relaunch/recovery test. Until that new binary runs on the phone, device staging recovery remains NOT_RUN.

Primary API: https://developer.apple.com/documentation/photos/phassetresourcemanager — writeData exports a complete resource to a file; no byte-offset parameter in the public interface used here.

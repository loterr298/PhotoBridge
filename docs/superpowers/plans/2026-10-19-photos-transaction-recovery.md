# Photos transaction recovery

> Execute inline, tests first, in the current feature checkout under the user's standing instruction to implement and verify directly. Keep originals and legacy failed sessions untouched. One independent review before delivery.

**Goal:** Resume a new-protocol Photos restore without creating another album or duplicate copies of already recorded assets.

**Architecture:** Immutable plan binds exact manifest/request hashes, inbox/attempt UUIDs, source identities, title and the original timestamp permission. An exclusive native file lock serializes writers. Before each Photos transaction, commit an intent; inside its changes block, commit the placeholder identity before returning. Persistence failure cannot cancel a PhotoKit request: retain the intent, stop, and never automatically replay. Resume accepts only explicit recorded identities that are actually visible in the recorded album and whose complete resources are independently reread and verified. Missing identity/object, changed inputs/policy/album/order/asset version or corrupt records refuse recovery. Legacy attempts remain blocked.

**Public API basis:** Apple PHObjectPlaceholder preserves its localIdentifier after creation; absence before a completion is not proof of transaction rollback. No private Photos APIs or library searches by filename/date/title.

**Data:** append-only restore-recovery plan/intent/placeholder/verified records; fresh verification-attempt and run directories preserve earlier files. Latest progress remains a mirror, not authority. Final report is exclusively and atomically published after full resource/order revalidation. Metadata writes use unique temporary files so interrupted scratch files never need overwriting.

**Scope:** iOS16+, Intel macOS, existing strict resource policy and default-off authorized adjustmentTimestamp option, shouldMoveFile=false, no source metadata edits. Fixed per-transaction album-prefix checks favor safety; scale/performance testing remains separate. Resource-reading and Photos-transaction interruption tests are distinct.

- [x] Add RED native checks for crash windows, explicit identity adoption, missing placeholders/objects, changed policy/hash, order/membership changes, corrupt/missing event, duplicate IDs, version changes, locks, symlinks and extreme indices.
- [x] Implement and test pure recovery model plus immutable native ledger/atomic metadata; never infer a failed transaction from an absent asset.
- [x] Integrate new/restored paths with per-run readback, immutable mappings, actual counters, final report and an explicit one-asset post-commit/pre-verification diagnostic stop.
- [ ] Run full local suites and Intel build, independent review and regression fixes, commit/status update; build0.3.6/build10 in Actions and verify artifacts.
- [ ] After user installs signed iPhone update, new3-Live inbox: stop after1 committed copy before verification, capture ledger, user restart, resume; audit6 resources and same first created ID with only2 further creations. Device result stays NOT_RUN until actual evidence. User checks playback/order separately.

Source: https://developer.apple.com/documentation/photos/phobjectplaceholder . Power-loss durability and arbitrary destruction of App journal files are not claimed; missing/corrupt/ambiguous durable intent data fail closed.

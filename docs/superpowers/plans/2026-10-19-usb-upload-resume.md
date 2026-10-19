# Verified USB upload continuation

> Execute inline, tests first, as explicitly requested in PROJECT_PROMPT.md. No additional design approval pause.

**Goal:** Continue a not-yet-published Mac→iPhone backup upload without replacing completed resources or replaying Photos writes.

**Architecture:** A new resumable uploader reuses local committed-backup validation. Each fresh inbox has an immutable owner document binding its UUID, nonce and exact manifest digest. An exclusive AFC/flock on that document serializes cooperating uploaders and is released with the connection. Resume requires the bound local journal and an identical owner document. Published restore requests and attempted Photos imports are refused. Existing complete files are read back and verified, never rewritten. Existing .part bytes must match the local prefix; open without truncation, verify EOF, then append the remainder. Full USB readback/hash precedes rename; restore-request.json is published last. No original photos, existing albums or already imported copies are touched.

**Tech:** Existing Python standard library + separately installed libimobiledevice. Public AFC get_file_info, file_lock, seek/tell and RW (non-truncating) APIs. If locking or file-type metadata is unavailable, fail closed.

**Files:** scripts/usb_probe.py (bounded primitives), scripts/album_restore.py (shared local validation), scripts/upload_resume.py (state machine), tests/test_upload_resume.py and manual hardware harness. Existing default uploader remains supported.

- [x] RED tests: interrupted upload with one complete resource and one partial; verify resumed offset/byte accounting, complete-file preservation and ready-last publication.
- [x] RED refusal tests: changed local source/manifest, wrong owner, corrupt/oversized partial, symlink, concurrent lock, published request/Photos marker. Refusal must have no resource writes.
- [x] Add AFC regular-file metadata, exclusive lock and non-truncating .part append. Verify both primary and close error preservation.
- [x] Implement bound uploader; reuse existing manifest and full-byte checks. Record actual uploaded suffix bytes separately from USB verification reads.
- [x] Run complete tests, independent review and actual USB controlled writer interruption/reconnect/append/readback. Physical upload cable-loss remains a separate manual test, never inferred from the controlled one.
- [ ] Update implementation status, commit code, build Intel/cloud artifacts and report exact limits. No iPhone update is necessary to test App Documents uploading; new phone diagnostic build is independently checked.

Primary API reference: https://libimobiledevice.org/docs/libimobiledevice/latest/afc_8h.html . RW is O_RDWR|O_CREAT, not a truncating mode; append is restricted to owned RestoreInbox .part files. The user explicitly authorized USB transfers and asks not to delete/overwrite originals; appending verified temporary upload data is limited to these new sessions.

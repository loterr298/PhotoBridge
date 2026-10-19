# Safe USB download continuation

> Execute inline with tests first; within the user's existing USB recovery request.

**Goal:** Continue an interrupted Mac download using verified completed resources and AFC byte offsets, preserving the failed session as evidence.

**Architecture:** `album_resume.py` wraps the existing strict downloader. A new destination directory receives the resumed backup; the previous directory is read-only. The current phone manifest must exactly match the prior progress manifest SHA-256. Previously completed files are reused locally only after full hash verification. Partial bytes are copied to the new session, then AFC seeks to that byte offset. The existing full-resource and post-attribute checks certify the assembled bytes before commit.

**Constraints:** No old-file overwrite/deletion; no Photos writes; no relaxed media/adjustment comparisons. Reject symlinks, changed manifests, oversized/corrupt local resources and invalid offsets. Invalid partial prefixes cannot pass the final full hash. Only actual fetched resource bytes count as USB bytes. This first slice does not resume iOS staging, uploads or ambiguous Photos transactions.

**Files:** scripts/album_resume.py, scripts/usb_probe.py, tests/test_album_resume.py.

1. Add filesystem-backed boundary tests for interruption after one completed file and a partial prefix; assert exact remaining AFC offset, old bytes unchanged and complete final hashes. Observe missing-module RED.
2. Add tests for changed manifest rejection before creating output, corrupt prefix refusal, symlink rejection and fully committed source reuse without resource USB reads.
3. Add bounded optional `offset=0` to AFC.read using documented afc_file_seek(client, handle, int64_t, SEEK_SET). Existing callers remain unchanged.
4. Implement new-directory continuation through the existing downloader, with exact manifest binding and full hash checks. Run complete Python/Core checks and independent review; commit.
5. Run a real USB controlled receiver interruption, close/reopen AFC, resume from the actual partial offset and independently verify all output hashes. Report it as controlled interruption, not physical cable loss. Cloud build updated Intel tooling; existing phone 0.3.0 remains usable.

Primary protocol API: https://libimobiledevice.org/docs/libimobiledevice/latest/afc_8h.html (afc_file_seek). External library remains separately installed, not bundled.

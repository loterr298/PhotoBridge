# 0.3.17 user-flow check

Scope: task UI refinement and bounded waiting. Historical 20-item/Live/USB evidence is not reused as a new device pass.

| Flow | Expected | Current evidence |
| --- | --- | --- |
| Mac opens without phone | One direction/task; clear connect action; no fake device or permanent spinner | PASS actual locally built 0.3.17 launch |
| Two Mac direction areas | Both shown simultaneously, one primary action each; no selector | User steering implemented; native confirmation pending |
| Choose/Cancel saved folder | Native chooser can cancel without changing selected backup | PASS actual locally built 0.3.17 launch |
| Open existing saved album | Actual ordered grid, bounded thumbnails, dismiss works | PASS opened existing 2707-photo album, scrolled to later ordinals, closed; no media writes |
| Stuck control process | Deadline returns failure and releases busy state | Real subprocess test PASS; no real AFC stall simulated |
| Large subprocess output | Drain without holding all output in memory | 6MiB stdout/stderr, 65536-byte retained test PASS |
| Pause blocked file helper | Grace window then termination; existing media untouched | Real subprocess test PASS; new physical USB pause NOT_RUN |
| Malformed request queue | Later valid requests remain reachable | Eight bad requests then valid request PASS |
| Phone companion | Permission check alone does not read album catalog | Source reviewed; simulator pending |
| Phone receive | Find published backups; check before explicit Photos import | Simulator empty-state test pending; real Photos writes NOT_RUN |
| Photo info | Picker opens/cancels; edits remain separate | Simulator test pending |

Design review against the eight Apple-design principles: purpose (two explicit directions), agency (pause/resume/native cancel retained), responsibility (media immutable/default timestamps unchanged), familiarity (native tabs/pickers/dialogs), flexibility (semantic text, adaptive palette, dynamic iOS type; device accessibility NOT_RUN), simplicity (one active task/primary action), craft (bounded actual visual checks pending), delight (quiet hierarchy; no decorative animation). The local apple-design catalog contains no referenced HIG reference files, so no current official pixel-spec conformance is asserted.

Known limits: genuine iPhone/USB not available during local check; full per-asset recovery-prefix validation remains quadratic, large manifests retain the 64MiB bound, and actual phone staging capacity remains required. Absolute no-hang/no-crash guarantees cannot be established by source tests or empty simulator UI checks.

First native visual pass found three small issues: default Mac canvas was too gray, direction label duplicated the segmented choices, and disclosure state carried into the other task. Fixed together with a lighter adaptive canvas, hidden redundant label (VoiceOver label retained), and collapsing options when switching direction. Final confirmation pending. Native album screenshots containing user photos stay local and are not uploaded.

Latest explicit user steering replaces the direction selector with two independent, simultaneously visible task regions. Previously recorded direction-switch observations are historical; final two-region native check is pending.

2026-10-27 final two-region native check: both export and import headers/buttons observed together, no segmented/radio direction control, both optional disclosures initially closed, shared connection action visible. Installed locally built 0.3.17/build21 with strict signature; screenshot build/PhotoBridge-0.3.17-CalmUI/mac-two-areas.png. Hardware USB/Photos transfer remains NOT_RUN in this check.

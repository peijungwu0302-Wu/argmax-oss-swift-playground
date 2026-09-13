# LectureTranscriber v1.8.2 Implementation Plan

> **For Codex:** Execute sequentially with red-green-refactor tests and build checkpoints. Preserve all existing user data and identifiers.

**Goal:** Ship v1.8.2 build 15 with caption-first PiP, a complete live transcript route, corrected and coalesced Live Activity updates, and system-native Apple Speech/Translation defaults.

**Architecture:** Extend `LectureController`, `CaptionFeed`, `CaptionPiP`, the existing Translation worker, and the single Widget extension. Add route-only `AppNavigationState` and presentation-only `PiPPresentationSettings`. Reuse existing transcript models and rows.

**Tech Stack:** Swift 5, SwiftUI, AVKit sample-buffer PiP, ActivityKit/WidgetKit, Speech, Translation, XcodeGen, GitHub Actions, SideStore manifest.

### Task 1: Baseline and release metadata

- Update Package.swift, XcodeGen project, Widget plist, IPA validation, workflow artifact metadata, and release notes to 1.8.2 build 15.
- Add validation that the main and widget identifiers and single-extension IPA shape remain exact.
- Run metadata/package validation and a cloud build checkpoint.

### Task 2: Live Activity timer and lifecycle

- Add failing logic tests for elapsed reference-date conversion, pause/resume continuity, update classification, throttling, and revision pairing.
- Extract pure timing/update policy helpers where needed.
- Fix pause so it does not end the activity; make stop explicitly end it.
- Render elapsed time with `countsDown: false`, improve header/body/footer, and add `widgetURL`.
- Run LogicTests and a cloud build checkpoint.

### Task 3: Caption-first navigation and full transcript

- Add failing route tests for active lecture resolution and deep-link fallback.
- Add route-only `AppNavigationState` and `.onOpenURL` handling.
- Add or extract a live transcript view using controller lines, saved line translations, timestamps, a separate current draft, bounded lazy rendering, Follow Live, and Return to Live.
- Replace compact/full mode entry with Full Transcript and PiP actions.
- Run navigation/transcript tests and a cloud build checkpoint.

### Task 4: PiP auto-start and presentation settings

- Add failing tests for missing-key defaults, existing-key preservation, reset, clamping, adaptive layout, and bounded readiness retries.
- Add `PiPPresentationSettings` for the seven presentation preferences only.
- Make recording trigger bounded auto-start, retain a manual `pip.enter` fallback, and implement production sample preview.
- Apply font scale, alignment, vertical position, gap, mode, and ratio-specific layout to the renderer. Redraw active PiP on presentation changes.
- Route PiP restore to the full active transcript.
- Run PiP logic tests and a cloud build checkpoint.

### Task 5: Apple system defaults and recognition UX

- Add failing preference/default tests and resource-state tests without mocking framework behavior.
- Default Apple Speech, Apple Translation, Traditional Chinese target, and live translation only for absent keys.
- Surface real Speech asset progress when available, otherwise indeterminate preparation; continue Start automatically.
- Separate System Resources from Downloadable App Models and show the selected Apple locale.
- Present SenseVoice according to its actual auto/multilingual implementation and retain existing engines.
- Run controller/resource tests and a cloud build checkpoint.

### Task 6: Regression, distribution, and release

- Run LogicTests, LaunchTests, build, model-engine compilation, IPA package validation, manifest validation, and public asset verification.
- Verify the archive contains only `LectureTranscriber.app/PlugIns/LectureTranscriberWidget.appex` and both bundle identifiers are unchanged.
- Commit, push `release/v1.8.2`, create/upload release with the existing SideStore pipeline, redownload/unzip the IPA, update manifests, and push distribution metadata.
- Record real-device-only tests as `NOT TESTED` until performed on the user's devices.

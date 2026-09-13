# LectureTranscriber v1.8.2 Design

## Goal

Make PiP the default cross-app live-caption surface, keep the main app as the complete finalized transcript, and make the existing Live Activity a low-frequency status and latest-caption surface. Preserve the existing recording, transcript, translation, model, and single-widget architecture.

## State Ownership

- `LectureController` continues to own recording, recognition, finalized transcript lines, translation coordination, and `CaptionFeed` updates.
- `CaptionFeed` remains the single source of current draft caption content.
- `AppNavigationState` owns routes only: home, active lecture, and full transcript. PiP restore and Live Activity URLs only request routes.
- `PiPPresentationSettings` owns only persisted PiP presentation preferences. Missing keys receive v1.8.2 defaults; existing preferences remain unchanged.
- `CaptionPiP` renders `CaptionFeed` using `PiPPresentationSettings`; it does not own transcript history or navigation.
- `LiveActivityCoordinator` owns ActivityKit timing, throttling, revision matching, and lifecycle. `ContentView` does not perform ActivityKit updates.

## Caption Surfaces

PiP consumes the latest draft original and draft translation for minimum delay. It displays only the current short caption. Starting a recording schedules a bounded readiness attempt when auto-start is enabled. Failure leaves recording, recognition, and translation running and exposes the manual `pip.enter` action.

The main transcript reads the controller's existing finalized `TranscriptLine` collection and its existing saved translations. A separate current-draft block may be shown at the bottom. The view reuses existing timestamp and transcript row concepts and never creates a second transcript store. Follow Live stops when the user scrolls upward and resumes only through Return to Live.

The Live Activity uses meaningful partials at a coalesced interval, and pushes final original and final translation changes immediately. Revision identifiers prevent pairing a newer original with an older translation. Timestamps are monotonic elapsed values converted to a reference `Date`; the widget renders elapsed time with `countsDown: false` and uses the system timer view without per-second activity updates.

## PiP Presentation

Defaults are auto-start on, 5:1, 100%, bilingual, left-aligned, vertically centered, and standard original/translation gap. Font scale is stored as 0.75 through 1.50. Base font, safe padding, wrapping, line limits, and vertical padding adapt to the actual render size and 3:1, 5:1, or 6:1 ratio. Changes redraw an active PiP immediately. Ratio changes rebuild and restart PiP only if the public sample-buffer geometry cannot update reliably while active. No private API controls PiP position.

When no recording is active, real PiP preview uses the production renderer with normal sample copy. During recording it continues to display live captions. Restore delegates route to the active full transcript and then complete restoration.

## System Resource Defaults

Apple Speech remains the default recognition engine and one selected locale is always explicit. The existing public Speech asset installation request is invoked from the user-triggered recording flow. Any available `Progress` is reported; otherwise UI shows an indeterminate preparing state. System Speech and Translation resources are presented separately from downloadable app models.

Live Translation defaults to on and Apple Translation to Traditional Chinese only when the corresponding preference keys do not yet exist. The existing Translation worker and official session preparation flow remain in place, and successful preparation continues the pending recording/translation flow without an off/on toggle.

SenseVoice remains the existing multilingual and mixed-language option. The UI exposes auto language only if the current engine implementation really supports it. Qwen3-ASR is deferred.

## Data, Packaging, and Verification

The update changes no storage locations or identifiers and performs no migration that deletes or moves models, recordings, lectures, transcript versions, translations, bookmarks, speaker data, or Smart Notes. The IPA contains one app and the existing widget extension only. Build and simulator checks are reported separately from real-device checks; device-only scenarios remain `NOT TESTED` until the user performs them.

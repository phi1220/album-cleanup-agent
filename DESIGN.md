---
version: alpha
name: ByePhoto for macOS
description: A quiet contact sheet for model-assisted review and explicit, user-confirmed Photos library cleanup.
colors:
  primary: "#3859B8"
  marker: "#BA7D29"
  keep: "#1B6E38"
  delete: "#B81F1A"
typography:
  sans:
    fontFamily: "SF Pro, system-ui, sans-serif"
  mono:
    fontFamily: "SF Mono, ui-monospace, monospace"
rounded:
  card: "12pt"
spacing:
  compact: "8pt"
  standard: "18pt"
  section: "32pt"
components:
  photoCard:
    cornerRadius: "12pt"
    metadataRule: "3pt ochre edge"
---

# ByePhoto for macOS Design System

## Overview

### Creative North Star

Treat the library as a photographer's contact sheet: photographs carry the color and detail, while the surrounding interface behaves like a calm inspection bench. The small ochre registration edge beside each photo's metadata is the one repeated signature.

### Product context and register

- **Audience and primary job:** People reviewing their own photo library and deciding what to keep, with actual model advice and deliberate deletion review.
- **Target market(s) and evidence:** Mac-first, with Chinese UI copy for the current user context; no broader market assumption is encoded.
- **Locale(s) and language policy:** Simplified Chinese and English interfaces. A native language picker offers Follow System, 简体中文 and English; dates follow the selected language while retaining the local timezone. Existing user/model content stays in its original language.
- **Usage scene:** A resizable desktop window for deliberate, visual review rather than rapid bulk operations.
- **Register:** Product.
- **Memorable signature:** A narrow ochre registration edge next to each photo's date and pixel dimensions.
- **Restraint:** Keep controls native and let image content dominate the grid.
- **Anti-references:** No dashboard cards, analytics, gradients, or decorative film-strip chrome; those compete with the photos and suggest analysis that has not happened.
- **Token ownership/runtime mapping:** This file defines intent. `mac/AlbumCleanupMac.swift` maps accent, marker, system semantic surfaces/text/separators, and card radius in `DesignTokens`. Keep those mappings together when tokens change.

## Colors

The indigo `primary` is the native action and keyboard-focus accent. The ochre `marker` marks each contact-sheet entry without signaling a keep/delete decision. Runtime uses AppKit semantic colors for canvas, surface, text, and separators so macOS appearance remains legible. Never use the ochre marker as a recommendation status.

## Typography

Use the system San Francisco family for interface copy and SF Mono for dates, indices, and pixel dimensions. Keep Chinese labels in native system fonts so macOS selects the correct CJK fallback. Use concise native Chinese and English labels, with dates formatted for the active interface locale. Allow English help text to wrap without clipping controls.

## Layout

One quiet title row leads into a single scrollable, adaptive contact sheet. Keep a minimum 176-point tile width, 18-point gutters, and 32-point outer inset. Thumbnails are square to make scanning consistent; important photo decisions must later show the full image in context before confirmation.

## Elevation & Depth

Use native window and control surfaces. Separate the status note with a hairline divider. Avoid shadows and floating panels; there is only one content layer.

## Shapes

Use a 12-point photo radius and standard native control shapes. Keep metadata edges and separators crisp; reserve rounded shapes for thumbnails and native controls.

## Components

### Foundational visual states

Permission, loading, empty, and thumbnail-unavailable states use text and system symbols, not color alone. The app requests library access only after the user chooses the permission action. Visible thumbnails, review previews and analysis use the same cancellable PhotoKit reader with network access enabled. Show actual iCloud progress, then the image; show a concise failure and native retry control when unavailable. PhotoKit manages the needed resource download, while model uploads stay at 768px redrawn JPEG. Grid scrolling cancels offscreen view tasks; no global library sync setting is changed.

### Buttons and actions

Use standard SwiftUI buttons with native focus and keyboard behavior. Refresh and model settings are secondary actions; analysis of all unprocessed photos is primary. Keep deletion review separate at the trailing end of the action row. Only the final explicitly acknowledged delete button uses prominent danger presentation. High-confidence model cleanup goes into the application staging queue; system deletion requires the user’s delete-all action.

### Navigation and data display

The app has three tabs and an adaptive photo grid, bounded to one round of at most 100 unprocessed assets, selected newest-first after excluding completed advice. Each cell exposes its date and pixel dimensions to accessibility. The order index reflects the current newest-first result, not a permanent asset identifier. One analysis action processes all unprocessed assets in internal batches; users do not select batches. Review sheets show uncropped, aspect-fit previews and side-by-side model keep references when supplied. Labels distinguish model advice from the owner's decision.

The fixed status row reports completed photos and actual batch stages. Completed keep/cleanup assets leave the pending grid. Persist pending IDs, retain unfinished images and top up to 100 from accessible unanalyzed assets; uncertain advice stays in its own tab and never blocks loading more. Loading is local and does not start a paid request. Three native segmented tabs separate library, uncertain photos, and the pending-deletion queue. The primary analysis button acts on all unprocessed photos; clear keeps and high-confidence cleanup decisions route automatically. Only uncertain photos automatically open the review sheet. The queue is a staging area; assets stay in Photos until the user presses the explicit delete-all action.

### Forms and overlays

Native SwiftUI owns settings, segmented controls, scrollbars and review sheets. Uncertainty review has prominent labeled red Delete and green Keep actions, an optional reason, progress count, and automatic advancement. Command-D and Command-K are explicit shortcuts; typing in the reason must never activate an unmodified delete shortcut. A skip teaches nothing. Queue restore supports multiselection and an optional reason; final delete-all has an adjacent consequence statement and optional reason. The user's explicit one-click delete-all requirement replaces the old redundant acknowledgement checkbox; PhotoKit may show its own system confirmation.

### Workflow and canonical ownership

| Capability | Owner | Source / verification |
|---|---|---|
| Routing, queue and feedback | `ReviewMemory`, `PhotoLibraryModel` | `UX-CONTRACT.md`; `mac/tests/ReviewChecks.swift` |
| API/preview | `VisionModel`, `PhotoImages` | HTTPS only, 768px redrawn JPEG, 120s image/download bound, cancellable requests; tests/build |
| Review and restoration | `PhotoReviewSheet`, `LibraryScreen` | Red/green labeled native actions and optional reason; persistence checks |
| Persistence and prompt | `ReviewMemory` | Atomic local records, feedback version, source-backed compressed rules covering all distinct latest owner feedback, no automatic-model feedback; roundtrip/correction checks |
| Actual deletion | `validateDeletion` and PhotoKit | Snapshot/keeper/permission validation, no auto retry, owner feedback only on success; boundary tests |

The preference sheet shows compact conditions, exceptions and source counts before an expandable complete evidence history. A separate count explains that reasonless choices are retained as immediate local examples; do not imply that these are inferred category rules. Photo analysis starts directly using existing memory; only the explicit preference update action runs compression/evolution. Compression uses short wire source IDs, bounded text batches and atomic per-batch checkpoints. Learning progress/error and sample insufficiency stay inline; a reserved one-line slot shows elapsed model response waiting time with native TimelineView, without fabricated completion percentages; update, cancel and rollback are native controls using the shared model busy state. Harness versions show real held-out metrics and cannot affect existing review decisions.

Keychain remains the sole key store. Reviews, owner decisions and feedback survive relaunch in Application Support. Model advice alone never enters owner feedback. Reasonless user actions remain examples, not broad categorical rules. Clear memory removes feedback context, not existing queue decisions. Product flows and behavioral boundaries are recorded in `UX-CONTRACT.md`.

### Iconography

Use SF Symbols at native weights. Every symbol-only state has adjacent text or an accessibility label. Cloud loading uses native progress plus a percentage; retry is a separate labeled button outside the photo-opening button, never a nested button.

### Motion

No custom motion. Preserve standard macOS focus and button feedback.

### Content and data visualization

Keep and delete use `DesignTokens.keep` / `DesignTokens.delete`, mapped to #1B6E38 and #B81F1A for legible white labels, always with labels and icons. State exactly what the app has read. Do not present local heuristics as model analysis or a thumbnail as proof of original quality. Dates and dimensions are evidence labels, not scores.

## Do's and Don'ts

- **Do:** Keep permission and iCloud limitations visible beside the affected content.
- **Do:** Keep future keep/cleanup states separate from image quality measurements.
- **Don't:** Infer a cleanup recommendation from the grid or from missing metadata.
- **Don't:** imply Photos assets have ordinary filesystem paths or that a model recommendation is deletion authorization.
- **Don't:** claim the feedback prompt trains model weights or demonstrates measured self-improvement.

Language ownership: `mac/Localization.swift` resolves the persisted language and native `.lproj` resources in `mac/Resources/`. All app-owned labels, progress, errors and accessibility copy share this owner. SwiftUI native pickers own popup geometry and keyboard behavior. Language changes preserve the window model, review state and entered reasons; system-owned menus/dialogs follow macOS language settings. Existing saved system reports are translated for display without rewriting feedback or records.

Brand and English copy: use **ByePhoto** in both locales, including app bundle/display names and window titles. The default README is English, with a separate README.zh-CN.md for Chinese. English documentation uses English control names and ASCII launch paths. In English mode the language picker reads Simplified Chinese; owned UI and examples must not leak Chinese copy. User-authored and model-history text retains its original language. English counters use neutral labels to avoid singular/plural errors.

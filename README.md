# ByePhoto

English · [Simplified Chinese](README.zh-CN.md)

ByePhoto helps you review your photo library with a vision model. It handles clear keep and cleanup decisions, asks for your input when uncertain, and leaves final deletion to you. The project includes a native macOS app and a separate Python CLI, each with its own local history and preferences.

## macOS app

Requires macOS 15+ and Xcode or compatible Swift Command Line Tools. Python and Reef are not required.

```bash
./build-mac-app.sh
open ".build/ByePhoto.app"
```

If the default SDK does not match your compiler, select a compatible SDK installed on your machine. For example:

```bash
export MACOS_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
./build-mac-app.sh
./test-mac-review.sh
```

### Language settings

In Model Settings → Interface Language, choose Follow System, Simplified Chinese or English. The interface updates immediately and remembers your choice. Dates follow the interface locale; subsequent model reasons, preference summaries and policy guidance use the selected language. Existing user reasons, model explanations and preference content retain their original language. System menus and permission prompts follow macOS or its per-app language setting.

### Workflow

1. Grant access to Apple Photos. In **Model Settings**, enter an HTTPS endpoint that supports the OpenAI API format, a vision model ID and an API key, or import an existing `.env` file. The key is stored in the local Keychain.
2. Click **Analyze All** to process up to 100 unanalyzed photos in the current round. Balanced internal batches contain at most 12 photos, with up to two batches running concurrently. Batch boundaries try to keep bursts and closely timed shots together. You can cancel; completed results are saved and failed items can be retried.
3. Photos marked Keep leave the pending list automatically. Cleanup suggestions with model-reported confidence of at least 0.90 enter **Pending Deletion**; cases requiring your judgment open for review. Favorites and the retained photos in similar-photo comparisons are protected. Confidence is not a statistically calibrated accuracy measure.
4. The review window shows uncropped photos and the model’s reasons. The red **Delete** button adds a photo to Pending Deletion; the green **Keep** button keeps it. Use ⌘D / ⌘K and optionally provide a reason. **Review Later** records no feedback.
5. In Pending Deletion, select photos and choose **Restore Selected**, or use **Delete All**. Restore only removes photos from the app’s queue. Delete All submits a PhotoKit deletion request, which may prompt for system confirmation. Cancellation or failure adds no deletion feedback and does not trigger an automatic retry.

After refresh or analysis, unfinished photos are retained and new unanalyzed photos fill the round up to 100. Uncertain cases and the deletion queue are separate and do not block new photos. Visible thumbnails, review previews and analysis load photos from iCloud as needed, showing download progress. Each image has a 120-second timeout and can be retried after failure.

System deletion affects the entire library and other devices using iCloud Photos. Recover deleted photos through Recently Deleted in Apple Photos; the app does not empty Recently Deleted.

### Preferences and review policy

Your keep, queue-for-deletion, restore and successful deletion actions are saved locally. Model suggestions do not become user preferences. The latest choice for a photo takes precedence. Reconfirming the same choice without a new reason preserves an earlier reason; choices without reasons remain individual examples.

Summarization and evaluation run only when you click **Update Preferences** in **Preferences**. Photo analysis uses saved preferences and new feedback directly. Summaries retain conditions, exceptions and all source references, while raw feedback remains complete. Each successful batch is saved atomically so interrupted work can resume. Corrections invalidate summaries that cite superseded sources.

Policy updates split photos and known comparison groups into training and held-out validation sets. Training memory produces a candidate prompt supplement; the current and candidate policies are then compared on the same held-out thumbnails. A new version is enabled only if unsafe cleanup does not increase, cleanup recall does not decrease and fewer manual edits are needed. Insufficient evidence or failed validation preserves the current policy. Rollback is supported, and changing the model or endpoint prevents reuse of old guidance.

This is native prompt evolution inspired by Reef’s workflow. It neither invokes the Reef framework nor trains model weights. One held-out replay does not establish long-term gains. Library-wide similarity comparison across batches is not implemented. See [UX-CONTRACT.md](UX-CONTRACT.md) for detailed boundaries.

### Data and privacy

- Review records: `~/Library/Application Support/AlbumCleanup/review-memory.json`. Non-secret model settings use UserDefaults; API keys use Keychain.
- Analysis or an explicit preference update sends redrawn JPEG previews with a maximum dimension of 768px, dates, dimensions, favorite status and feedback/summary text to your configured service. Original image files, GPS/EXIF data and PhotoKit IDs are not included in prompts.
- PhotoKit manages iCloud downloads and caching. The app does not change the system’s optimized storage settings.
- Clear Feedback removes raw feedback, summaries and learned review policies while preserving existing keep/cleanup decisions.

## Python CLI

Requires Python 3.11+. Pillow is the only dependency. The CLI scans ordinary photo directories and exports reviewed cleanup plans; it does not move or delete original photos.

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python album_agent.py scan /absolute/path/to/photos
python album_agent.py groups --all
python album_agent.py agent
python album_agent.py export
```

On Windows, run the corresponding commands with `.venv\Scripts\python.exe`. Use `python album_agent.py --help` to list subcommands. Use a separate state directory for each album: `python album_agent.py --state /path/to/state scan /path/to/photos`. The top-level `--state` option must precede the subcommand.

### Scanning and review

Supports JPEG, PNG, WebP, BMP and TIFF. SHA-256 identifies exact duplicates; capture times and perceptual hashes identify bursts. When timestamps are missing, aspect ratio, perceptual hash and low-resolution color samples help match near-identical copies. Grouping and blur estimates are local evidence, not model-based content judgments.

```bash
python album_agent.py show GROUP_ID
python album_agent.py review GROUP_ID --keep 1,3 --uncertain 2
python album_agent.py split GROUP_ID "1,2;3"
```

Replace `GROUP_ID` with an ID from `groups`. `show` creates thumbnail contact sheets. `--keep all` protects the entire group; `--keep none` is allowed only for single photos or screenshots. Duplicate, similar-photo and burst groups must retain at least one photo. Split incorrectly grouped photos before reviewing them. Screenshots are identified by filename. To extract text, install Tesseract separately and use `scan /path/to/photos --ocr tesseract`.

The default offline agent uses a fixed tool loop to read groups, evidence and preferences before proposing a review. Press Enter to skip. Confirmation saves the proposal, tool trace, user decision and policy version. Export writes `.album-agent/cleanup-plan.json` with relative paths, SHA-256 hashes and group IDs, checking that candidate files have not changed. Thumbnails and review state remain local.

### Connecting a vision model

```bash
cp .env.example .env
# Fill in your key, provider's compatible endpoint and vision model ID locally.
python album_agent.py check-model
python album_agent.py agent "Assess image content value and recommend which photos to keep" --group GROUP_ID --allow-remote
```

Configure `QWEN_API_KEY`, `QWEN_BASE_URL` and `QWEN_MODEL`; `DASHSCOPE_API_KEY` is also supported. Environment variables take precedence. `check-model` sends text only. Remote review requires an explicit group of at most 12 photos and sends its thumbnails and OCR text. Custom JSON gateways can use `ALBUM_MODEL_URL` and `ALBUM_MODEL_TOKEN`.

The model may suggest cleanup for individual photos and screenshots, but must explain the visible evidence. Unknown personal usefulness does not imply low value, and thumbnails cannot establish original-image blur or document expiry. Every CLI cleanup candidate still requires user review.

### Preferences and versioning

- Ranking preferences: `review GROUP_ID --keep 1 --scope kind --rank sharp`. Scope can be `kind` or `global`; ranking can be `sharp`, `bright`, `recent` or `resolution`.
- Content preferences: the model proposes a category, observable matching conditions and retention exceptions. These are saved only after review and an explicit choice to apply them to future matching photos. One-off choices, filenames, test cases and model opinions do not automatically become category rules. Inspect with `rules`; roll back with `rollback-rules --yes`.
- Burst policies: explicitly opt in feedback from at least two burst groups with `--use-for-evolution`. Record independent blind labels with `review ... --split validation` and `--split test`. `evolve` proposes and validates a candidate against safety, recall and manual edits. Use `versions` to inspect it, `activate v1 --yes` to enable it, `rollback --yes` to revert and `evaluate --split test` to evaluate. Identical image content cannot cross splits; the operator must ensure capture-event separation.

You can also record an explicit category preference directly:

```bash
python album_agent.py review GROUP_ID --keep none --remember-category "Category" --remember-when "Observable matching conditions" --remember-except "Retention exceptions"
```

Category rules and burst configurations are versioned separately. They do not authorize deletion and do not share state with the native app.

## Development and verification

```bash
./test-mac-review.sh
.venv/bin/python -m unittest -v test_semantic_review.py
```

Native checks use synthetic data and injected callbacks to cover model protocols, deletion protections, persistence, batching, iCloud cancellation/timeouts, preference provenance and held-out evaluation. They do not access the network or modify the real photo library. Optional live checks, `./test-mac-review.sh --check-learning .env` and `--check-vision .env`, send only synthetic feedback or a generated image. Real library interactions still require manual verification.

Workflow logs:

```bash
/usr/bin/log stream --level info --predicate 'subsystem == "com.phi1220.albumcleanup.mac" AND category == "workflow"'
```

| Path | Purpose |
|---|---|
| `mac/AlbumCleanupMac.swift` | Native window, library state and workflow orchestration |
| `mac/ModelReview.swift` | Model settings, Keychain, networking, previews and review windows |
| `mac/ReviewProtocol.swift` | Model protocol, batching, deletion protections and review memory |
| `mac/PreferenceLearning.swift` | Preference summaries, held-out evaluation, policy versions and rollback |
| `mac/Localization.swift` / `mac/Resources/` | Chinese/English text, formatting and language settings |
| `mac/tests/` | Native offline and localization checks |
| `album_agent.py` / `album_core.py` | CLI, scanning/grouping, review, export and policy evaluation |
| `agent_loop.py` / `qwen_api.py` | Fixed tool loop and model adapter |
| `semantic_preferences.py` | Explicit CLI content preferences |
| `DESIGN.md` / `UX-CONTRACT.md` | Visual conventions and behavioral boundaries |

The repository contains only source code, tests, documentation and an empty configuration template. Local user preference records, `.env`, photos, state directories, virtual environments, caches and `.build/` are not committed.

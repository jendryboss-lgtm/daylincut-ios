# ClipForge

ClipForge is a CapCut-style video editor for iPhone. It uses only Apple frameworks: SwiftUI, Observation, AVFoundation, Core Image on Metal, SwiftData, Speech, Vision and StoreKit 2. There are no third-party packages.

- **Requires:** iOS 17+ and Xcode 15.3+ (Xcode 16 recommended).
- **Bundle id:** `com.clipforge.app`

## Build and run

```bash
brew install xcodegen          # only needed if you change project.yml
xcodegen generate              # regenerates ClipForge.xcodeproj from project.yml
open ClipForge.xcodeproj
```

### Command line

```bash
xcodebuild -project ClipForge.xcodeproj -scheme ClipForge \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
xcodebuild -project ClipForge.xcodeproj -scheme ClipForge \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

### Signing

To run on a device, set your team under *Signing & Capabilities*, or set `DEVELOPMENT_TEAM` in `project.yml`.

### StoreKit testing

The `ClipForge` scheme already points at `ClipForge/Resources/ClipForge.storekit`, so purchases work in the simulator without App Store Connect. It defines two products:

| Product | Price | Offer |
| --- | --- | --- |
| `com.clipforge.pro.monthly` | $7.99 | $1.99 for the first month |
| `com.clipforge.pro.yearly` | $49.99 | 1-week free trial |

Use **Debug ▸ StoreKit ▸ Manage Transactions** to refund or expire a purchase.

For production, create the same product IDs in App Store Connect.

## Features

- **Home:** Pro banner, "Extend video" hero, "New video" and "Edit photo" cards, a recents strip, a 12-tool grid and a tab bar with a badge.
- **Media picker:** built on PhotoKit.
  - Shows Recents with All, Videos, Photos and Live tabs.
  - Video tiles show duration badges, and selection is numbered so you can pick several items.
  - A tray holds the selection, with a "Next (n)" button and "Pick for me".
- **Compiling screen:** shows real import and analysis progress.
- **Editor:**
  - **Top bar:** back, the music pill ("Original"), a 1080P menu and Export.
  - **Preview and timeline:** an `AVPlayer` preview over a scrubbable timeline with filmstrips. The playhead has add-ending, add-audio and add-text lanes.
  - **Clip editing:** add, reorder, trim, split, delete, duplicate and change speed.
  - **Looks and text:** filters, adjustments, effects, 11 transitions, and timed text with styles and animations.
  - **Audio:** music, voice-over recording, extracting audio from a clip, and volume and fade controls.
  - **Overlays and AI tools:** picture-in-picture overlays with background removal, auto-captions, an AI clipper, an avatar, generated media, canvas aspect and background, and undo/redo.
- **AutoCut:**
  - 8 styles; Music, Scene or Hybrid mode; length of 10, 15, 30 or 60 s, or a custom length.
  - Aspect ratios 9:16, 16:9, 1:1 or 4:5; sensitivity; slow, medium or fast pacing.
  - It uses a real onset and beat detector on the music, plus scene-change detection on the footage.
- **Export sheet:**
  - Options: AI ultra HD, resolution from 480P to 4K, frame rate from 24 to 60 fps, bitrate, Smart HDR (10-bit HEVC HLG), share to TikTok and TikTok Promote.
  - Shows the estimated file size before rendering.
  - Renders with `AVAssetReader` → `AVAssetWriter`, then saves to Photos. Free users get a watermark.
- **Other tabs:**
  - **Projects:** stored with SwiftData; search, sort, rename, duplicate and delete.
  - **Templates**, **AI Lab** (generate video, story maker, avatar, extend, photo editor, remove background) and **Me** (subscription, appearance, storage).
- **Paywall:** built on StoreKit 2. It gates 4K export, watermark removal, AI ultra HD, Smart HDR and the advanced AI tools.

## Architecture

The app uses MVVM with `@Observable` view models. `AppRouter` owns navigation: tabs, flows and the full-screen editor. All editing works on a value-type `Timeline`, which makes undo a list of snapshots and lets the pure logic be unit-tested.

```
ClipForge/
  App/            entry point, router, root tabs, camera capture
  Models/         Timeline, Clip, Effect/Transition, Caption/Text, ExportSettings, SwiftData Project
  Features/       one folder per screen (Home, MediaPicker, Compiling, Editor + Panels,
                  AutoCut, Export, Paywall, Projects, Templates, AILab, PhotoEditor, Me)
  Services/
    VideoEngine/  TimelineLayout + TimelineEditing (pure), VideoEngine (AVComposition builder),
                  RenderPlan + ClipCompositor (custom AVVideoCompositing on a Metal CIContext),
                  FilterRenderer, TextImageRenderer, FrameVideoWriter, AudioSynth, SegmentationService
    AIService/    AIService protocol + LocalAIService, AutoCutEngine/Arranger, OnsetDetector,
                  SceneChangeDetector, CaptionService (Speech), AIClipper (Vision), SpeechSynth
    ExportService/ AVAssetReader/Writer renderer with SDR fallback when HDR encoding fails
    MediaLibrary/  PhotoKit import/save, app media store, media probing
    ProjectStore/  SwiftData persistence and thumbnails
    Purchases/     StoreKit 2 PurchaseManager (entitlements, paywall routing)
ClipForgeTests/   XCTest: layout, editing, AutoCut, analysis, export settings, and
                  end-to-end VideoEngine composition and export tests
```

### Render pipeline

1. **Layout.** `TimelineLayout` places the clips. A transition overlaps two neighbouring clips, and its length is capped at half of the shorter clip. The result is a list of single and transition segments.
2. **Tracks.** `VideoEngine.build` puts the clips on alternating A/B video and audio tracks, using timescale 600. Overlays and audio items each get their own tracks. It emits one `CompositionInstruction` per segment and an `AVAudioMix` with volume and fades.
3. **Frames.** `ClipCompositor` renders every frame with Core Image on the shared Metal context. Per clip, it applies transform and fit, filter, adjustments, auto-enhance and effects. It then draws transitions, overlays (with an optional Vision person mask), text, captions and the watermark.
4. **Preview.** The editor plays this same composition through `AVPlayer`.
5. **Export.** `ExportService` reads the same composition through `AVAssetReaderVideoCompositionOutput`, so the export matches the preview.

## Adding real cloud AI

Everything generative goes through `AIService` in `Services/AIService/AIService.swift`. The shipped `LocalAIService` is an honest on-device stand-in. It generates procedural animated scenes, builds stories from `StoryPlanner` with `AVSpeechSynthesizer` narration, and draws a stylised lip-synced avatar. It also extends clips with a freeze-frame and Ken Burns effect, and does photo edits with Core Image and Vision. The UI labels these results "On-device".

To connect a real model:

1. **Implement the protocol.** Create `struct RemoteAIService: AIService`, for example `RemoteAIService(endpoint:apiKey:)`. Each method should:
   - upload its inputs, such as frames, prompts or the photo;
   - poll or stream the job;
   - download the result into the media store with `MediaStore.importFile(at:)`;
   - return a `Clip` from `MediaProbe.clip(fileName:kind:)`, or a `Timeline`, `AudioItem` or `UIImage`.
2. **Set the flags.** Return `isGenerative = true` and a provider `name`. The AI disclosure views show both.
3. **Swap the provider.** Change `AIServiceProvider.current`, or inject your service from configuration.
4. **Keep secrets off the device.** Don't ship API keys in the app. Call your own backend, which holds the provider key, and authenticate users, for example with App Attest plus your account system.
5. **Pass the progress callbacks through.** The Compiling and generator screens already display them.

AutoCut, captions (Speech), segmentation (Vision) and the AI clipper already run fully on-device and don't need a cloud service.

## Tests

`ClipForgeTests` holds 47 tests.

- **Pure logic:** `TimelineLayout` overlap and clamping, editing operations (split, delete, duplicate, move, remove-range, speed), the AutoCut arranger, the onset/tempo and scene-change detectors, caption grouping, story planning, AI clipper selection, and export settings.
- **VideoEngine composition:** these tests generate real H.264 and AAC media at test time. They check:
  - composition duration against the layout;
  - A/B track alternation;
  - that the instructions are contiguous, with two source tracks in each transition;
  - frame rendering through the custom compositor;
  - trim and speed;
  - a full 480p/24 fps export with audio and a watermark.

## Known limitations

- **TikTok sharing.** The TikTok OpenSDK is a third-party package, so sharing uses the system share sheet. "Promote" opens the TikTok app, or the TikTok website if the app is missing.
- **Frame rates.** Above the source frame rate, frames are duplicated, not interpolated.
- **Smart HDR** needs a device that can encode 10-bit HEVC. Otherwise the export falls back to SDR automatically.
- **Captions** use `SFSpeechRecognizer`. Recognition is on-device when the locale supports it; otherwise it goes through Apple's server and is subject to Apple's limits of about one minute per request. Long clips are transcribed in chunks.
- **Generative features** are local procedural mocks until you plug in a cloud `AIService`.

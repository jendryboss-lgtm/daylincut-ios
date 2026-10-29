import AVFoundation
import CoreImage
import Foundation
import UIKit

// MARK: - AIService

/// Everything "generative" goes through this protocol. `LocalAIService` implements it
/// fully on-device (procedural video, TTS, Core Image, Vision). To plug in a cloud
/// model, write another type that conforms (see README "Adding cloud AI") and swap it
/// in `AIServiceProvider.current`.
protocol AIService: Sendable {
    var name: String { get }
    /// True when results come from a generative model rather than local procedural output.
    var isGenerative: Bool { get }

    func generateVideo(prompt: String, duration: Double, aspect: AspectRatio,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Clip
    func storyboard(prompt: String, sceneCount: Int) async throws -> [StoryScene]
    func makeStory(prompt: String, aspect: AspectRatio, narrate: Bool,
                   progress: @escaping @Sendable (Double) -> Void) async throws -> Timeline
    func makeAvatar(script: String, look: AvatarLook, aspect: AspectRatio,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> Clip
    func generateMusic(style: AutoCutStyle, duration: Double) async throws -> AudioItem
    func extend(clip: Clip, by seconds: Double, aspect: AspectRatio,
                progress: @escaping @Sendable (Double) -> Void) async throws -> Clip
    func editPhoto(_ image: UIImage, operation: PhotoOperation) async throws -> UIImage
}

enum AIServiceProvider {
    /// Swap this for a cloud implementation (e.g. `RemoteAIService(endpoint:apiKey:)`).
    static let current: any AIService = LocalAIService()
}


// MARK: - LocalAIService

/// On-device implementation. No network, no third-party models.
struct LocalAIService: AIService {
    var name: String { "On-device" }
    var isGenerative: Bool { false }

    // MARK: Video

    func generateVideo(prompt: String, duration: Double, aspect: AspectRatio,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Clip {
        let scenes = StoryPlanner.scenes(for: prompt, sceneCount: 1)
        let palette = scenes.first?.palette ?? StoryPlanner.palettes[0]
        let title = prompt.isEmpty ? "Generated" : prompt
        let size = aspect.renderSize(shortSide: 720)
        let canvasSize = CGSize(width: size.width, height: size.height)
        let renderer = ProceduralScene(canvas: canvasSize, palette: palette, title: title, seed: prompt.hashValue)
        let fileName = try await FrameVideoWriter.write(size: canvasSize, duration: duration, fps: 30, progress: progress) { t in
            renderer.frame(at: t, duration: duration)
        }
        return Clip(mediaKind: .video, fileName: fileName, sourceDuration: duration, hasAudio: false,
                    displayWidth: Double(size.width), displayHeight: Double(size.height))
    }

    func storyboard(prompt: String, sceneCount: Int) async throws -> [StoryScene] {
        StoryPlanner.scenes(for: prompt, sceneCount: sceneCount)
    }

    func makeStory(prompt: String, aspect: AspectRatio, narrate: Bool,
                   progress: @escaping @Sendable (Double) -> Void) async throws -> Timeline {
        let scenes = StoryPlanner.scenes(for: prompt)
        var timeline = Timeline()
        timeline.aspectRatio = aspect
        let size = aspect.renderSize(shortSide: 720)
        let canvasSize = CGSize(width: size.width, height: size.height)
        var cursor = 0.0
        let synth = SpeechSynth()
        for (i, scene) in scenes.enumerated() {
            try Task.checkCancellation()
            var duration = scene.duration
            var narrationFile: (fileName: String, duration: Double)?
            if narrate {
                narrationFile = try? await synth.synthesize(scene.narration, rate: 0.48)
                if let n = narrationFile { duration = max(duration, n.duration + 0.4) }
            }
            let renderer = ProceduralScene(canvas: canvasSize, palette: scene.palette, title: "", seed: i * 7919 + prompt.count)
            let base = Double(i) / Double(scenes.count)
            let fileName = try await FrameVideoWriter.write(size: canvasSize, duration: duration, fps: 30, progress: { p in
                progress(base + p / Double(scenes.count))
            }) { t in renderer.frame(at: t, duration: duration) }
            var clip = Clip(mediaKind: .video, fileName: fileName, sourceDuration: duration, hasAudio: false,
                            displayWidth: Double(size.width), displayHeight: Double(size.height))
            clip.effect = .kenBurns
            clip.transition = Transition(type: i % 2 == 0 ? .dissolve : .slideLeft, duration: 0.4)
            timeline.clips.append(clip)
            timeline.texts.append(TextOverlay(text: scene.narration, start: cursor + 0.1, duration: max(0.5, duration - 0.6),
                                              centerX: 0.5, centerY: 0.72, fontScale: 0.045, colorHex: "#FFFFFF",
                                              style: .background, animation: .typewriter))
            if let n = narrationFile {
                timeline.audio.append(AudioItem(kind: .voiceover, title: "Narration \(i + 1)", fileName: n.fileName,
                                                sourceDuration: n.duration, start: cursor + 0.2, duration: n.duration))
            }
            cursor += clip.timelineDuration - (i < scenes.count - 1 ? clip.transition.effectiveDuration : 0)
        }
        timeline.texts.insert(TextOverlay(text: scenes.first?.title.uppercased() ?? "STORY", start: 0, duration: 1.8,
                                          centerX: 0.5, centerY: 0.3, fontScale: 0.075, style: .neon, animation: .pop), at: 0)
        let music = try await generateMusic(style: .cinematic, duration: timeline.duration)
        var bed = music
        bed.volume = narrate ? 0.25 : 0.8
        timeline.audio.append(bed)
        timeline.clampToDuration()
        progress(1)
        return timeline
    }

    // MARK: Avatar

    func makeAvatar(script: String, look: AvatarLook, aspect: AspectRatio,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> Clip {
        let synth = SpeechSynth()
        progress(0.05)
        let voice = try await synth.synthesize(script, rate: 0.5)
        progress(0.25)
        let samples = try await AudioSynth.readMonoSamples(url: MediaStore.url(for: voice.fileName))
        let fps = 30
        let envelope = StoryPlanner.envelope(samples: samples, sampleRate: 11025, fps: fps)
        let duration = voice.duration + 0.3
        let size = aspect.renderSize(shortSide: 720)
        let canvas = CGSize(width: size.width, height: size.height)
        let avatar = AvatarRenderer(canvas: canvas, look: look)
        let fileName = try await FrameVideoWriter.write(size: canvas, duration: duration, fps: fps,
                                                        audioURL: MediaStore.url(for: voice.fileName),
                                                        progress: { progress(0.25 + 0.75 * $0) }) { t in
            let idx = min(envelope.count - 1, max(0, Int(t * Double(fps))))
            let open = envelope.isEmpty ? 0 : envelope[idx]
            return avatar.frame(at: t, mouthOpen: open)
        }
        try? FileManager.default.removeItem(at: MediaStore.url(for: voice.fileName))
        return Clip(mediaKind: .video, fileName: fileName, sourceDuration: duration, hasAudio: true,
                    displayWidth: Double(size.width), displayHeight: Double(size.height))
    }

    // MARK: Music

    func generateMusic(style: AutoCutStyle, duration: Double) async throws -> AudioItem {
        let beat = try AudioSynth.makeBeat(bpm: style.bpm, duration: max(4, duration))
        return AudioItem(kind: .music, title: "\(style.title) Beat", fileName: beat.fileName, sourceDuration: beat.duration,
                         start: 0, sourceStart: 0, duration: min(beat.duration, max(4, duration)),
                         volume: 0.8, fadeIn: 0.3, fadeOut: 1, beats: beat.beats)
    }

    // MARK: Extend video

    /// Continues a clip past its end with a slow push-in on its final frame and a
    /// motion-blurred drift, so the shot "keeps going".
    func extend(clip: Clip, by seconds: Double, aspect: AspectRatio,
                progress: @escaping @Sendable (Double) -> Void) async throws -> Clip {
        guard let last = await VideoEngine.thumbnail(fileName: clip.fileName, at: max(0, clip.sourceEnd - 0.05),
                                                      maxSize: CGSize(width: 1920, height: 1920)) else {
            throw VideoEngineError.unreadableMedia(clip.fileName)
        }
        let base = CIImage(cgImage: last)
        let size = CGSize(width: (last.width / 2) * 2, height: (last.height / 2) * 2)
        let extent = CGRect(origin: .zero, size: size)
        let fileName = try await FrameVideoWriter.write(size: size, duration: seconds, fps: 30, progress: progress) { t in
            let p = t / max(0.01, seconds)
            let eased = p * p * (3 - 2 * p)
            let scale = 1 + 0.12 * eased
            let dx = -size.width * 0.03 * eased
            let moved = base
                .transformed(by: FilterRenderer.scaleAbout(center: CGPoint(x: extent.midX, y: extent.midY), scale: scale))
                .transformed(by: CGAffineTransform(translationX: dx, y: 0))
            return moved.clampedToExtent()
                .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: 2 + 4 * eased, kCIInputAngleKey: 0])
                .cropped(to: extent)
        }
        var result = clip
        result.id = UUID()
        result.fileName = fileName
        result.sourceDuration = seconds
        result.sourceStart = 0
        result.sourceEnd = seconds
        result.hasAudio = false
        result.speed = 1
        result.displayWidth = Double(size.width)
        result.displayHeight = Double(size.height)
        result.transition = Transition()
        return result
    }

    // MARK: Photos

    func editPhoto(_ image: UIImage, operation: PhotoOperation) async throws -> UIImage {
        guard let normalized = FrameVideoWriter.normalize(image, maxDimension: 2048), let cg = normalized.cgImage else {
            throw VideoEngineError.unreadableMedia("photo")
        }
        let input = CIImage(cgImage: cg)
        let output: CIImage
        switch operation {
        case .autoEnhance:
            output = FilterRenderer.apply(FilterRenderer.autoAdjustment(for: input), to: input)
        case .retouch:
            output = PhotoRetouch.retouch(input)
        case .removeBackground:
            guard let mask = SegmentationService.subjectMask(for: input) else {
                throw VideoEngineError.unreadableMedia("No subject found")
            }
            output = SegmentationService.cutOut(input, mask: mask)
        case .cartoon:
            output = PhotoRetouch.cartoon(input)
        case .cinematic:
            output = FilterRenderer.apply(.cinematic, intensity: 1, to: input)
        case .vivid:
            output = FilterRenderer.apply(.vivid, intensity: 1, to: input)
        case .mono:
            output = FilterRenderer.apply(.noir, intensity: 1, to: input)
        case .sketch:
            output = PhotoRetouch.sketch(input)
        }
        guard let rendered = RenderContext.shared.createCGImage(output, from: input.extent,
                                                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw VideoEngineError.writerFailed("Photo render failed")
        }
        return UIImage(cgImage: rendered)
    }
}

// MARK: - Procedural renderers

/// Animated gradient "scene" with drifting light orbs and an optional title.
struct ProceduralScene {
    let canvas: CGSize
    let colors: [CIColor]
    let titleImage: CIImage?
    let seed: Int

    init(canvas: CGSize, palette: [String], title: String, seed: Int) {
        self.canvas = canvas
        self.colors = palette.map { CIColor(color: UIColor(hex: $0)) }
        self.seed = abs(seed % 10_000)
        if !title.isEmpty, let cg = TextImageRenderer.render(text: title, fontName: "AvenirNext-Heavy",
                                                             pointSize: canvas.width * 0.075, color: .white,
                                                             style: .shadow, maxWidth: canvas.width * 0.86) {
            titleImage = CIImage(cgImage: cg)
        } else {
            titleImage = nil
        }
    }

    func frame(at t: Double, duration: Double) -> CIImage {
        let rect = CGRect(origin: .zero, size: canvas)
        let a = colors.first ?? CIColor(red: 0.1, green: 0.1, blue: 0.2)
        let b = colors.count > 1 ? colors[1] : CIColor(red: 0.3, green: 0.1, blue: 0.5)
        let angle = t * 0.35 + Double(seed) * 0.01
        let p0 = CIVector(x: rect.midX + cos(angle) * rect.width * 0.6, y: rect.midY + sin(angle) * rect.height * 0.6)
        let p1 = CIVector(x: rect.midX - cos(angle) * rect.width * 0.6, y: rect.midY - sin(angle) * rect.height * 0.6)
        var image = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": p0, "inputPoint1": p1, "inputColor0": a, "inputColor1": b
        ])?.outputImage?.cropped(to: rect) ?? CIImage(color: a).cropped(to: rect)

        for i in 0..<5 {
            let phase = Double(seed + i * 131)
            let x = rect.width * (0.5 + 0.4 * sin(t * (0.2 + 0.07 * Double(i)) + phase))
            let y = rect.height * (0.5 + 0.4 * cos(t * (0.15 + 0.05 * Double(i)) + phase * 0.7))
            let r = rect.width * (0.12 + 0.05 * Double(i % 3))
            let orb = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: x, y: y), "inputRadius0": 0, "inputRadius1": r,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.22),
                "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            ])?.outputImage?.cropped(to: rect)
            if let orb { image = orb.composited(over: image) }
        }
        if let titleImage {
            let fadeIn = min(1, t / 0.6), fadeOut = min(1, max(0, (duration - t) / 0.5))
            let alpha = min(fadeIn, fadeOut)
            let scale = 0.94 + 0.06 * min(1, t / 1.2)
            let placed = titleImage
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let tx = rect.midX - placed.extent.width / 2 - placed.extent.minX
            let ty = rect.midY - placed.extent.height / 2 - placed.extent.minY
            let faded = placed.transformed(by: CGAffineTransform(translationX: tx, y: ty))
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
            image = faded.composited(over: image)
        }
        return image.cropped(to: rect)
    }
}

/// Stylised talking avatar drawn with Core Image primitives and lip-synced to TTS.
struct AvatarRenderer {
    let canvas: CGSize
    let look: AvatarLook
    private let background: CIImage
    private let skin: CIColor

    init(canvas: CGSize, look: AvatarLook) {
        self.canvas = canvas
        self.look = look
        let rect = CGRect(origin: .zero, size: canvas)
        let c0 = CIColor(color: UIColor(hex: look.backgroundHex[0]))
        let c1 = CIColor(color: UIColor(hex: look.backgroundHex[1]))
        background = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: rect.height), "inputPoint1": CIVector(x: rect.width, y: 0),
            "inputColor0": c0, "inputColor1": c1
        ])?.outputImage?.cropped(to: rect) ?? CIImage(color: c0).cropped(to: rect)
        skin = CIColor(color: UIColor(hex: look.skinHex))
    }

    private func disc(center: CGPoint, radius: CGFloat, color: CIColor, softness: CGFloat = 1.5) -> CIImage {
        let clear = CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0)
        return CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(cgPoint: center), "inputRadius0": max(0, radius - softness), "inputRadius1": radius,
            "inputColor0": color, "inputColor1": clear
        ])?.outputImage?.cropped(to: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)) ?? .empty()
    }

    private func ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, color: CIColor) -> CIImage {
        let r = max(rx, 1)
        return disc(center: .zero, radius: r, color: color)
            .transformed(by: CGAffineTransform(scaleX: 1, y: max(0.02, ry / r)))
            .transformed(by: CGAffineTransform(translationX: center.x, y: center.y))
    }

    func frame(at t: Double, mouthOpen: Double) -> CIImage {
        let w = canvas.width, h = canvas.height
        let unit = min(w, h)
        let bob = CGFloat(sin(t * 2.1)) * unit * 0.008
        let center = CGPoint(x: w / 2, y: h * 0.52 + bob)
        let headR = unit * 0.28
        var image = background
        // Shoulders
        image = ellipse(center: CGPoint(x: w / 2, y: center.y - headR * 1.55), rx: headR * 1.45, ry: headR * 0.75,
                        color: CIColor(red: 0.12, green: 0.12, blue: 0.16)).composited(over: image)
        // Head
        image = disc(center: center, radius: headR, color: skin, softness: 2).composited(over: image)
        // Eyes with blinking every ~3.2 s
        let blinkPhase = t.truncatingRemainder(dividingBy: 3.2)
        let eyeOpen: CGFloat = blinkPhase < 0.12 ? 0.12 : 1
        let eyeY = center.y + headR * 0.18
        let eyeColor = CIColor(red: 0.08, green: 0.08, blue: 0.1)
        for dx in [-headR * 0.36, headR * 0.36] {
            image = ellipse(center: CGPoint(x: center.x + dx, y: eyeY), rx: headR * 0.09, ry: headR * 0.11 * eyeOpen,
                            color: eyeColor).composited(over: image)
        }
        // Mouth
        let open = CGFloat(max(0, min(1, mouthOpen)))
        image = ellipse(center: CGPoint(x: center.x, y: center.y - headR * 0.42),
                        rx: headR * (0.22 + 0.06 * open), ry: headR * (0.035 + 0.16 * open),
                        color: CIColor(red: 0.45, green: 0.08, blue: 0.12)).composited(over: image)
        return image.cropped(to: CGRect(origin: .zero, size: canvas))
    }
}

// MARK: - Retouch & stylise

enum PhotoRetouch {
    /// Skin smoothing restricted to detected faces + gentle brightening.
    static func retouch(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let faces = SegmentationService.faceRects(in: image)
        let smooth = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(2, extent.width * 0.004)])
            .cropped(to: extent)
        // High-pass detail keeps eyes/edges sharp: blend 70% smooth in face regions.
        var mask = CIImage(color: .black).cropped(to: extent)
        for f in faces {
            let r = CGRect(x: f.minX * extent.width, y: f.minY * extent.height,
                           width: f.width * extent.width, height: f.height * extent.height).insetBy(dx: -f.width * extent.width * 0.1,
                                                                                                    dy: -f.height * extent.height * 0.15)
            let radius = max(r.width, r.height) / 2
            let spot = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: r.midX, y: r.midY), "inputRadius0": radius * 0.55, "inputRadius1": radius,
                "inputColor0": CIColor(red: 0.7, green: 0.7, blue: 0.7), "inputColor1": CIColor(red: 0, green: 0, blue: 0)
            ])?.outputImage?.cropped(to: extent)
            if let spot { mask = spot.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask]) }
        }
        let blended = faces.isEmpty
            ? smooth.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: image, kCIInputTimeKey: 0.75])
            : smooth.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
        return blended
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.02, kCIInputSaturationKey: 1.05])
            .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": 0.35])
            .cropped(to: extent)
    }

    static func cartoon(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let posterized = image.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 6])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.4])
        let edges = image.applyingFilter("CILineOverlay", parameters: ["inputEdgeIntensity": 1.2, "inputThreshold": 0.15])
        return edges.composited(over: posterized).cropped(to: extent)
    }

    static func sketch(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let gray = image.applyingFilter("CIPhotoEffectNoir")
        let lines = gray.applyingFilter("CILineOverlay", parameters: ["inputEdgeIntensity": 1.5, "inputThreshold": 0.1])
        return lines.composited(over: CIImage(color: .white).cropped(to: extent)).cropped(to: extent)
    }
}

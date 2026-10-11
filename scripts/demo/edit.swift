import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation

struct OutputSpec: Decodable {
    let width: Int
    let height: Int
    let fps: Int
}

struct SourceSpec: Decodable {
    let video: String
    let cursor: String?
}

struct Caption: Decodable {
    let at: Double
    let duration: Double
    let text: String
}

struct Card: Decodable {
    let title: String
    let subtitle: String
    let duration: Double
}

struct Clip: Decodable {
    let source: String?
    let start: Double?
    let end: Double?
    let speed: Double?
    let camera: [[Double]]?
    let cursor: Bool?
    let captions: [Caption]?
    let dissolve: Double?
    let card: Card?
}

struct EditList: Decodable {
    let output: OutputSpec
    let sourceWidth: Int
    let sourceHeight: Int
    let pointScale: Double
    let fontsDirectory: String
    let iconPath: String
    let destination: String
    let crf: Int
    let sources: [String: SourceSpec]
    let clips: [Clip]
}

struct CameraPose {
    let zoom: Double
    let centerX: Double
    let centerY: Double
}

enum Easing {
    static func smooth(_ value: Double) -> Double {
        let clamped = min(1, max(0, value))
        return clamped * clamped * clamped * (clamped * (clamped * 6 - 15) + 10)
    }
}

struct CameraTrack {
    let keys: [[Double]]

    func pose(at time: Double) -> CameraPose {
        guard let first = keys.first, let last = keys.last else { return CameraPose(zoom: 1, centerX: 0.5, centerY: 0.5) }
        if time <= first[0] { return CameraPose(zoom: first[1], centerX: first[2], centerY: first[3]) }
        if time >= last[0] { return CameraPose(zoom: last[1], centerX: last[2], centerY: last[3]) }
        for index in 1..<keys.count where time <= keys[index][0] {
            let from = keys[index - 1]
            let to = keys[index]
            let progress = Easing.smooth((time - from[0]) / (to[0] - from[0]))
            return CameraPose(
                zoom: from[1] + (to[1] - from[1]) * progress,
                centerX: from[2] + (to[2] - from[2]) * progress,
                centerY: from[3] + (to[3] - from[3]) * progress)
        }
        return CameraPose(zoom: last[1], centerX: last[2], centerY: last[3])
    }
}

struct CursorSample {
    let epoch: Double
    let x: Double
    let y: Double
    let pressed: Bool
}

struct CursorTrack {
    let samples: [CursorSample]
    let movementTimes: [Double]
    let pressTimes: [Double]

    init(path: String) {
        let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var parsed: [CursorSample] = []
        for line in content.split(separator: "\n") {
            let fields = line.split(separator: ",").compactMap { Double($0) }
            guard fields.count == 4 else { continue }
            parsed.append(CursorSample(epoch: fields[0], x: fields[1], y: fields[2], pressed: fields[3] > 0))
        }
        parsed.sort { $0.epoch < $1.epoch }
        samples = parsed
        var moved: [Double] = []
        var presses: [Double] = []
        for index in parsed.indices {
            let sample = parsed[index]
            if index > 0 {
                let previous = parsed[index - 1]
                if abs(sample.x - previous.x) > 0.01 || abs(sample.y - previous.y) > 0.01 { moved.append(sample.epoch) }
                if sample.pressed && !previous.pressed { presses.append(sample.epoch) }
            }
        }
        movementTimes = moved
        pressTimes = presses
    }

    private func lowerIndex(of epoch: Double, in times: [Double]) -> Int? {
        var low = 0
        var high = times.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if times[middle] <= epoch { found = middle; low = middle + 1 } else { high = middle - 1 }
        }
        return found
    }

    func position(at epoch: Double) -> (x: Double, y: Double, pressed: Bool)? {
        guard let first = samples.first, epoch >= first.epoch else { return nil }
        guard let index = lowerIndex(of: epoch, in: samples.map { $0.epoch }) else { return nil }
        let current = samples[index]
        guard index + 1 < samples.count else { return (current.x, current.y, current.pressed) }
        let next = samples[index + 1]
        let span = next.epoch - current.epoch
        guard span > 0, span < 0.5 else { return (current.x, current.y, current.pressed) }
        let progress = (epoch - current.epoch) / span
        return (current.x + (next.x - current.x) * progress, current.y + (next.y - current.y) * progress, current.pressed)
    }

    func visibility(at epoch: Double, idleSeconds: Double, fadeSeconds: Double) -> Double {
        guard let index = lowerIndex(of: epoch, in: movementTimes) else { return 0 }
        let age = epoch - movementTimes[index]
        if age <= idleSeconds { return 1 }
        return max(0, 1 - (age - idleSeconds) / fadeSeconds)
    }

    func secondsSinceLastPress(at epoch: Double) -> Double? {
        guard let index = lowerIndex(of: epoch, in: pressTimes) else { return nil }
        return epoch - pressTimes[index]
    }
}

enum Fonts {
    static func register(directory: String) {
        for name in ["InstrumentSans.ttf", "SourceSerif4.ttf"] {
            CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "\(directory)/\(name)") as CFURL, .process, nil)
        }
    }

    static func font(family: String, weight: Double, size: CGFloat) -> CTFont {
        let base = CTFontDescriptorCreateWithNameAndSize(family as CFString, size)
        let weighted = CTFontDescriptorCreateCopyWithVariation(base, NSNumber(value: 2_003_265_652) as CFNumber, CGFloat(weight))
        return CTFontCreateWithFontDescriptor(weighted, size, nil)
    }
}

enum Drawing {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }

    static func textLine(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    static func captionImage(text: String, scale: CGFloat) -> CGImage {
        let font = Fonts.font(family: "Instrument Sans", weight: 500, size: 27 * scale)
        let line = textLine(text, font: font, color: CGColor(red: 0.93, green: 0.94, blue: 0.97, alpha: 1))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let horizontalPadding = 30 * scale
        let verticalPadding = 17 * scale
        let margin = 40 * scale
        let width = Int(bounds.width + horizontalPadding * 2 + margin * 2)
        let height = Int(bounds.height + verticalPadding * 2 + margin * 2)
        return bitmap(width: width, height: height) { context in
            let pill = CGRect(x: margin, y: margin, width: CGFloat(width) - margin * 2, height: CGFloat(height) - margin * 2)
            let path = CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 28 * scale, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
            context.setFillColor(CGColor(red: 0.075, green: 0.078, blue: 0.095, alpha: 0.95))
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
            context.setLineWidth(1 * scale)
            context.addPath(path)
            context.strokePath()
            context.textPosition = CGPoint(x: pill.minX + horizontalPadding - bounds.minX, y: pill.minY + verticalPadding - bounds.minY)
            CTLineDraw(line, context)
        }
    }

    static func cursorImage(scale: CGFloat) -> CGImage {
        let size = Int(40 * scale)
        return bitmap(width: size, height: size) { context in
            context.scaleBy(x: scale, y: scale)
            let tip = CGPoint(x: 6, y: 34)
            let outline = CGMutablePath()
            outline.move(to: tip)
            outline.addLine(to: CGPoint(x: 6, y: 8.5))
            outline.addLine(to: CGPoint(x: 12.2, y: 14.4))
            outline.addLine(to: CGPoint(x: 16.0, y: 5.2))
            outline.addLine(to: CGPoint(x: 20.2, y: 7.0))
            outline.addLine(to: CGPoint(x: 16.4, y: 16.0))
            outline.addLine(to: CGPoint(x: 24.4, y: 16.2))
            outline.closeSubpath()
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -2), blur: 5, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.addPath(outline)
            context.fillPath()
            context.restoreGState()
            let inner = CGMutablePath()
            inner.move(to: CGPoint(x: 7.6, y: 31.0))
            inner.addLine(to: CGPoint(x: 7.6, y: 12.2))
            inner.addLine(to: CGPoint(x: 12.4, y: 16.8))
            inner.addLine(to: CGPoint(x: 16.3, y: 7.9))
            inner.addLine(to: CGPoint(x: 18.0, y: 8.7))
            inner.addLine(to: CGPoint(x: 14.2, y: 17.6))
            inner.addLine(to: CGPoint(x: 21.2, y: 17.8))
            inner.closeSubpath()
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.addPath(inner)
            context.fillPath()
        }
    }

    static func rippleImage(size: Int) -> CGImage {
        bitmap(width: size, height: size) { context in
            let inset = CGFloat(size) * 0.08
            let rect = CGRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
            context.setStrokeColor(CGColor(red: 0.64, green: 0.66, blue: 1, alpha: 1))
            context.setLineWidth(CGFloat(size) * 0.035)
            context.strokeEllipse(in: rect)
            context.setFillColor(CGColor(red: 0.64, green: 0.66, blue: 1, alpha: 0.16))
            context.fillEllipse(in: rect)
        }
    }

    static func trafficLights(width: Int, height: Int) -> CGImage {
        bitmap(width: width, height: height) { context in
            let colors: [CGColor] = [
                CGColor(red: 1.0, green: 0.373, blue: 0.341, alpha: 1),
                CGColor(red: 0.996, green: 0.737, blue: 0.180, alpha: 1),
                CGColor(red: 0.157, green: 0.784, blue: 0.251, alpha: 1),
            ]
            for (index, color) in colors.enumerated() {
                let centerX = 27.0 + Double(index) * 40.5
                let centerY = Double(height) - 27.0
                let rect = CGRect(x: centerX - 11.5, y: centerY - 11.5, width: 23, height: 23)
                context.setFillColor(color)
                context.fillEllipse(in: rect)
                context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.22))
                context.setLineWidth(1)
                context.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
            }
        }
    }

    static func card(_ card: Card, width: Int, height: Int, iconPath: String) -> CGImage {
        let scale = CGFloat(width) / 1920
        return bitmap(width: width, height: height) { context in
            let gradient = CGGradient(colorsSpace: colorSpace, colors: [
                CGColor(red: 0.082, green: 0.086, blue: 0.106, alpha: 1),
                CGColor(red: 0.047, green: 0.049, blue: 0.060, alpha: 1),
            ] as CFArray, locations: [0, 1])!
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) * 0.56), startRadius: 0,
                                       endCenter: CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) * 0.56), endRadius: CGFloat(width) * 0.62,
                                       options: [.drawsAfterEndLocation])
            if let icon = NSImage(contentsOfFile: iconPath)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let side = 150 * scale
                context.draw(icon, in: CGRect(x: (CGFloat(width) - side) / 2, y: CGFloat(height) * 0.60, width: side, height: side))
            }
            let title = textLine(card.title, font: Fonts.font(family: "Source Serif 4", weight: 600, size: 104 * scale),
                                 color: CGColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1))
            let titleBounds = CTLineGetBoundsWithOptions(title, [])
            context.textPosition = CGPoint(x: (CGFloat(width) - titleBounds.width) / 2 - titleBounds.minX, y: CGFloat(height) * 0.46)
            CTLineDraw(title, context)
            let subtitle = textLine(card.subtitle, font: Fonts.font(family: "Instrument Sans", weight: 450, size: 40 * scale),
                                    color: CGColor(red: 0.62, green: 0.64, blue: 0.72, alpha: 1))
            let subtitleBounds = CTLineGetBoundsWithOptions(subtitle, [])
            context.textPosition = CGPoint(x: (CGFloat(width) - subtitleBounds.width) / 2 - subtitleBounds.minX, y: CGFloat(height) * 0.36)
            CTLineDraw(subtitle, context)
        }
    }
}

final class FrameSource {
    private let process = Process()
    private let handle: FileHandle
    private let frameBytes: Int

    init(video: String, start: Double, end: Double, speed: Double, fps: Int, width: Int, height: Int) {
        frameBytes = width * height * 4
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-v", "error", "-ss", String(start), "-t", String(end - start), "-i", video,
            "-vf", "setpts=(PTS-STARTPTS)/\(speed),fps=\(fps),format=bgra", "-f", "rawvideo", "-",
        ]
        process.standardOutput = pipe
        handle = pipe.fileHandleForReading
        try? process.run()
    }

    func nextFrame() -> Data? {
        var collected = Data()
        while collected.count < frameBytes {
            let chunk = handle.readData(ofLength: frameBytes - collected.count)
            if chunk.isEmpty { return nil }
            collected.append(chunk)
        }
        return collected
    }

    func finish() {
        process.terminate()
    }
}

final class Encoder {
    private let process = Process()
    private let input: FileHandle

    init(spec: OutputSpec, destination: String, crf: Int) {
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(spec.width)x\(spec.height)", "-r", String(spec.fps), "-i", "-",
            "-c:v", "libx264", "-preset", "slow", "-crf", String(crf), "-pix_fmt", "yuv420p", "-profile:v", "high", "-tag:v", "avc1",
            "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-movflags", "+faststart", destination,
        ]
        process.standardInput = pipe
        input = pipe.fileHandleForWriting
        try? process.run()
    }

    func write(_ data: Data) {
        input.write(data)
    }

    func finish() {
        try? input.close()
        process.waitUntilExit()
    }
}

final class Compositor {
    private let edit: EditList
    private let context: CIContext
    private let outputBounds: CGRect
    private let encoder: Encoder
    private let cursorSprite: CIImage
    private let rippleSprite: CIImage
    private let spriteScale: CGFloat = 4
    private let trafficLights: CIImage
    private let pillWidth = 172
    private let pillHeight = 58
    private var lastFrame: CIImage?
    private var tracks: [String: CursorTrack] = [:]
    private var epochs: [String: Double] = [:]
    private var captionImages: [String: CIImage] = [:]
    private var framesWritten = 0

    init(edit: EditList) {
        self.edit = edit
        context = CIContext(options: [.workingColorSpace: Drawing.colorSpace, .outputColorSpace: Drawing.colorSpace])
        outputBounds = CGRect(x: 0, y: 0, width: edit.output.width, height: edit.output.height)
        encoder = Encoder(spec: edit.output, destination: edit.destination, crf: edit.crf)
        cursorSprite = CIImage(cgImage: Drawing.cursorImage(scale: spriteScale))
        rippleSprite = CIImage(cgImage: Drawing.rippleImage(size: 256))
        trafficLights = CIImage(cgImage: Drawing.trafficLights(width: pillWidth, height: pillHeight))
        for (name, source) in edit.sources {
            if let cursorPath = source.cursor { tracks[name] = CursorTrack(path: cursorPath) }
            let epochText = (try? String(contentsOfFile: source.video + ".epoch", encoding: .utf8)) ?? "0"
            epochs[name] = Double(epochText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
    }

    private func patchedSource(_ raw: Data) -> CIImage {
        let width = edit.sourceWidth
        let height = edit.sourceHeight
        let image = CIImage(bitmapData: raw, bytesPerRow: width * 4, size: CGSize(width: width, height: height), format: .BGRA8,
                            colorSpace: Drawing.colorSpace)
        let stripRect = CGRect(x: 178, y: height - pillHeight, width: 1, height: pillHeight)
        let strip = image.cropped(to: stripRect)
            .transformed(by: CGAffineTransform(translationX: -178, y: 0))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(pillWidth), y: 1))
            .samplingNearest()
            .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(height - pillHeight)))
        let lights = trafficLights.transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(height - pillHeight)))
        return lights.composited(over: strip.composited(over: image))
    }

    private func camera(for pose: CameraPose, on image: CIImage) -> (CIImage, CGRect, CGFloat) {
        let width = Double(edit.sourceWidth)
        let height = Double(edit.sourceHeight)
        let visibleWidth = width / pose.zoom
        let visibleHeight = height / pose.zoom
        let left = min(max(pose.centerX * width - visibleWidth / 2, 0), width - visibleWidth)
        let top = min(max(pose.centerY * height - visibleHeight / 2, 0), height - visibleHeight)
        let bottomInImageSpace = height - top - visibleHeight
        let scale = CGFloat(edit.output.width) / CGFloat(visibleWidth)
        let cropped = image.cropped(to: CGRect(x: left, y: bottomInImageSpace, width: visibleWidth, height: visibleHeight))
            .transformed(by: CGAffineTransform(translationX: -left, y: -bottomInImageSpace))
        let scaled = cropped.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        return (scaled, CGRect(x: left, y: top, width: visibleWidth, height: visibleHeight), scale)
    }

    private func overlayCursor(on image: CIImage, source: String, epoch: Double, view: CGRect, scale: CGFloat) -> CIImage {
        guard let track = tracks[source], let position = track.position(at: epoch) else { return image }
        var result = image
        let sourceX = position.x * edit.pointScale
        let sourceY = position.y * edit.pointScale
        let outputX = (sourceX - Double(view.minX)) * Double(scale)
        let outputY = Double(edit.output.height) - (sourceY - Double(view.minY)) * Double(scale)
        if let sincePress = track.secondsSinceLastPress(at: epoch), sincePress < 0.55 {
            let progress = sincePress / 0.55
            let diameter = (40 + 70 * Easing.smooth(progress)) * Double(scale)
            let alpha = (1 - progress) * 0.9
            let ring = rippleSprite
                .transformed(by: CGAffineTransform(scaleX: diameter / 256, y: diameter / 256))
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
                .transformed(by: CGAffineTransform(translationX: outputX - diameter / 2, y: outputY - diameter / 2))
            result = ring.composited(over: result)
        }
        let visibility = track.visibility(at: epoch, idleSeconds: 1.6, fadeSeconds: 0.5)
        guard visibility > 0.01 else { return result }
        let pointerScale = CGFloat(edit.pointScale) * scale / spriteScale * 0.86
        let tipInSprite = CGPoint(x: 6 * spriteScale, y: 34 * spriteScale)
        let pressedShrink: CGFloat = position.pressed ? 0.92 : 1
        let sprite = cursorSprite
            .transformed(by: CGAffineTransform(translationX: -tipInSprite.x, y: -tipInSprite.y))
            .transformed(by: CGAffineTransform(scaleX: pointerScale * pressedShrink, y: pointerScale * pressedShrink))
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(visibility))])
            .transformed(by: CGAffineTransform(translationX: outputX, y: outputY))
        return sprite.composited(over: result)
    }

    private func captionOverlay(_ captions: [Caption], at time: Double, on image: CIImage) -> CIImage {
        var result = image
        for caption in captions where time >= caption.at && time <= caption.at + caption.duration {
            let key = caption.text
            if captionImages[key] == nil {
                captionImages[key] = CIImage(cgImage: Drawing.captionImage(text: caption.text, scale: CGFloat(edit.output.width) / 1920))
            }
            guard let sprite = captionImages[key] else { continue }
            let fade = 0.35
            let elapsed = time - caption.at
            let remaining = caption.at + caption.duration - time
            let alpha = min(Easing.smooth(elapsed / fade), Easing.smooth(remaining / fade))
            let slide = (1 - Easing.smooth(elapsed / fade)) * 10
            let x = (CGFloat(edit.output.width) - sprite.extent.width) / 2
            let y = 54 * CGFloat(edit.output.width) / 1920 - 40 * CGFloat(edit.output.width) / 1920 - CGFloat(slide)
            let placed = sprite
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
                .transformed(by: CGAffineTransform(translationX: x, y: y))
            result = placed.composited(over: result)
        }
        return result
    }

    private func emit(_ image: CIImage) {
        var buffer = Data(count: edit.output.width * edit.output.height * 4)
        buffer.withUnsafeMutableBytes { pointer in
            context.render(image, toBitmap: pointer.baseAddress!, rowBytes: edit.output.width * 4, bounds: outputBounds, format: .BGRA8,
                           colorSpace: Drawing.colorSpace)
        }
        encoder.write(buffer)
        framesWritten += 1
        lastFrame = image
    }

    private func blend(_ incoming: CIImage, over previous: CIImage, amount: Double) -> CIImage {
        let eased = Easing.smooth(amount)
        let faded = incoming.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(eased))])
        return faded.composited(over: previous)
    }

    private func renderClip(_ clip: Clip) {
        let fps = Double(edit.output.fps)
        let dissolveFrames = Int((clip.dissolve ?? 0) * fps)
        if let card = clip.card {
            let image = CIImage(cgImage: Drawing.card(card, width: edit.output.width, height: edit.output.height, iconPath: edit.iconPath))
            let total = Int(card.duration * fps)
            for index in 0..<total {
                let time = Double(index) / fps
                let fadeIn = Easing.smooth(time / 0.9)
                let frame = lastFrame.map { blend(image, over: $0, amount: fadeIn) } ?? image
                emit(frame)
            }
            return
        }
        guard let sourceName = clip.source, let spec = edit.sources[sourceName], let start = clip.start, let end = clip.end else { return }
        let speed = clip.speed ?? 1
        let frames = FrameSource(video: spec.video, start: start, end: end, speed: speed, fps: edit.output.fps, width: edit.sourceWidth,
                                 height: edit.sourceHeight)
        let track = CameraTrack(keys: clip.camera ?? [[0, 1, 0.5, 0.5]])
        let captions = clip.captions ?? []
        let showCursor = clip.cursor ?? true
        let epochZero = epochs[sourceName] ?? 0
        var index = 0
        while true {
            let finished: Bool = autoreleasepool {
            guard let raw = frames.nextFrame() else { return true }
            let outputTime = Double(index) / fps
            let sourceTime = start + outputTime * speed
            let pose = track.pose(at: outputTime)
            let patched = patchedSource(raw)
            let (framed, view, scale) = camera(for: pose, on: patched)
            var composed = framed
            if showCursor { composed = overlayCursor(on: composed, source: sourceName, epoch: epochZero + sourceTime, view: view, scale: scale) }
            composed = captionOverlay(captions, at: outputTime, on: composed)
            if index < dissolveFrames, let previous = lastFrame {
                composed = blend(composed, over: previous, amount: Double(index) / Double(max(1, dissolveFrames)))
            }
            emit(composed.cropped(to: outputBounds))
            index += 1
            return false
            }
            if finished { break }
        }
        frames.finish()
    }

    func run() {
        for (index, clip) in edit.clips.enumerated() {
            let before = framesWritten
            renderClip(clip)
            fputs("clip \(index): \(framesWritten - before) frames\n", stderr)
        }
        encoder.finish()
        print("wrote \(edit.destination): \(framesWritten) frames, \(Double(framesWritten) / Double(edit.output.fps)) s")
    }
}

_ = NSApplication.shared
guard CommandLine.arguments.count > 1,
      let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let edit = try? JSONDecoder().decode(EditList.self, from: data) else {
    fputs("usage: edit <edit-list.json>\n", stderr)
    exit(1)
}
Fonts.register(directory: edit.fontsDirectory)
Compositor(edit: edit).run()

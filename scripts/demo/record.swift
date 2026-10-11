import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

struct RecorderArguments {
    let processID: pid_t
    let output: URL
    let framesPerSecond: Int
    let bitrate: Int

    init(_ arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        processID = pid_t(value("--pid") ?? "") ?? 0
        output = URL(fileURLWithPath: value("--out") ?? "capture.mov")
        framesPerSecond = Int(value("--fps") ?? "") ?? 60
        bitrate = (Int(value("--mbps") ?? "") ?? 40) * 1_000_000
    }
}

final class WindowRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let arguments: RecorderArguments
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstTimestamp: CMTime?
    private let queue = DispatchQueue(label: "recorder.samples")

    init(_ arguments: RecorderArguments) { self.arguments = arguments }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let candidates = content.windows.filter { $0.owningApplication?.processID == arguments.processID && $0.frame.width > 600 }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw NSError(domain: "recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "no window for pid \(arguments.processID)"])
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let scale = Int(info.pointPixelScale)
        let width = Int(info.contentRect.width) * scale
        let height = Int(info.contentRect.height) * scale

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(arguments.framesPerSecond))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.queueDepth = 8
        configuration.scalesToFit = false

        try? FileManager.default.removeItem(at: arguments.output)
        let writer = try AVAssetWriter(outputURL: arguments.output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: arguments.bitrate,
                AVVideoExpectedSourceFrameRateKey: arguments.framesPerSecond,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
        self.writer = writer
        self.input = input

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        print("recording \(width)x\(height) window \(window.windowID) -> \(arguments.output.path)")
        fflush(stdout)
    }

    func stop() async {
        try? await stream?.stopCapture()
        queue.sync {}
        input?.markAsFinished()
        await writer?.finishWriting()
        print("finished")
        fflush(stdout)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let writer, let input else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstTimestamp == nil {
            firstTimestamp = timestamp
            writer.startSession(atSourceTime: timestamp)
            let sinceFrame = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), timestamp))
            let epoch = Date().timeIntervalSince1970 - sinceFrame
            try? String(format: "%.4f\n", epoch).write(toFile: arguments.output.path + ".epoch", atomically: true, encoding: .utf8)
        }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("stream stopped: \(error)\n".utf8))
    }
}

_ = NSApplication.shared
let recorder = WindowRecorder(RecorderArguments(CommandLine.arguments))
let stopSignals = [SIGINT, SIGTERM].map { signalNumber -> DispatchSourceSignal in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler { Task { await recorder.stop(); exit(0) } }
    source.resume()
    return source
}
Task {
    do { try await recorder.start() } catch { print("failed: \(error)"); exit(1) }
}
withExtendedLifetime(stopSignals) { RunLoop.main.run() }

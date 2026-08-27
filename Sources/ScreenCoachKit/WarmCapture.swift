import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Metal
import ScreenCaptureKit
import ScreenCoachCore

/// Screen capture, measured three ways.
///
/// The brief budgets 50 ms for hotkey→frame and warns that `SCStream` session
/// setup is a hidden 300–800 ms tax, so the stream must be kept warm. That is
/// a claim worth testing rather than inheriting, so this file implements all
/// three plausible paths and the bench times them head to head:
///
///  1. `/usr/sbin/screencapture` — what WindowPet actually shipped. A process
///     spawn per frame. The baseline to beat.
///  2. `SCScreenshotManager.captureImage` — the macOS 14+ one-shot. No stream
///     to keep alive, so if it lands inside budget the whole warm-stream
///     apparatus is unnecessary complexity.
///  3. A warm `SCStream` that keeps the newest complete frame in hand.
///
/// The non-obvious part of (3): ScreenCaptureKit does **not** deliver frames
/// on a timer. When the screen is static it emits `.idle` frames with no
/// pixels, so "wait for the next frame after the hotkey" can block for an
/// unbounded time on a still screen — the exact situation a coach faces,
/// since the user is staring at the UI they're asking about. The correct
/// design is therefore to retain the last `.complete` frame and use it
/// immediately: if nothing has changed, a frame from 3 seconds ago is still
/// a perfect likeness. `frameAgeMs` reports that staleness so it is a stated
/// property rather than a silent assumption.
public final class WarmCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    public struct Frame {
        public let pixelBuffer: CVPixelBuffer
        public let capturedAtNs: UInt64
        public let contentRect: CGRect
        public let contentScale: CGFloat

        public var ageMs: Double { Mono.msSince(capturedAtNs) }
    }

    public enum CaptureError: Error, CustomStringConvertible {
        case noDisplay
        case noWindow
        case notStarted
        case noFrameYet
        case conversionFailed

        public var description: String {
            switch self {
            case .noDisplay: return "No shareable display (Screen Recording permission?)"
            case .noWindow: return "No matching shareable window"
            case .notStarted: return "Stream not started"
            case .noFrameYet: return "Warm stream has not delivered a complete frame yet"
            case .conversionFailed: return "CVPixelBuffer → CGImage conversion failed"
            }
        }
    }

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "coach.capture.output", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: Frame?
    private var firstFrameContinuation: CheckedContinuation<Void, Never>?

    /// Metal-backed and built once. A fresh `CIContext` per conversion would
    /// pay Metal pipeline setup on the measured path and report a capture
    /// cost that is really a warm-up cost.
    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    public private(set) var completeFrames = 0
    public private(set) var idleFrames = 0

    public override init() { super.init() }

    // MARK: - Shareable content

    public static func mainDisplay() async throws -> SCDisplay {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        return display
    }

    /// The frontmost app's on-screen window, which is what a teaching coach
    /// actually wants: window-scoped capture sees the app you asked about and
    /// nothing else on the desktop. Lower friction and dramatically better
    /// privacy than grabbing the whole display.
    /// The window to capture. With `named` nil this is the frontmost app's
    /// window; with a name it is that app's largest on-screen window, which
    /// lets a benchmark target a dense professional UI without stealing focus
    /// from whatever the user is doing.
    public static func frontmostWindow(named: String? = nil) async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        )
        let candidates = content.windows.filter { w in
            w.isOnScreen && w.frame.width >= 120 && w.frame.height >= 60
        }

        if let named = named?.lowercased(), !named.isEmpty {
            let matches = candidates.filter {
                ($0.owningApplication?.applicationName ?? "").lowercased().contains(named)
                    || ($0.owningApplication?.bundleIdentifier ?? "").lowercased().contains(named)
            }
            // Largest, not first: apps scatter small palettes and inspectors
            // through the window list and the document window is the one a
            // person means.
            guard let best = matches.max(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }) else { throw CaptureError.noWindow }
            return best
        }

        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let pid = frontPID,
           let match = candidates.first(where: { $0.owningApplication?.processID == pid }) {
            return match
        }
        guard let any = candidates.first else { throw CaptureError.noWindow }
        return any
    }

    public static func configuration(for filter: SCContentFilter,
                                     maxLongEdge: Int? = nil) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // pointPixelScale is a Float; everything else here is CGFloat. Widen
        // once, explicitly, rather than letting inference pick a winner.
        let scale = CGFloat(filter.pointPixelScale)
        let w = filter.contentRect.width * scale
        let h = filter.contentRect.height * scale
        if let maxLongEdge, Swift.max(w, h) > CGFloat(maxLongEdge) {
            let shrink = CGFloat(maxLongEdge) / Swift.max(w, h)
            config.width = Int((w * shrink).rounded())
            config.height = Int((h * shrink).rounded())
        } else {
            config.width = Int(w.rounded())
            config.height = Int(h.rounded())
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.capturesAudio = false
        // Depth 3 is the documented minimum. Deeper only buys history we
        // never look at — we always want the newest frame, never an older one.
        config.queueDepth = 3
        return config
    }

    // MARK: - Warm stream

    /// Starts the stream and returns only once a first `.complete` frame has
    /// landed, so the caller genuinely has a warm stream rather than a
    /// started one. The returned value is the cold-start cost.
    @discardableResult
    public func start(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> Double {
        let t0 = Mono.nowNs()
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await s.startCapture()
        stream = s
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if latest != nil { lock.unlock(); c.resume(); return }
            firstFrameContinuation = c
            lock.unlock()
        }
        return Mono.msSince(t0)
    }

    public func stop() async {
        guard let s = stream else { return }
        try? await s.stopCapture()
        stream = nil
    }

    /// The newest complete frame, with its age. Never blocks.
    public func latestFrame() throws -> Frame {
        lock.lock()
        defer { lock.unlock() }
        guard stream != nil else { throw CaptureError.notStarted }
        guard let f = latest else { throw CaptureError.noFrameYet }
        return f
    }

    // MARK: - Materialisation

    /// Pixel buffer → `CGImage`, optionally cropped. Cropping to the target
    /// window instead of feeding a whole 5K display is itself a large
    /// accuracy win for the vision fallback, so it belongs on the measured
    /// path rather than bolted on later.
    public func materialize(_ frame: Frame, cropPixels: CGRect? = nil) throws -> CGImage {
        var image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        if let crop = cropPixels {
            // CIImage is bottom-left origin; the crop arrives top-left.
            let h = image.extent.height
            let flipped = CGRect(x: crop.minX, y: h - crop.maxY,
                                 width: crop.width, height: crop.height)
            image = image.cropped(to: flipped)
            guard !image.extent.isEmpty else { throw CaptureError.conversionFailed }
            image = image.transformed(by: .init(translationX: -image.extent.minX,
                                                y: -image.extent.minY))
        }
        guard let cg = ciContext.createCGImage(image, from: image.extent) else {
            throw CaptureError.conversionFailed
        }
        return cg
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }

        // .idle means "nothing changed, here is a heartbeat with no pixels".
        // Counting these is how we learn how often a still screen would have
        // starved a next-frame-please design.
        guard status == .complete else {
            if status == .idle { lock.lock(); idleFrames += 1; lock.unlock() }
            return
        }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var contentRect = CGRect.zero
        if let dict = info[.contentRect] as? [String: Any] {
            contentRect = CGRect(dictionaryRepresentation: dict as CFDictionary) ?? .zero
        }
        let scale = (info[.contentScale] as? CGFloat) ?? 1

        lock.lock()
        completeFrames += 1
        latest = Frame(pixelBuffer: pixels, capturedAtNs: Mono.nowNs(),
                       contentRect: contentRect, contentScale: scale)
        let waiter = firstFrameContinuation
        firstFrameContinuation = nil
        lock.unlock()
        waiter?.resume()
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("ScreenCoach: capture stream stopped: \(error.localizedDescription)")
    }
}

/// Compare two captures of the same scene.
///
/// Exists to test one load-bearing assumption. The warm-stream design hands
/// out the newest *complete* frame, which on a still screen can be hundreds
/// of milliseconds old. That is only safe if staleness is evidence of
/// stillness — ScreenCaptureKit emits a complete frame when content changes,
/// so an old frame should mean "nothing has changed since", not "you are
/// looking at the past". If that holds, the age number is harmless. If it
/// does not, the whole capture design has to wait for a fresh frame and the
/// budget changes. So it gets measured rather than assumed.
public enum FrameCompare {

    /// Fraction of pixels that differ beyond `tolerance`, sampled on a
    /// downscaled grid — enough to catch any visible change without paying
    /// for a full-resolution diff.
    public static func differenceFraction(_ a: CGImage, _ b: CGImage,
                                          grid: Int = 128, tolerance: Int = 8) -> Double? {
        guard let ga = gray(a, grid: grid), let gb = gray(b, grid: grid) else { return nil }
        var differing = 0
        for i in 0..<ga.count where abs(Int(ga[i]) - Int(gb[i])) > tolerance {
            differing += 1
        }
        return Double(differing) / Double(ga.count)
    }

    /// Difference after searching for the best alignment.
    ///
    /// Necessary because `SCStream` and `SCScreenshotManager` do **not** place
    /// window content identically inside the output buffer for the same
    /// filter — measured here at a ~38×42 px offset plus letterboxing. Diffing
    /// them raw reports ~30% of pixels changed on an idle window, which reads
    /// as "the screen is changing constantly" when it is really "these two
    /// APIs disagree about framing". Returns the residual difference once that
    /// disagreement is factored out, plus the shift that was needed.
    public static func alignedDifference(_ a: CGImage, _ b: CGImage,
                                         grid: Int = 128, tolerance: Int = 8,
                                         maxShift: Int = 12)
        -> (fraction: Double, shift: (x: Int, y: Int))? {
        guard let ga = gray(a, grid: grid), let gb = gray(b, grid: grid) else { return nil }
        var best = (fraction: Double.infinity, shift: (x: 0, y: 0))
        for dy in -maxShift...maxShift {
            for dx in -maxShift...maxShift {
                var differing = 0, counted = 0
                for y in 0..<grid {
                    let sy = y + dy
                    guard sy >= 0, sy < grid else { continue }
                    for x in 0..<grid {
                        let sx = x + dx
                        guard sx >= 0, sx < grid else { continue }
                        counted += 1
                        if abs(Int(ga[y * grid + x]) - Int(gb[sy * grid + sx])) > tolerance {
                            differing += 1
                        }
                    }
                }
                guard counted > grid * grid / 2 else { continue }
                let f = Double(differing) / Double(counted)
                if f < best.fraction { best = (f, (dx, dy)) }
            }
        }
        return best.fraction.isFinite ? best : nil
    }

    private static func gray(_ image: CGImage, grid: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: grid * grid)
        guard let ctx = CGContext(
            data: &buffer, width: grid, height: grid, bitsPerComponent: 8,
            bytesPerRow: grid, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: grid, height: grid))
        return buffer
    }
}

// MARK: - One-shot paths

public enum OneShotCapture {

    /// macOS 14+ single-frame capture. No stream lifecycle at all.
    public static func screenshot(filter: SCContentFilter,
                                  config: SCStreamConfiguration) async throws -> CGImage {
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// WindowPet's shipped approach, kept as the honest baseline: spawn
    /// `/usr/sbin/screencapture`, write a PNG to disk, read it back.
    public static func viaScreencaptureTool(longEdge: Int? = 1568) -> CGImage? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("coach-bench-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-t", "png", tmp.path]
        do {
            try p.run()
            p.waitUntilExit()
        } catch { return nil }
        guard p.terminationStatus == 0 else { return nil }

        if let longEdge {
            let r = Process()
            r.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            r.arguments = ["-Z", String(longEdge), tmp.path]
            r.standardOutput = FileHandle.nullDevice
            r.standardError = FileHandle.nullDevice
            try? r.run()
            r.waitUntilExit()
        }
        guard let data = try? Data(contentsOf: tmp),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }
}

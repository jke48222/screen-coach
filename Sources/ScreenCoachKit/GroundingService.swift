import CoreGraphics
import Foundation
import ImageIO
import ScreenCoachCore

/// Talks to the Holo1.5 sidecar.
///
/// Started lazily and never eagerly: the model costs ~5.6 GB resident, and on a
/// 24 GB machine that is not something to hold for a user whose apps all expose
/// good accessibility trees and who therefore never needs it. The first AX miss
/// pays the ~0.5 s load; everything after that is warm.
///
/// Failure here is expected and survivable. There may be no Python, no MLX, no
/// weights on disk. The coach must degrade to accessibility-only rather than
/// break, so every path returns nil instead of throwing into the UI.
public final class GroundingService {

    public struct Result {
        public let point: ScreenPoint
        public let ttftMs: Double
        public let totalMs: Double
        public let imageTokens: Int
    }

    public enum State: Equatable {
        case notStarted
        case loading
        case ready(model: String, loadSeconds: Double)
        case failed(String)
    }

    public private(set) var state: State = .notStarted

    private var process: Process?
    private var toChild: FileHandle?
    private var fromChild: FileHandle?
    private var buffer = Data()
    private let lock = NSLock()
    private var nextID = 1

    private let serverScript: URL
    private let modelPath: String
    private let scratch: URL

    /// Hard ceiling on one grounding call. Measured worst case is ~7 s on a
    /// full frame; beyond 20 s something is wrong and the user should get an
    /// answer from the tree rather than a spinner.
    public var timeout: TimeInterval = 20

    public init(serverScript: URL, modelPath: String) {
        self.serverScript = serverScript
        self.modelPath = modelPath
        self.scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("screencoach-frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch,
                                                 withIntermediateDirectories: true)
    }

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    // MARK: - Lifecycle

    /// Blocks until the model is loaded or the attempt fails. Callers run this
    /// off the main thread; it is only ever paid once.
    @discardableResult
    public func startIfNeeded() -> Bool {
        lock.lock()
        if case .ready = state { lock.unlock(); return true }
        if case .loading = state { lock.unlock(); return false }
        guard FileManager.default.fileExists(atPath: serverScript.path) else {
            state = .failed("holo_server.py not found at \(serverScript.path)")
            lock.unlock(); return false
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            state = .failed("no model at \(modelPath) — vision fallback disabled")
            lock.unlock(); return false
        }
        state = .loading
        lock.unlock()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", serverScript.path, modelPath]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            lock.lock(); state = .failed("could not launch python3: \(error)"); lock.unlock()
            return false
        }
        process = p
        toChild = inPipe.fileHandleForWriting
        fromChild = outPipe.fileHandleForReading

        guard let hello = readLine(timeout: 180) else {
            lock.lock(); state = .failed("sidecar did not report ready"); lock.unlock()
            return false
        }
        if let ready = hello["ready"] as? Bool, ready {
            lock.lock()
            state = .ready(model: hello["model"] as? String ?? modelPath,
                           loadSeconds: hello["load_s"] as? Double ?? 0)
            lock.unlock()
            return true
        }
        lock.lock()
        state = .failed(hello["error"] as? String ?? "sidecar failed to load")
        lock.unlock()
        return false
    }

    public func shutdown() {
        if let toChild {
            try? toChild.write(contentsOf: Data("{\"op\":\"quit\"}\n".utf8))
        }
        process?.terminate()
        process = nil
        toChild = nil
        fromChild = nil
        state = .notStarted
    }

    deinit { shutdown() }

    // MARK: - Grounding

    /// Ground `query` in `image`, optionally restricted to `crop`.
    ///
    /// `crop` and the returned point are both in the image's own pixel space.
    /// The caller converts to screen coordinates, because only the caller knows
    /// which display the frame came from — and that index has to survive the
    /// whole round trip or the pointer lands on the wrong monitor.
    public func ground(image: CGImage, query: String, cropPixels: CGRect?,
                       screenIndex: Int, displayScale: CGFloat,
                       displayOrigin: CGPoint) -> Result? {
        guard isReady else { return nil }

        let frameURL = scratch.appendingPathComponent("frame-\(UUID().uuidString).png")
        guard write(image, to: frameURL) else { return nil }
        // The frame is deleted the moment the answer comes back. Nothing is
        // persisted by default — that is the headline privacy claim and it has
        // to be true in the code, not only in the README.
        defer { try? FileManager.default.removeItem(at: frameURL) }

        lock.lock(); let id = nextID; nextID += 1; lock.unlock()
        var request: [String: Any] = ["id": id, "image": frameURL.path, "query": query]
        if let c = cropPixels {
            request["crop"] = [c.minX, c.minY, c.width, c.height]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let toChild else { return nil }
        try? toChild.write(contentsOf: data + Data("\n".utf8))

        guard let response = readLine(timeout: timeout) else { return nil }
        if let error = response["error"] as? String {
            NSLog("ScreenCoach: grounding failed — \(error)")
            return nil
        }
        guard let px = response["x"] as? Double, let py = response["y"] as? Double else {
            return nil
        }

        // Image pixels → display points → global CG, keeping the screen index.
        let cg = CGPoint(x: displayOrigin.x + px / displayScale,
                         y: displayOrigin.y + py / displayScale)
        return Result(
            point: ScreenPoint(cg: cg, screenIndex: screenIndex),
            ttftMs: response["ttft_ms"] as? Double ?? 0,
            totalMs: response["total_ms"] as? Double ?? 0,
            imageTokens: response["tokens"] as? Int ?? 0
        )
    }

    // MARK: - Plumbing

    private func write(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Reads one newline-delimited JSON object, with a deadline.
    ///
    /// `availableData` blocks until *something* arrives, so the deadline is
    /// enforced between reads rather than inside one. That is enough: the
    /// sidecar either streams or it is wedged, and a wedged sidecar gets
    /// abandoned rather than waited on forever.
    private func readLine(timeout: TimeInterval) -> [String: Any]? {
        guard let fromChild else { return nil }
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    return obj
                }
                continue
            }
            guard Date() < deadline else { return nil }
            let chunk = fromChild.availableData
            if chunk.isEmpty {
                // EOF — the sidecar died.
                lock.lock(); state = .failed("sidecar exited"); lock.unlock()
                return nil
            }
            buffer.append(chunk)
        }
    }

    public var statusLine: String {
        switch state {
        case .notStarted: return "vision: not loaded (loads on first AX miss)"
        case .loading: return "vision: loading…"
        case .ready(let m, let s):
            return String(format: "vision: ready (%@, %.1fs)",
                          (m as NSString).lastPathComponent, s)
        case .failed(let why): return "vision: unavailable — \(why)"
        }
    }
}

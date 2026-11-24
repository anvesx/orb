@preconcurrency import AVFoundation
import LiveKit
import os

/// A test voice for live checks without a person: with `ORB_TEST_VOICE=<folder>`, each audio file put in the folder is
/// played into the call's microphone stream, after echo cancellation, then deleted. `say -o` writes such a file; the
/// speakers can't be used, because echo cancellation removes what the Mac itself plays.
final class TestVoice: NSObject, AudioCustomProcessingDelegate, @unchecked Sendable {
    let folder: URL
    let lock = OSAllocatedUnfairLock(initialState: (rate: 48_000.0, queue: [Float](), start: 0))
    var timer: DispatchSourceTimer?

    static func install() {
        guard let path = ProcessInfo.processInfo.environment["ORB_TEST_VOICE"], !path.isEmpty else { return }
        let voice = TestVoice(folder: URL(fileURLWithPath: path))
        AudioManager.shared.capturePostProcessingDelegate = voice
        shared = voice
        trace.warning("test voice on: files in \(path, privacy: .public) go into the microphone")
    }

    nonisolated(unsafe) static var shared: TestVoice?

    init(folder: URL) {
        self.folder = folder
        super.init()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now(), repeating: 0.3)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func poll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.path < $1.path }) where ["wav", "aiff", "aif", "caf"].contains(url.pathExtension) {
            let rate = lock.withLock { $0.rate }
            if let samples = Self.load(url, rate: rate) {
                lock.withLock { $0.queue += samples }
                trace.debug("test voice: \(url.lastPathComponent, privacy: .public), \(samples.count) samples")
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Mono samples at `rate`, in the 16-bit range that WebRTC's audio processing uses.
    static func load(_ url: URL, rate: Double) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: out),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil else { return nil }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * rate / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: capacity) else { return nil }
        var given = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        guard let data = output.floatChannelData?[0] else { return nil }
        return (0..<Int(output.frameLength)).map { data[$0] * 32_767 }
    }

    var audioProcessingName: String { "orb.test-voice" }

    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
        lock.withLock { $0.rate = Double(sampleRateHz) }
    }

    func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        let frames = audioBuffer.frames
        let chunk: [Float]? = lock.withLock { s in
            guard s.start < s.queue.count else { return nil }
            let n = min(frames, s.queue.count - s.start)
            let out = Array(s.queue[s.start..<(s.start + n)])
            s.start += n
            if s.start >= s.queue.count { s.queue = []; s.start = 0 }
            return out
        }
        guard let chunk else { return }
        for c in 0..<audioBuffer.channels {
            let p = audioBuffer.rawBuffer(forChannel: c)
            for i in 0..<frames { p[i] = i < chunk.count ? chunk[i] : 0 }
        }
    }

    func audioProcessingRelease() {}
}

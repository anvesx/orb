import AVFoundation
import LiveKit
import OrbKit

/// One voice call over LiveKit: the native form of the web page's `talk()`. The room, the muted microphone, the
/// agent's state, the captions (text streams on `lk.transcription`), the worker's events (data on `orb.bench`) and
/// the audio levels.
public actor LiveKitTransport: VoiceTransport {
    public nonisolated let levels = AudioLevels()
    var room: Room?
    var silence: Task<Void, Never>?
    /// After a release the track sends silence this long before it mutes: a muted track sends nothing, and the model's
    /// turn detection (700 ms of silence, gemini_live.py) would wait for an end of the turn that never comes.
    static let endOfTurnSilence: Duration = .milliseconds(1200)

    public init() {}

    public func connect(url: String, token: String) async throws -> AsyncStream<VoiceEvent> {
        await disconnect()
        let (stream, events) = AsyncStream<VoiceEvent>.makeStream()
        let room = Room()
        let observer = RoomObserver(events: events, levels: levels)
        room.add(delegate: observer)
        // unmuting stays instant, so a press never loses its first syllable (mac-app.md 6.3)
        try AudioManager.shared.set(microphoneMuteMode: .voiceProcessing)
        try await room.registerTextStreamHandler(for: "lk.transcription") { [weak room] reader, sender in
            await observer.transcription(reader, mine: sender == room?.localParticipant.identity)
        }
        let capture = AudioCaptureOptions(echoCancellation: true, autoGainControl: true, noiseSuppression: true)
        try await room.connect(url: url, token: token, roomOptions: RoomOptions(defaultAudioCaptureOptions: capture))
        let mic = try await room.localParticipant.setMicrophone(enabled: true)
        try await room.localParticipant.setMicrophone(enabled: false)
        (mic?.track as? LocalAudioTrack)?.add(audioRenderer: observer.you)
        for p in room.remoteParticipants.values { observer.seen(p) }
        self.room = room
        return stream
    }

    public func setMicrophone(_ on: Bool) async throws {
        silence?.cancel()
        if on {
            AudioManager.shared.isMicrophoneMuted = false
            try await room?.localParticipant.setMicrophone(enabled: true)
            return
        }
        AudioManager.shared.isMicrophoneMuted = true  // the voice-processing input sends zeros: the end of the turn
        silence = Task {
            try? await Task.sleep(for: Self.endOfTurnSilence)
            guard !Task.isCancelled else { return }
            _ = try? await room?.localParticipant.setMicrophone(enabled: false)
        }
    }

    public func disconnect() async {
        silence?.cancel()
        await room?.disconnect()
        room = nil
        levels.set(you: 0)
        levels.set(orb: 0)
    }
}

/// Turns room callbacks into `VoiceEvent`s. The callbacks come on LiveKit's queues; the stream is thread-safe.
final class RoomObserver: RoomDelegate, Sendable {
    let events: AsyncStream<VoiceEvent>.Continuation
    let you: Meter
    let orb: Meter

    init(events: AsyncStream<VoiceEvent>.Continuation, levels: AudioLevels) {
        self.events = events
        you = Meter { levels.set(you: $0) }
        orb = Meter { levels.set(orb: $0) }
    }

    func seen(_ p: Participant) {
        guard p.isAgent else { return }
        events.yield(.agentJoined)
        events.yield(.agentState(OrbKit.AgentState(attribute: p.attributes["lk.agent.state"] ?? "")))
    }

    func transcription(_ reader: TextStreamReader, mine: Bool) async {
        let segment = reader.info.attributes["lk.segment_id"] ?? reader.info.id
        do {
            if mine {  // each update holds the whole text so far
                let text = try await reader.readAll()
                events.yield(.yourWords(segment: segment, text: text,
                                        final: reader.info.attributes["lk.transcription_final"] == "true"))
            } else {
                for try await chunk in reader { events.yield(.orbWords(segment: segment, chunk: chunk)) }
            }
        } catch {}
    }

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) { seen(participant) }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        if participant.isAgent { events.yield(.agentState(.idle)) }
    }

    func room(_ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]) {
        guard participant.isAgent, let raw = attributes["lk.agent.state"] else { return }
        events.yield(.agentState(OrbKit.AgentState(attribute: raw)))
    }

    func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        events.yield(.youSpeaking(participants.contains { $0 is LocalParticipant }))
    }

    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        (publication.track as? RemoteAudioTrack)?.add(audioRenderer: orb)
    }

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String,
              encryptionType: EncryptionType) {
        if topic == BenchEvent.topic, let e = BenchEvent(data: data) { events.yield(.bench(e)) }
    }

    func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) { events.yield(.reconnecting) }
    func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) { events.yield(.reconnected) }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        events.yield(.disconnected(error?.localizedDescription))
        events.finish()
    }
}

/// The level of an audio track, from each buffer's RMS on a −50…−10 dB scale. It runs on the audio thread.
final class Meter: NSObject, AudioRenderer, Sendable {
    let report: @Sendable (Float) -> Void

    init(report: @escaping @Sendable (Float) -> Void) {
        self.report = report
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let n = Int(pcmBuffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        if let f = pcmBuffer.floatChannelData?[0] {
            for i in 0..<n { sum += f[i] * f[i] }
        } else if let s = pcmBuffer.int16ChannelData?[0] {
            for i in 0..<n { let v = Float(s[i]) / 32768; sum += v * v }
        } else { return }
        let db = 10 * log10(max(sum / Float(n), 1e-10))
        report(min(max((db + 50) / 40, 0), 1))
    }
}

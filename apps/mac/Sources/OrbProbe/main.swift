import Foundation
import OrbKit
import OrbVoice

// orb-probe [seconds] [--talk]: one Gemini Live call through the agent service, without the app. It prints the agent's
// states, the captions and the worker's events. The microphone stays muted unless --talk is given.
let args = CommandLine.arguments.dropFirst()
let seconds = args.first.flatMap(Double.init) ?? 20
let api = AgentClient(base: URL(string: ProcessInfo.processInfo.environment["ORB_URL"] ?? "http://127.0.0.1:8100")!)
let transport = LiveKitTransport()
let start = Date()
func say(_ line: String) { print(String(format: "%6.2f s  ", Date().timeIntervalSince(start)) + line) }

do {
    guard let status = try await api.voiceStatus() else { throw AgentError(status: 503, message: "voice is off") }
    say("voice status: livekit \(String(describing: status.livekit)), worker \(String(describing: status.worker))")
    let session = try await api.createSession(topic: "orb probe", config: SessionConfig(),
                                              sources: [Source(name: "probe.md", kind: .markdown, text: "# Probe\nThe code word is heliotrope.")])
    say("session \(session.id), sources \(session.sources.map { "\($0.name) \($0.used)/\($0.chars)" })")
    let token = try await api.token(session: session.id)
    let events = try await transport.connect(url: token.url, token: token.token)
    say("joined \(token.room)")
    if args.contains("--talk") { try await transport.setMicrophone(true); say("microphone on") }
    let reader = Task {
        for await e in events { say("\(e)") }
    }
    try await Task.sleep(for: .seconds(seconds))
    say("levels: you \(transport.levels.you), orb \(transport.levels.orb)")
    await transport.disconnect()
    reader.cancel()
    say("done")
} catch {
    say("failed: \(error.localizedDescription)")
    exit(1)
}

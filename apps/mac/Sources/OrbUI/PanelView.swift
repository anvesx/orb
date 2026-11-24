import OrbKit
import SwiftUI

/// The panel: the orb and its state, the captions, the context of the call, a warning when there is one, and talk.
struct PanelView: View {
    let model: AppModel
    let actions: PanelActions

    var body: some View {
        let mood = Mood(model.call, youSpeaking: model.youSpeaking)
        VStack(alignment: .leading, spacing: 18) {
            header
            VStack(spacing: 10) {
                OrbView(mood: mood) { [levels = model.levels] in mood == .speaking ? levels.orb : levels.you }
                    .frame(width: 132, height: 132)
                Text(stateLine(mood))
                    .font(Theme.state)
                    .foregroundStyle(mood == .idle ? Theme.ink2 : mood.tint)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            .frame(maxWidth: .infinity)
            CaptionsView(captions: model.captions, hint: "Hold \(model.talkShortcut) and talk.")
            ContextView(model: model, pickFiles: actions.pickFiles)
            if let warning = model.warning {
                WarningView(text: warning)
            }
            footer
        }
        .padding(18)
        .frame(width: Theme.panelWidth)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
    }

    var header: some View {
        HStack(spacing: 8) {
            Logo().frame(width: 18, height: 18)
            Text("orb").font(Theme.wordmark).foregroundStyle(Theme.ink)
            Spacer()
            ServiceDot(up: model.serviceUp)
            Button(action: actions.openInspector) {
                Image(systemName: "rectangle.split.2x1").font(.system(size: 13)).foregroundStyle(Theme.ink2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Inspector")
            Button(action: actions.openSettings) {
                Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(Theme.ink2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
    }

    func stateLine(_ mood: Mood) -> String {
        if model.call.reconnecting { return "Reconnecting…" }
        if mood == .idle { return model.sessionID == nil ? "Ready" : "Ready · the call ended" }
        if mood == .listening && model.call.micOn { return model.youSpeaking ? "Hearing you…" : "Speak now" }
        return mood.words
    }

    var footer: some View {
        HStack(spacing: 10) {
            TalkButton(model: model, shortcut: model.talkShortcut)
            Spacer()
            if model.call.phase != .idle {
                Button("Hang up") { model.hangUp() }
                    .buttonStyle(PillStyle(tint: Theme.alert))
            } else if model.sessionID != nil {
                Button("New session") { model.newSession() }
                    .buttonStyle(PillStyle(tint: Theme.ink2))
            }
        }
    }
}

/// Press and hold to talk, like the shortcut.
struct TalkButton: View {
    let model: AppModel
    let shortcut: String
    @State private var held = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: held ? "waveform" : "mic.fill").font(.system(size: 12, weight: .semibold))
            Text(held ? "Listening" : "Hold to talk").font(.system(size: 13, weight: .semibold))
            Text(shortcut).font(Theme.meta).foregroundStyle(Theme.canvas.opacity(0.6))
        }
        .foregroundStyle(Theme.canvas)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Capsule().fill(held ? Theme.listen : Theme.ink))
        .scaleEffect(held ? 0.97 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: held)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !held { held = true; model.talkDown() } }
            .onEnded { _ in held = false; model.talkUp() })
        .accessibilityLabel("Hold to talk")
        .accessibilityAddTraits(.isButton)
    }
}

struct PillStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.22 : 0.12)))
    }
}

struct ServiceDot: View {
    var up: Bool?

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(up == true ? Theme.listen : up == false ? Theme.alert : Theme.idle).frame(width: 6, height: 6)
            Text(up == true ? "service" : up == false ? "service off" : "checking").font(Theme.meta).foregroundStyle(Theme.ink2)
        }
        .accessibilityElement(children: .combine)
    }
}

struct WarningView: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.alert)
            Text(text).font(Theme.body).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(Theme.alert.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.alert.opacity(0.35), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

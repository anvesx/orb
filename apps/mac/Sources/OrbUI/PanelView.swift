import OrbKit
import SwiftUI

/// The panel: the orb and its state, the captions, what orb can use, a warning when there is one, and talk.
struct PanelView: View {
    let model: AppModel
    let actions: PanelActions

    var body: some View {
        let mood = Mood(model.call, youSpeaking: model.youSpeaking)
        VStack(alignment: .leading, spacing: 18) {
            header
            VStack(spacing: 10) {
                OrbView(mood: mood) { [levels = model.levels] in mood == .speaking ? levels.orb : levels.you }
                    .frame(width: 120, height: 120)
                Text(stateLine(mood))
                    .font(Theme.state)
                    .foregroundStyle(mood == .idle ? Theme.ink2 : mood.tint)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            .frame(maxWidth: .infinity)
            CaptionsView(captions: model.captions, hint: "Look at anything, hold \(model.talkShortcut) and ask about it."
                         + (model.doubleTapBlocked == nil ? " Or double-tap ⌥ and just talk." : ""))
            SensesRow(model: model, allowScreen: actions.allowScreen)
            if let warning = model.warning {
                WarningView(text: warning)
            } else if let blocked = model.doubleTapBlocked, model.settings.doubleTapOption {
                WarningView(text: blocked)
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
            Button(action: actions.openSettings) {
                Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(Theme.ink2)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
    }

    func stateLine(_ mood: Mood) -> String {
        if model.call.reconnecting { return "Reconnecting…" }
        if mood == .idle { return "Ready" }
        if mood == .ready { return "Ready · hold \(model.talkShortcut)" + (model.doubleTapBlocked == nil ? " or double-tap ⌥" : "") }
        if model.call.handsFree && mood == .listening { return model.youSpeaking ? "Hearing you…" : "Hands-free · double-tap ⌥ to stop" }
        if mood == .listening { return model.youSpeaking ? "Hearing you…" : "Speak now" }
        return mood.words
    }

    var footer: some View {
        HStack(spacing: 10) {
            TalkButton(model: model, shortcut: model.talkShortcut)
            Spacer()
            if model.call.phase != .idle {
                Button("Hang up") { model.hangUp() }
                    .buttonStyle(PillStyle(tint: Theme.alert))
            }
        }
    }
}

/// One quiet line: what orb can use besides your voice. The screen (and what it read there) and Google Search.
struct SensesRow: View {
    let model: AppModel
    let allowScreen: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            screen
            if model.settings.webSearch {
                Sense(icon: "globe", text: "Search", live: false)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder var screen: some View {
        if !model.settings.screen {
            Sense(icon: "eye.slash", text: "Screen off", live: false)
        } else if model.screenAllowed == false {
            Button(action: allowScreen) {
                Sense(icon: "eye.trianglebadge.exclamationmark", text: "Allow screen access", live: false, tint: Theme.speak2)
            }
            .buttonStyle(.plain)
            .help("orb can't see your screen. Allow orb in System Settings › Privacy & Security › Screen Recording.")
        } else {
            Sense(icon: "eye", text: model.sharing ? (model.seeing.map { "Sees \($0)" } ?? "Sees your screen")
                                                   : "Sees your screen when you talk", live: model.sharing)
        }
    }
}

struct Sense: View {
    var icon: String
    var text: String
    var live: Bool
    var tint: Color = Theme.ink2

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
            if live {
                Circle().fill(Theme.listen).frame(width: 5, height: 5)
                    .shadow(color: Theme.listen, radius: 3)
            }
        }
        .foregroundStyle(live ? Theme.ink : tint)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(live ? Theme.listen.opacity(0.4) : Theme.line, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
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

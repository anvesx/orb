import OrbKit
import SwiftUI

/// The black capsule under the menu bar: a small orb and the state. A click opens the panel; when it is open, the
/// panel hangs from it.
public struct IslandView: View {
    let model: AppModel
    @Binding var expanded: Bool
    let actions: PanelActions

    public init(model: AppModel, expanded: Binding<Bool>, actions: PanelActions) {
        self.model = model
        self._expanded = expanded
        self.actions = actions
    }

    public var body: some View {
        let mood = Mood(model.call, youSpeaking: model.youSpeaking)
        VStack(spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    OrbView(mood: mood) { [levels = model.levels] in mood == .speaking ? levels.orb : levels.you }
                        .frame(width: 20, height: 20)
                    Text(mood == .idle ? "orb" : mood.words)
                        .font(mood == .idle ? Theme.wordmark : Theme.state)
                        .foregroundStyle(mood == .idle ? Theme.ink : mood.tint)
                        .contentTransition(.opacity)
                    if model.warning != nil && !expanded {
                        Circle().fill(Theme.alert).frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Capsule().fill(Theme.canvas))
                .overlay(Capsule().strokeBorder(mood == .idle ? Theme.line : mood.tint.opacity(0.55), lineWidth: 1))
                .shadow(color: mood == .idle ? .clear : mood.tint.opacity(0.35), radius: 10)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Close orb" : "Open orb")
            .accessibilityValue(mood.words)

            if expanded {
                PanelView(model: model, actions: actions)
                    .transition(.asymmetric(insertion: .scale(scale: 0.92, anchor: .top).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: expanded)
        .animation(.easeOut(duration: 0.25), value: mood)
        .preferredColorScheme(.dark)
    }
}

/// What the panel asks of the app: windows and pickers live there.
public struct PanelActions {
    public var pickFiles: () -> Void
    public var openSettings: () -> Void
    public var talkShortcut: String

    public init(pickFiles: @escaping () -> Void, openSettings: @escaping () -> Void, talkShortcut: String) {
        self.pickFiles = pickFiles
        self.openSettings = openSettings
        self.talkShortcut = talkShortcut
    }
}

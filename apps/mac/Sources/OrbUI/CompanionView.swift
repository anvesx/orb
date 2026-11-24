import OrbKit
import SwiftUI

/// The small orb next to the pointer during a call: a level ring while you speak or orb speaks, the orb's colours for
/// its state, and a bubble with the latest words.
public struct CompanionView: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let mood = Mood(model.call, youSpeaking: model.youSpeaking)
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                LevelRing(mood: mood, levels: model.levels)
                OrbView(mood: mood) { [levels = model.levels] in mood == .speaking ? levels.orb : levels.you }
                    .frame(width: 28, height: 28)
                    .shadow(color: mood.tint.opacity(0.6), radius: 6)
            }
            .frame(width: 40, height: 40)
            if let label = model.pointer?.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.canvas)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.speak2))
                    .shadow(color: Theme.speak2.opacity(0.5), radius: 8)
                    .transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
            } else if model.settings.bubble, let words = bubble(mood) {
                Text(words)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(mood == .speaking ? Theme.ink : Theme.ink2)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: 220, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.canvas.opacity(0.92)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(mood.tint.opacity(0.5), lineWidth: 0.5))
                    .transition(.opacity)
            }
        }
        .fixedSize()
        .animation(.easeOut(duration: 0.2), value: mood)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.pointer?.id)
        .accessibilityHidden(true)
    }

    func bubble(_ mood: Mood) -> String? {
        switch mood {
        case .speaking: model.captions.orb.isEmpty ? nil : model.captions.orb
        case .listening: model.captions.youFinal || model.captions.you.isEmpty ? nil : model.captions.you
        default: nil
        }
    }
}

/// A ring that grows with the level of whoever speaks.
struct LevelRing: View {
    var mood: Mood
    var levels: AudioLevels
    @State private var smoother = Smoother()  // a reference: it steps each frame without a state update

    var body: some View {
        TimelineView(.animation(paused: mood != .listening && mood != .speaking)) { _ in
            let level = CGFloat(smoother.value.step(mood == .speaking ? levels.orb : levels.you))
            Circle()
                .strokeBorder(mood.tint, lineWidth: 1.5)
                .scaleEffect(0.75 + 0.35 * level)
                .opacity(0.25 + 0.75 * level)
        }
    }
}

@MainActor
final class Smoother {
    var value = LevelSmoother(attack: 0.6, release: 0.12)
}

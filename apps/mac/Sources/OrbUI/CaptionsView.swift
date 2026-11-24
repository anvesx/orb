import OrbKit
import SwiftUI

/// What you said and what orb says. Your words are grey while they are still interim.
struct CaptionsView: View {
    var captions: Captions
    var hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if captions.you.isEmpty && captions.orb.isEmpty {
                Text(hint).font(Theme.caption).foregroundStyle(Theme.ink2)
            } else {
                line("YOU", captions.you, color: captions.youFinal ? Theme.ink : Theme.ink2, tint: Theme.listen)
                line("ORB", captions.orb, color: Theme.ink, tint: Theme.speak)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
    }

    @ViewBuilder
    func line(_ who: String, _ text: String, color: Color, tint: Color) -> some View {
        if !text.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(who).font(Theme.label).tracking(1.2).foregroundStyle(tint).frame(width: 30, alignment: .leading)
                Text(text).font(Theme.caption).foregroundStyle(color).lineLimit(4).truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

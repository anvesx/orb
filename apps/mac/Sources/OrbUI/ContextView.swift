import OrbKit
import SwiftUI

/// What orb knows in this call besides your voice: chips, a menu to add more, and how much of each file it read.
struct ContextView: View {
    let model: AppModel
    let pickFiles: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONTEXT").font(Theme.label).tracking(1.2).foregroundStyle(Theme.ink2)
            FlowRow(spacing: 6) {
                ForEach(model.context) { item in Chip(item: item) { model.remove(item) } }
                addMenu
            }
            if !model.sourceUses.isEmpty {
                Text(usage).font(Theme.meta).foregroundStyle(Theme.ink2).lineLimit(2)
            } else if model.context.isEmpty {
                Text("Nothing yet: orb talks about anything. Add files to talk about them.")
                    .font(Theme.meta).foregroundStyle(Theme.ink2)
            }
        }
    }

    var addMenu: some View {
        Menu {
            let open = model.suggestions.filter { !model.context.contains($0) }
            if !open.isEmpty {
                Section("On your Desktop") {
                    ForEach(open.prefix(12)) { item in Button(item.title) { model.add(item) } }
                }
            }
            Button("Choose files or a folder…", action: pickFiles)
        } label: {
            Label("Add", systemImage: "plus").font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
    }

    var usage: String {
        let read = model.sourceUses.filter { $0.used > 0 }
        let part = read.filter { !$0.whole }.count
        let left = model.sourceUses.count - read.count
        var s = "\(read.count) file\(read.count == 1 ? "" : "s") in the call"
        if part > 0 { s += " · \(part) in part" }
        if left > 0 { s += " · \(left) too long to fit" }
        return s
    }
}

struct Chip: View {
    var item: ContextItem
    var remove: () -> Void

    var body: some View {
        let hue = Theme.hue(for: item.title)
        HStack(spacing: 6) {
            Image(systemName: (item.url?.hasDirectoryPath ?? false) ? "folder.fill" : "doc.text.fill").font(.system(size: 10))
            Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(item.title)")
        }
        .foregroundStyle(hue)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(hue.opacity(0.16)))
        .overlay(Capsule().strokeBorder(hue.opacity(0.6), lineWidth: 1))
    }
}

/// Children left to right, wrapping to the next line.
struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, p) in arrange(bounds.width, subviews).points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += row + spacing; row = 0 }
            points.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            row = max(row, s.height)
            widest = max(widest, x - spacing)
        }
        return (points, widest, y + row)
    }
}

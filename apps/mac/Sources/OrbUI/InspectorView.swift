import OrbKit
import SwiftUI

/// The engine's view of the session, as the web page's details show it: the conversation, the next move, the six
/// promises, the debts, the last Jev call, timing and cost, the call's latency table and the worker's events.
public struct InspectorView: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Conversation(engine: model.engine).padding(18)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: model.engine?.messages?.count) { proxy.scrollTo("end") }
            }
            .frame(minWidth: 340, maxWidth: .infinity)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let e = model.engine {
                        NextMove(engine: e)
                        Promises(engine: e)
                        Debts(engine: e)
                        JevCall(engine: e)
                    } else {
                        Text(model.sessionID == nil ? "No session yet. Talk to start one." : "Reading the session…")
                            .foregroundStyle(Theme.ink2)
                    }
                    Latency(log: model.turnLog)
                    Events(lines: model.events)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 420, maxWidth: .infinity)
        }
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
        .background(Theme.canvas)
        .preferredColorScheme(.dark)
        .onAppear { model.inspect(true) }
        .onDisappear { model.inspect(false) }
    }
}

struct Heading: View {
    var text: String
    var body: some View { Text(text.uppercased()).font(Theme.label).tracking(1.2).foregroundStyle(Theme.ink2) }
}

struct Conversation: View {
    var engine: EngineView?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Heading(text: "Conversation")
            let messages = engine?.messages ?? []
            if messages.isEmpty { Text("The conversation appears here when you talk.").foregroundStyle(Theme.ink2) }
            ForEach(messages) { m in
                let human = m.speaker == "human"
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(human ? "You" : "orb").font(.system(size: 11, weight: .semibold)).foregroundStyle(human ? Theme.listen : Theme.speak)
                        if !human, let name = engine?.turn(replying: m.seq)?.decision?.name { Text(name).font(Theme.meta).foregroundStyle(Theme.think) }
                        Text(m.id + (m.channel == "voice" && human ? " · spoken" : "")).font(Theme.meta).foregroundStyle(Theme.ink2)
                        if m.interrupted == true { Text("cut off").font(Theme.meta).foregroundStyle(Theme.alert) }
                    }
                    Text(m.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(human ? Theme.surface : Theme.surface.opacity(0.5)))
            }
        }
    }
}

struct NextMove: View {
    var engine: EngineView

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Heading(text: "Next move")
            if let last = engine.turns?.last, let d = last.decision {
                Text("The \(d.persona ?? d.name ?? "—")").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(Theme.think)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Job").foregroundStyle(Theme.ink2); Text(d.move ?? "—") }
                    GridRow { Text("Why").foregroundStyle(Theme.ink2); Text(d.why ?? "—") }
                    GridRow { Text("Debt").foregroundStyle(Theme.ink2); Text([d.debt ?? "none", d.kind, d.promise].compactMap { $0 }.joined(separator: " · ")) }
                }
                if let c = last.check, let text = c.text {
                    Text("Check of the reply: " + text).foregroundStyle(c.done == true ? Theme.listen : c.done == false ? Theme.alert : Theme.ink2)
                } else if engine.busy == true {
                    Text("Jev reads the reply…").foregroundStyle(Theme.ink2)
                }
            } else {
                Text("No message yet.").foregroundStyle(Theme.ink2)
            }
            HStack(spacing: 6) {
                ForEach(EngineView.stages, id: \.self) { stage in
                    Text(stage).font(Theme.meta)
                        .padding(.horizontal, 8).frame(height: 20)
                        .background(Capsule().fill(stage == engine.stage ? Theme.think.opacity(0.3) : Theme.surface))
                        .foregroundStyle(stage == engine.stage ? Theme.ink : Theme.ink2)
                }
            }
            if let why = engine.stageWhy { Text(why).font(Theme.meta).foregroundStyle(Theme.ink2) }
        }
    }
}

struct Promises: View {
    var engine: EngineView

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Heading(text: "Six promises · due now = target · paid of owed = score")
            let need = engine.need == nil ? nil : engine.turns?.last?.decision?.promise
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(EngineView.promises, id: \.self) { p in
                    let s = engine.scores?[p]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p).font(.system(size: 12, weight: .semibold))
                        Text(EngineView.promiseWords[p] ?? "").font(Theme.meta).foregroundStyle(Theme.ink2)
                        Text((s?.due == true ? "Due now · " : "Not due yet · ") + (s.map { $0.owed > 0 ? "\($0.paid) of \($0.owed) paid" : "no debts yet" } ?? ""))
                            .font(Theme.meta).foregroundStyle(s?.due == true ? Theme.listen : Theme.ink2)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p == need ? Theme.think : .clear, lineWidth: 1))
                    .opacity(s?.due == true ? 1 : 0.6)
                }
            }
        }
    }
}

struct Debts: View {
    var engine: EngineView

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Heading(text: "Debts")
            HStack(alignment: .top, spacing: 8) {
                ForEach([("Waiting", "waiting"), ("Due now", "due"), ("Paid", "paid")], id: \.1) { title, status in
                    let debts = (engine.board ?? []).filter { $0.status == status }
                        .sorted { status == "paid" ? ($0.paid ?? 0) > ($1.paid ?? 0) : false }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(title) \(debts.count)").font(.system(size: 11, weight: .semibold))
                        if debts.isEmpty { Text("None").font(Theme.meta).foregroundStyle(Theme.ink2) }
                        ForEach(debts) { d in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(d.id) · \(d.kind)").font(Theme.meta).foregroundStyle(Theme.ink2)
                                Text(d.about).font(.system(size: 12)).lineLimit(3)
                                Text(d.status == "paid" ? "paid in M\((d.paid ?? 0) + 1)" : d.owner == "both" ? "both sides" : d.owner == "ai" ? "orb owes" : "you owe")
                                    .font(Theme.meta).foregroundStyle(Theme.ink2)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(d.id == engine.need ? Theme.think : .clear, lineWidth: 1))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct JevCall: View {
    var engine: EngineView

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Heading(text: "Last Jev call · timing and cost")
            if let c = engine.lastCall, let qs = c.questions, !qs.isEmpty {
                Text("\(c.id ?? "") · \(c.speaker == "human" ? "you" : "orb") · \(qs.count) questions · \(c.seconds.map { String(format: "%.2f s", $0) } ?? "?") · \(c.tokens ?? 0) tokens")
                    .font(Theme.meta).foregroundStyle(Theme.ink2)
                ForEach(Array(qs.enumerated()), id: \.offset) { _, q in
                    HStack(spacing: 8) {
                        Text(q.label ?? "").font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        Capsule().fill(Theme.surface).frame(width: 90, height: 5)
                            .overlay(alignment: .leading) { Capsule().fill(q.yes == true ? Theme.listen : Theme.ink2).frame(width: 90 * (q.answer ?? 0), height: 5) }
                        Text(String(format: "%.2f", q.answer ?? 0)).font(Theme.meta).foregroundStyle(Theme.ink2)
                    }
                }
            } else if let error = engine.lastCall?.error {
                Text(error).foregroundStyle(Theme.alert)
            } else {
                Text("No call yet.").foregroundStyle(Theme.ink2)
            }
            if let t = engine.turns?.last?.timing {
                Text("Jev reads your message \(t.readHuman.map { String(format: "%.2f s", $0) } ?? "-") · the reply \(t.readAI.map { String(format: "%.2f s", $0) } ?? "-")")
                    .font(Theme.meta).foregroundStyle(Theme.ink2)
            }
            Text("Jev tokens in this chat: \(engine.tokens ?? 0) (about $\(String(format: "%.4f", engine.costUSD ?? 0)))")
                .font(Theme.meta).foregroundStyle(Theme.ink2)
        }
    }
}

struct Latency: View {
    var log: TurnLog

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Heading(text: "This call's turns (seconds)")
            if log.rows.isEmpty {
                Text("No turn yet.").foregroundStyle(Theme.ink2)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow { ForEach(["#", "Turn end", "Jev", "LLM", "TTS", "Total", "Persona"], id: \.self) { Text($0).font(Theme.label).foregroundStyle(Theme.ink2) } }
                    ForEach(Array(log.rows.enumerated()), id: \.offset) { i, r in
                        GridRow {
                            Text("\(i + 1)")
                            ForEach([r.endOfTurn, r.read, r.firstToken, r.firstAudio, r.total].map { $0.map { String(format: "%.2f", $0) } ?? "—" }.enumerated().map { $0 }, id: \.offset) {
                                Text($0.element).fontWeight($0.offset == 4 ? .semibold : .regular)
                            }
                            Text(r.persona ?? "").gridColumnAlignment(.leading)
                        }
                        .font(Theme.meta)
                    }
                }
            }
        }
    }
}

struct Events: View {
    var lines: [String]
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { Text($0.element).font(Theme.meta).foregroundStyle(Theme.ink2).textSelection(.enabled) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Heading(text: "Events (\(lines.count))")
        }
    }
}

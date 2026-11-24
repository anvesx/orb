import OrbKit
import SwiftUI

/// The settings: the service, the voice, the talk shortcut (a view from the app) and the companion.
public struct SettingsView<Shortcut: View>: View {
    @Bindable var model: AppModel
    let shortcut: Shortcut

    public init(model: AppModel, @ViewBuilder shortcut: () -> Shortcut) {
        self.model = model
        self.shortcut = shortcut()
    }

    public var body: some View {
        Form {
            Section("Service") {
                TextField("Agent service", text: $model.settings.serviceURL)
                    .onSubmit { model.refresh() }
                LabeledContent("Status", value: model.serviceUp == true ? "Running" : model.serviceUp == false ? "Not running" : "Checking…")
            }
            Section {
                Picker("Model", selection: $model.settings.geminiModel) {
                    Text("Default").tag(String?.none)
                    ForEach(model.gemini?.models ?? [], id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Picker("Voice", selection: $model.settings.geminiVoice) {
                    Text("Default").tag(String?.none)
                    ForEach(model.gemini?.voices ?? [], id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Toggle("orb personas", isOn: $model.settings.personas)
                Toggle("Google Search", isOn: $model.settings.webSearch)
            } header: {
                Text("Voice (Gemini Live)")
            } footer: {
                Text("orb personas: before each reply, Jev reads what you said and orb's rules choose the role Gemini speaks in. A change applies from the next call.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Let orb see my screen during a call", isOn: $model.settings.screen)
            } header: {
                Text("Screen")
            } footer: {
                Text("During a call orb sees the display under your pointer, reads its text when you ask, and points at what it explains. The screen goes to Gemini, like your voice; nothing is shared outside a call.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Talk") {
                LabeledContent("Hold to talk") { shortcut }
                Toggle("Double-tap ⌥ to talk hands-free", isOn: $model.settings.doubleTapOption)
                Stepper(value: $model.settings.idleMinutes, in: 1...15, step: 1) {
                    LabeledContent("Keep the call up after the last word", value: "\(Int(model.settings.idleMinutes)) min")
                }
            }
            Section("Companion") {
                Toggle("Show orb next to the pointer during a call", isOn: $model.settings.companion)
                Toggle("Show the latest words in a bubble", isOn: $model.settings.bubble)
                    .disabled(!model.settings.companion)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refresh() }
    }
}

import SwiftUI

struct ContentView: View {
    @Environment(AssistantViewModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(spacing: 20) {
                HStack {
                    Label(model.usingGlasses ? "Glasses mic" : model.route,
                          systemImage: model.usingGlasses ? "eyeglasses" : "headphones")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Rush", isOn: $model.rush).fixedSize()
                }

                Text(model.status.label)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.heard.isEmpty {
                            Text(model.heard).foregroundStyle(.secondary)
                        }
                        if !model.answer.isEmpty {
                            Text(model.answer).font(.title3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: model.tapToAsk) {
                    Text(model.status == .speaking || model.status == .thinking ? "Stop" : "Tap to ask")
                        .font(.title.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.status == .speaking || model.status == .thinking ? .red : .accentColor)
            }
            .padding()
            .navigationTitle("Kitchen Copilot")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New shift", action: model.startOver)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear { if !model.isConfigured { showSettings = true } }
        }
    }
}

struct SettingsView: View {
    @Environment(AssistantViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    TextField("https://your-server.example.com", text: $model.serverURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("App token (same as server APP_TOKEN)", text: $model.token)
                } header: { Text("Server") } footer: {
                    Text("The token is stored in the iPhone Keychain. Your Claude API key stays on the server, never on the phone.")
                }
                Section {
                    LabeledContent("Status", value: model.glassesState.label)
                    Button(model.glassesState == .notRegistered ? "Connect glasses" : "Allow glasses microphone") {
                        Task {
                            if model.glassesState == .notRegistered {
                                await model.glasses.register()
                            } else {
                                await model.glasses.requestMicrophone()
                            }
                        }
                    }
                } header: { Text("Oakley Meta glasses") } footer: {
                    Text("Needs Developer Mode on in the Meta AI app. Opens Meta AI to approve Kitchen Copilot, then come back.")
                }
                Section("How to use") {
                    Text("Say \u{201C}Hey Meta, start Kitchen Copilot\u{201D} to open the app. Then press the capture button and ask, or say \u{201C}Hey kitchen\u{201D} and your question.")
                    Text("Voice commands: \u{201C}rush mode on/off\u{201D}, \u{201C}start over\u{201D}, \u{201C}stop\u{201D}.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .onDisappear { model.stopTalking() }
        }
    }
}

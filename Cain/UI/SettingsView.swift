// Copied from Bridge (phonebridge ba990d1, Bridge/UI/SettingsView.swift), trimmed: no duty mode, no prefilled URL.
import SwiftUI

struct SettingsView: View {
    @State private var url = ConfigStore.savedURL ?? ""
    @State private var deviceId = ConfigStore.savedDeviceId ?? ConfigStore.defaultDeviceId
    @State private var token = ""
    @State private var hasToken = ConfigStore.hasToken
    @State private var message: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://your-box.example", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Device id", text: $deviceId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(hasToken ? "Token saved — type to replace" : "Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server · 服务器").boxLabel()
                } footer: {
                    Text("Any server implementing Bridge's job API. Cain is its own device there (default id \"cain\"), next to Bridge. Stored in the Keychain on this device.")
                        .font(.caption).foregroundStyle(Theme.dim)
                }
                .boxRows()
                Section {
                    HStack(spacing: 8) {
                        Button("Save") { save() }
                            .buttonStyle(.box())
                        Button(testing ? "Testing…" : "Test connection") { test() }
                            .buttonStyle(.box())
                            .disabled(testing)
                    }
                }
                .boxRows()
                if let message {
                    Section {
                        Text(message).font(Theme.mono(.callout))
                    } header: {
                        Text("Result · 结果").boxLabel()
                    }
                    .boxRows()
                }
            }
            .boxList()
            .navigationTitle("Settings")
        }
    }

    private func save() {
        do {
            try ConfigStore.save(url: url, token: token, deviceId: deviceId)
            token = ""
            hasToken = ConfigStore.hasToken
            message = hasToken ? "Saved." : "Saved — but no token yet."
        } catch {
            message = error.localizedDescription
        }
    }

    private func test() {
        save()
        guard let config = ConfigStore.load() else {
            message = BoxError.notConfigured.localizedDescription
            return
        }
        testing = true
        Task {
            do {
                let reply = try await BoxClient(config: config).ping()
                let serverTime = reply["server_time"]?.stringValue.map { " (server time \($0))" } ?? ""
                message = "Connected to \(config.baseURL.host() ?? "box")\(serverTime)."
            } catch {
                message = "Failed: \(error.localizedDescription)"
            }
            testing = false
        }
    }
}

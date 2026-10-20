import Combine
import SwiftUI

/// One screen: the tunnel's state, the profiles, the newest log lines. Boring Box look.
struct HomeView: View {
    @EnvironmentObject private var tunnel: TunnelController
    @State private var status = AppStatus.shared
    @State private var showSettings = false
    @State private var polling = false
    @State private var profiles: [ProfileStore.Info] = []
    @State private var selected: String?
    @State private var logLines: [String] = []
    @State private var working = false
    @State private var actionError: String?

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusRow
                    if let message = actionError ?? tunnel.lastError {
                        Text(message).font(.footnote).foregroundStyle(Theme.red)
                    }
                } header: {
                    Text("Tunnel · 地道").boxLabel()
                }
                .boxRows()

                Section {
                    if profiles.isEmpty {
                        Text("No profiles yet. Your box uploads them with vpn.profile.put.")
                            .font(.footnote).foregroundStyle(Theme.dim)
                    }
                    ForEach(profiles, id: \.name) { profile in
                        profileRow(profile)
                    }
                } header: {
                    Text("Profiles · 配置").boxLabel()
                }
                .boxRows()

                Section {
                    HStack(spacing: 10) {
                        StatusSquare(state: status.connection.isHealthy ? .done
                            : status.connection == .connecting ? .running : .stale)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status.connection.label).font(Theme.mono(.caption))
                            Text(status.lastPollMessage).font(Theme.mono(.caption2)).foregroundStyle(Theme.dim)
                        }
                        Spacer()
                        Button(polling ? "Polling…" : "Poll now", action: pollNow)
                            .buttonStyle(.box())
                            .disabled(polling)
                    }
                } header: {
                    Text("Box · 盒子").boxLabel()
                }
                .boxRows()

                Section {
                    if status.activity.isEmpty {
                        Text("Nothing from the box yet.").font(.footnote).foregroundStyle(Theme.dim)
                    }
                    ForEach(status.activity.prefix(20)) { entry in
                        activityRow(entry)
                    }
                } header: {
                    Text("Activity · 动态").boxLabel()
                }
                .boxRows()

                Section {
                    if logLines.isEmpty {
                        Text("Nothing logged yet.").font(.footnote).foregroundStyle(Theme.dim)
                    }
                    ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(Theme.mono(.caption2)).foregroundStyle(Theme.dim)
                            .lineLimit(3)
                    }
                } header: {
                    Text("Log · 日志").boxLabel()
                }
                .boxRows()
            }
            .boxList()
            .navigationTitle("该隐")
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                Button("Settings") { showSettings = true }
                    .buttonStyle(.box())
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .onAppear(perform: reload)
        .onReceive(refreshTimer) { _ in reload() }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            StatusSquare(state: squareState)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(Theme.mono(.body, weight: .semibold))
                if let since = tunnel.connectedSince, tunnel.isOn {
                    Text("since \(since.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.mono(.caption)).foregroundStyle(Theme.dim)
                }
            }
            Spacer()
            Button(tunnel.isOn ? "Stop" : "Start", action: toggle)
                .buttonStyle(.box(color: tunnel.isOn ? Theme.red : Theme.text))
                .disabled(working || tunnel.isBusy || (!tunnel.isOn && selected == nil))
        }
        .padding(.vertical, 4)
    }

    /// "VPN on · profile home" — the same line as the activity feed, the box's vpn events and every vpn.* note.
    private var headline: String {
        VPNStatusLine.text(word: tunnel.statusWord, profile: selected)
    }

    private var squareState: StatusSquare.State {
        if tunnel.isBusy { return .running }
        if tunnel.isOn { return .done }
        return tunnel.lastError == nil ? .stale : .failed
    }

    private func profileRow(_ profile: ProfileStore.Info) -> some View {
        Button {
            choose(profile.name)
        } label: {
            HStack {
                Rectangle()
                    .strokeBorder(Theme.text, lineWidth: 1)
                    .background(profile.name == selected ? Theme.text : .clear)
                    .frame(width: Theme.squareSize, height: Theme.squareSize)
                Text(profile.name).font(Theme.mono(.body))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(profile.bytes), countStyle: .file))
                    .font(Theme.mono(.caption)).foregroundStyle(Theme.dim)
            }
        }
        .foregroundStyle(Theme.text)
    }

    private func activityRow(_ entry: ActivityEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StatusSquare(state: entry.status == .done ? .done : entry.status == .running ? .running : .failed)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.capability).font(Theme.mono(.caption, weight: .semibold))
                    Spacer()
                    Text(entry.time.formatted(date: .omitted, time: .shortened))
                        .font(Theme.mono(.caption2)).foregroundStyle(Theme.dim)
                }
                Text(entry.note).font(.footnote)
                if !entry.summary.isEmpty {
                    Text(entry.summary).font(Theme.mono(.caption2)).foregroundStyle(Theme.dim).lineLimit(2)
                }
            }
        }
    }

    private func pollNow() {
        polling = true
        Task {
            await CainRuntime.shared.pollNow()
            polling = false
            reload()
        }
    }

    private func reload() {
        profiles = tunnel.store.list()
        selected = tunnel.store.selected
        logLines = tunnel.log.tail(30).reversed()
    }

    private func toggle() {
        working = true
        actionError = nil
        Task {
            defer { working = false; reload() }
            do {
                if tunnel.isOn { try await tunnel.stop() } else { try await tunnel.start() }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func choose(_ name: String) {
        actionError = nil
        Task {
            defer { reload() }
            do { try await tunnel.select(name) } catch { actionError = error.localizedDescription }
        }
    }
}

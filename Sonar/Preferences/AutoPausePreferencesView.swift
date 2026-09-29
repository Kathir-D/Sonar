import AutoPauseEngine
import Combine
import SwiftUI

struct AutoPausePreferencesView: View {
    @ObservedObject var model: AutoPausePreferencesModel
    @ObservedObject var host: SonarEngineHost
    @StateObject private var recent = RecentSourcesModel()
    @State private var newBundleID = ""
    /// Re-applies engine settings whenever the model changes, so nothing has
    /// to be confirmed. Debounced because the sliders emit continuously.
    @State private var liveApply: AnyCancellable?
    /// Shown when Auto-Pause is switched on without the permission that makes
    /// it accurate.
    @State private var showPermissionAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                stateSection
                modeSection
                timingsSection
                sourcesSection
                recentSection
                diagnosticsSection
                permissionsSection
                saveSection
            }
            .frame(maxWidth: 600)
            .padding(20)
        }
        .onAppear {
            recent.start()
            host.refreshDiagnostics()
            // Auto-Pause ships enabled, so a user who never touches the
            // switch would never be prompted. Check on open as well.
            if model.enabled, !host.tapIsOperational {
                showPermissionAlert = true
            }
            liveApply = model.objectWillChange
                .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
                .sink { [host, model] _ in host.apply(model) }
        }
        .onDisappear {
            recent.stop()
            liveApply = nil
        }
        .onChange(of: model.enabled) { _, enabled in
            // Turning it on without the permission leaves it working on
            // process polling, which cannot tell silence from sound - so a
            // paused video can hold the resume for many seconds. Ask now,
            // while the user is actually turning the feature on.
            if enabled, !host.tapIsOperational {
                showPermissionAlert = true
            }
        }
        .alert(
            "Grant Audio Recording for accurate Auto-Pause",
            isPresented: $showPermissionAlert
        ) {
            Button("Open System Settings") {
                openPrivacyPane(.screenRecording)
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(
                "Sonar is running on process polling, which only knows whether an "
                    + "app is holding the audio output - not whether it is making "
                    + "sound. Browsers hold the output long after a video stops, so "
                    + "Spotify can take many seconds to resume. Screen & System "
                    + "Audio Recording lets Sonar measure actual loudness and "
                    + "resume immediately."
            )
        }
    }

    // MARK: - State dot

    private var stateSection: some View {
        Form {
            Section {
                Toggle("Enable Auto-Pause", isOn: $model.enabled)
                HStack {
                    stateDot
                    Text(host.uiState == .ducked ? "Ducked — Spotify held by Sonar"
                        : host.uiState == .listening ? "Listening"
                        : host.uiState == .tapUnavailable ? "Poll-only (tap unavailable)"
                        : "Idle")
                    Spacer()
                    Text(host.tapStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("State")
            } footer: {
                if host.uiState == .tapUnavailable {
                    // Poll-only can only ask "is this app holding the audio
                    // output?", never "is it actually making sound". A paused
                    // browser tab keeps the device open, so silence reads as
                    // loud and resuming is late. Say so, and say what fixes it.
                    Text(
                        "Tap unavailable, so Sonar is using process polling. Polling "
                            + "cannot measure loudness: any app holding the audio output "
                            + "counts as loud, even in silence, so a paused video can delay "
                            + "the resume. To fix, install the signed release, then grant "
                            + "Sonar under System Settings > Privacy & Security > Screen & "
                            + "System Audio Recording, and reopen Auto-Pause."
                    )
                } else {
                    Text("When ducked, Sonar owns Spotify playback and releases it on any manual pause, volume change, restart, or quit.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var stateDot: some View {
        Circle()
            .fill(host.uiState == .ducked ? Color.green
                : host.uiState == .listening ? Color.blue
                : host.uiState == .tapUnavailable ? Color.orange : Color.gray)
            .frame(width: 10, height: 10)
    }

    // MARK: - Mode

    private var modeSection: some View {
        Form {
            Section {
                Picker("Preset", selection: presetBinding) {
                    Text("Fade").tag(Optional(AutoPausePreset.fade))
                    Text("Instant").tag(Optional(AutoPausePreset.instant))
                    Text("Custom").tag(Optional<AutoPausePreset>.none)
                }
                .pickerStyle(.radioGroup)
                if let preset = model.currentPreset {
                    Text(preset.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Custom timings below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Mode")
            } footer: {
                Text(
                    "Fade eases volume out, pauses, waits for quiet, then fades back in. "
                        + "Instant pauses at once and resumes the moment the other app stops."
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Applies a preset on pick; falling back to "Custom" only clears the
    /// selection so the sliders below can be edited freely.
    private var presetBinding: Binding<AutoPausePreset?> {
        Binding(
            get: { model.currentPreset },
            set: { picked in
                guard let picked else { return }
                model.apply(picked)
            }
        )
    }

    // MARK: - Timings (slider + numeric)

    private var timingsSection: some View {
        Form {
            Section {
                sliderRow(
                    title: "Active duration",
                    value: $model.activeDuration,
                    range: 0.1...3.0,
                    step: 0.1,
                    unit: "s"
                )
                sliderRow(
                    title: "Quiet duration",
                    value: $model.quietDuration,
                    range: 0.1...10.0,
                    step: 0.1,
                    unit: "s"
                )
                sliderRow(
                    title: "Fade out",
                    value: $model.fadeOutDuration,
                    range: 0.0...5.0,
                    step: 0.1,
                    unit: "s"
                )
                sliderRow(
                    title: "Fade in",
                    value: $model.fadeInDuration,
                    range: 0.0...5.0,
                    step: 0.1,
                    unit: "s"
                )
                sliderRow(
                    title: "Loudness threshold",
                    value: $model.threshold,
                    range: 0.005...0.2,
                    step: 0.005,
                    unit: "RMS",
                    decimals: 3
                )
            } header: {
                Text("Timings & Threshold")
            } footer: {
                Text("Another app must stay loud for Active duration to duck Spotify; all sources must stay quiet for Quiet duration to resume.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String,
        decimals: Int = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                TextField(
                    "",
                    value: value,
                    format: .number.precision(.fractionLength(decimals))
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
            }
            Slider(value: value, in: range, step: step)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        Form {
            Section {
                Picker("Watch", selection: $model.filterMode) {
                    Text("All except…").tag(SourceFilterMode.allExcept)
                    Text("Only…").tag(SourceFilterMode.watchedOnly)
                }
                .pickerStyle(.segmented)

                ForEach(model.bundleIDs, id: \.self) { id in
                    HStack {
                        Text(id)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            model.bundleIDs.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    TextField("com.example.app", text: $newBundleID)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addBundleID)
                    Button("Add", action: addBundleID)
                        .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Bundle IDs of apps that count as external audio. Spotify, Sonar itself, and system blips are always excluded.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func addBundleID() {
        let id = newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !model.bundleIDs.contains(id) else { return }
        model.bundleIDs.append(id)
        newBundleID = ""
    }

    // MARK: - Recent sources finder

    private var recentSection: some View {
        Form {
            Section {
                if recent.entries.isEmpty {
                    Text("No audio sources heard in the last 3 minutes.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recent.entries) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.name)
                                Text(entry.bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if model.bundleIDs.contains(entry.bundleID) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("Watch") {
                                    model.bundleIDs.append(entry.bundleID)
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                }
            } header: {
                Text("Heard in the last 3 minutes")
            } footer: {
                Text("Live scan of apps producing audio. Add a bundle ID to the watch/except list above.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Form {
            Section {
                LabeledContent("Poll detector", value: host.pollActive ? "loud" : "quiet")
                LabeledContent("Tap RMS", value: String(format: "%.3f", host.tapRMS))
                if let t = host.loudCountdown {
                    LabeledContent("Duck in", value: String(format: "%.1f s", t))
                }
                if let t = host.quietCountdown {
                    LabeledContent("Resume in", value: String(format: "%.1f s", t))
                }
                LabeledContent("Last result", value: host.lastEventText)
                LabeledContent("Log", value: SonarLog.logURL.path(percentEncoded: false))
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Countdowns show time left in the current loud/quiet streak. The log is capped at 256 KB.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen & System Audio Recording")
                        Text(
                            host.tapIsOperational
                                ? "Granted - loudness detection is on"
                                : "Needed so Sonar can measure loudness instead of guessing"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            host.tapIsOperational ? Color.green : Color.secondary
                        )
                    }
                    Spacer()
                    Button(host.tapIsOperational ? "Open" : "Grant") {
                        openPrivacyPane(.screenRecording)
                    }
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automation")
                        Text("Lets Sonar pause and resume Spotify")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open") { openPrivacyPane(.automation) }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text(
                    "Without Screen & System Audio Recording, Sonar falls back to "
                        + "process polling, which only knows whether an app is holding "
                        + "the audio output - not whether it is making sound. A paused "
                        + "video can then hold the resume for many seconds."
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Save

    /// Settings apply as you change them. The engine reads these values live,
    /// so there is nothing to confirm and no button to remember to press.
    private var saveSection: some View {
        HStack {
            Label("Changes apply automatically", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
            Spacer()
        }
    }
}

#Preview {
    AutoPausePreferencesView(
        model: AutoPausePreferencesModel(),
        host: SonarEngineHost()
    )
}

/// The System Settings panes Auto-Pause depends on.
private enum PrivacyPane: String {
    case screenRecording = "Privacy_ScreenCapture"
    case automation = "Privacy_Automation"

    var url: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")
    }
}

private func openPrivacyPane(_ pane: PrivacyPane) {
    guard let url = pane.url else { return }
    NSWorkspace.shared.open(url)
}

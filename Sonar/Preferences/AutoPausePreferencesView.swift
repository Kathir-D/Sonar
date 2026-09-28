import AutoPauseEngine
import SwiftUI

struct AutoPausePreferencesView: View {
    @ObservedObject var model: AutoPausePreferencesModel
    @ObservedObject var host: SonarEngineHost
    @StateObject private var recent = RecentSourcesModel()
    @State private var newBundleID = ""
    @State private var savedFlash = false

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
        }
        .onDisappear { recent.stop() }
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
                Text("When ducked, Sonar owns Spotify playback and releases it on any manual pause, volume change, restart, or quit.")
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
                Text("Audio Capture: starting the engine triggers the system prompt once. If denied, Sonar runs poll-only (no RMS, no fade) until allowed.")
                Text("Automation: allow Sonar to control Spotify under System Settings › Privacy & Security › Automation, or auto-pause stays disabled with a hint.")
            } header: {
                Text("Permissions")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Save

    private var saveSection: some View {
        HStack {
            if savedFlash {
                Label("Saved", systemImage: "checkmark")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
            Spacer()
            Button("Save & Apply") {
                host.apply(model)
                savedFlash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    savedFlash = false
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    AutoPausePreferencesView(
        model: AutoPausePreferencesModel(),
        host: SonarEngineHost()
    )
}

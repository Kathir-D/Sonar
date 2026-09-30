import AutoPauseEngine
import Combine
import SwiftUI

/// One Edit-menu undo action. The undo manager keeps the handler, which keeps
/// this, so the target cannot outlive what it restores.
private final class UndoBox {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func perform() {
        action()
    }
}

/// `UndoManager` invokes registered handlers itself, on whichever thread owns
/// the menu command. This keeps the hop to the main actor in one place instead
/// of making every slider closure non-isolated.
private nonisolated func performUndo(_ box: UndoBox) {
    MainActor.assumeIsolated { box.perform() }
}

/// A slider drag is one change to the person doing it, however many values it
/// emits, so the drag is coalesced into a single named undo action.
@MainActor
private final class SliderUndoLog: ObservableObject {
    private struct Entry {
        let name: String
        /// The value before the drag started. Kept from the first value of the
        /// run, so undoing a drag lands where the drag started and not one step
        /// before the end.
        let undo: () -> Void
        /// The value the drag finished on.
        var redo: () -> Void
    }

    private var pending: [Entry] = []
    private var flush: AnyCancellable?

    /// - Parameters:
    ///   - name: what the Edit menu should say, without the "Undo" prefix.
    ///   - undo: put the value back.
    ///   - redo: put the dragged value back.
    func record(name: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        if let index = pending.firstIndex(where: { $0.name == name }) {
            pending[index].redo = redo
        } else {
            pending.append(Entry(name: name, undo: undo, redo: redo))
        }
        flush?.cancel()
        flush = Just(())
            .delay(for: .milliseconds(700), scheduler: RunLoop.main)
            .sink { [weak self] in self?.publish() }
    }

    private func publish() {
        let entries = pending
        pending = []
        for entry in entries {
            register(name: entry.name, undo: entry.undo, redo: entry.redo)
        }
    }

    /// A group per slider, so each drag keeps its own name in the menu instead
    /// of the whole stack sharing the last one written. Undo registers its own
    /// inverse, which is what makes Redo work as well.
    private func register(
        name: String,
        undo: @escaping () -> Void,
        redo: @escaping () -> Void
    ) {
        guard let manager = NSApp.keyWindow?.undoManager else { return }
        let box = UndoBox { [weak self] in
            undo()
            self?.register(name: "Redo \(name)", undo: redo, redo: undo)
        }
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: box, handler: performUndo)
        manager.setActionName(name)
        manager.endUndoGrouping()
    }
}

struct AutoPausePreferencesView: View {
    @ObservedObject var model: AutoPausePreferencesModel
    @ObservedObject var host: SonarEngineHost
    @ObservedObject private var permissions = SonarPermissions.shared
    @StateObject private var recent = RecentSourcesModel()
    @StateObject private var undoLog = SliderUndoLog()
    @State private var newBundleID = ""
    /// Re-applies engine settings whenever the model changes, so nothing has
    /// to be confirmed. Debounced because the sliders emit continuously.
    @State private var liveApply: AnyCancellable?
    /// Keeps the diagnostics rows live while the pane is open.
    @State private var diagnosticsTimer: Timer?
    /// A tap needs a moment to come up after the switch is flipped, so the
    /// "only polling" complaint is not raised before that settles.
    @State private var tapSettled = false
    @State private var settleTask: Task<Void, Never>?
    /// Mirrored so reopening the pane finds Advanced settings as the user left
    /// them, which is the whole reason to make it a disclosure.
    @AppStorage("autopause.advancedExpanded") private var advancedExpanded = false

    var body: some View {
        Form {
            // First, because nothing below it can work without these two.
            permissionsSection

            // Above the switch it describes, so "is Auto-Pause healthy" is
            // answerable without scrolling. Only exists when it is not.
            if let warning = degradedWarning {
                Section {
                    warningRow(warning)
                }
            }

            enableSection

            // Off means off: no mode, no timings, no list, no diagnostics
            // sitting there greyed out waiting to be ignored.
            if model.enabled {
                behaviourSection
                fadeSection
                advancedSection
                sourcesSection
                heardSection
                listedSection
                diagnosticsSection
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620)
        .onAppear {
            recent.start()
            // Permissions and the engine both change state while the user is
            // in System Settings, so read them on a timer and on every return
            // to this window.
            permissions.startLiveUpdates()
            diagnosticsTimer = Timer.scheduledTimer(
                withTimeInterval: 1,
                repeats: true
            ) { _ in
                host.refreshDiagnostics()
            }
            host.refreshDiagnostics()
            scheduleTapSettleCheck()
            liveApply = model.objectWillChange
                .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
                .sink { [host, model] _ in host.apply(model) }
        }
        .onDisappear {
            recent.stop()
            permissions.stopLiveUpdates()
            diagnosticsTimer?.invalidate()
            diagnosticsTimer = nil
            settleTask?.cancel()
            settleTask = nil
            liveApply = nil
        }
        .onChange(of: model.enabled) { _, _ in
            scheduleTapSettleCheck()
        }
        // Re-arm on every detector change, not just on enabling. A tap rebuild
        // drops the engine back onto polling for a second or two (see S1-6 in
        // the engine audit), and a warning that appears and vanishes again
        // while the user is reading it is worse than a late one.
        .onChange(of: host.drivingDetector) { _, _ in
            scheduleTapSettleCheck()
        }
    }

    // MARK: - What is wrong, said first

    /// The pane's headline state: Auto-Pause switched on but not doing its job.
    private struct DegradedWarning {
        let color: Color
        let headline: String
        let detail: String
        /// Nil while the state is still being read: a fix button with nothing
        /// to fix is a button that lies.
        let fix: (title: String, run: () -> Void)?
    }

    private var degradedWarning: DegradedWarning? {
        guard model.enabled else { return nil }

        if let first = missingPermissions.first {
            // Only the first: they are fixed one at a time anyway, and a banner
            // listing every consequence is not a summary.
            let state = stateToShow(for: first)
            return DegradedWarning(
                color: dotColor(for: state),
                headline: "Auto-Pause is on, but something is missing",
                detail: consequence(of: first),
                fix: actionTitle(for: state).map { title in
                    (title, { permissionAction(for: first, state: state) })
                }
            )
        }

        // The grant can be in place and the tap still dead: a tap that comes up
        // and delivers nothing measures digital silence as loud. The engine
        // knows which detector its last tick used, so ask it rather than
        // inferring from the tap's own state.
        if tapSettled, host.drivingDetector != .tap {
            return DegradedWarning(
                color: .orange,
                headline: "Auto-Pause is on, but no audio is reaching Sonar",
                detail: "Sonar is watching which apps hold the audio output instead of "
                    + "how loud they are, so a paused video can hold the resume for many "
                    + "seconds.",
                fix: ("Try again", restartDetector)
            )
        }

        return nil
    }

    private func consequence(of permission: SonarPermission) -> String {
        switch permission {
        case .screenRecording:
            return "Sonar can only tell whether an app is holding the audio output, "
                + "not whether it is making sound, so a paused video can hold the "
                + "resume for many seconds."
        case .automation:
            return "Sonar cannot pause or resume Spotify, so nothing will happen."
        }
    }

    /// A state dot, the same shape as the engine's own state row, so the pane
    /// has one way of saying "this is not right".
    private func warningRow(_ warning: DegradedWarning) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(warning.color)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(warning.headline)
                    .font(.callout.weight(.medium))
                Text(warning.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = warning.fix {
                    Button(fix.title, action: fix.run)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Permissions

    private var missingPermissions: [SonarPermission] {
        SonarPermission.allCases.filter { permissions.isBlocking($0) }
    }

    private var permissionsSection: some View {
        Section {
            ForEach(SonarPermission.allCases) { permission in
                permissionRow(permission)
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Both are needed before Auto-Pause can switch on.")
        }
    }

    /// One place decides what a permission row says and what its button does.
    /// A button that quietly does nothing is worse than no button at all.
    private func permissionRow(_ permission: SonarPermission) -> some View {
        let state = stateToShow(for: permission)
        let waiting = permissions.isRequesting(permission)
        return HStack(alignment: .top, spacing: 10) {
            permissionIcon(state)
                .foregroundStyle(dotColor(for: state))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(stateText(for: permission, state: state))
                    .font(.caption)
                    .foregroundStyle(dotColor(for: state))
                    .fixedSize(horizontal: false, vertical: true)
                if waiting {
                    Text("Waiting for the system dialog to be answered…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let actionTitle = actionTitle(for: state) {
                Button(actionTitle) { permissionAction(for: permission, state: state) }
                    // A second "Grant…" while the first dialog is up would open a
                    // second one on top of it. The row already says what it is
                    // waiting for, so the button is honest about being unusable
                    // rather than opening a dialog nobody asked for.
                    .disabled(waiting)
            }
        }
        .padding(.vertical, 2)
    }

    /// The grant is only half the truth for system audio: a granted app whose
    /// tap delivers nothing still cannot hear anything. Only worth saying while
    /// Auto-Pause is on, because nothing runs a tap while it is off.
    ///
    /// A request in flight deliberately does *not* blank the state any more. It
    /// used to report `.unknown` for the duration, and since the state is only
    /// cleared by the request's own completion, a dialog that was never
    /// answered left the row reading "Checking…" for the rest of the session:
    /// an in-flight request and a state nobody has read yet were the same thing,
    /// so a user with a real permission problem was shown no way out of it.
    /// The state is real, the wait is a separate caption, and both end.
    private func stateToShow(for permission: SonarPermission) -> SonarPermissionState {
        let state = permissions.state(for: permission)
        if permission == .screenRecording, state == .granted, model.enabled,
            !host.tapIsOperational
        {
            return .tapSilent
        }
        return state
    }

    /// True when the Automation row is `.blocked` because macOS stopped
    /// answering, rather than because it said no.
    ///
    /// The two are indistinguishable from the state alone — both are
    /// `.blocked` — and the difference decides both the wording and whether a
    /// "Grant…" button could ever work. See `SonarPermissions.automationCheckIsWedged`.
    private var automationCheckIsWedged: Bool {
        permissions.automationCheckIsWedged
    }

    private func stateText(
        for permission: SonarPermission,
        state: SonarPermissionState
    ) -> String {
        switch state {
        case .unknown:
            // Never "Checking…": there is nothing left to wait for. The read did
            // not come back, so say that much, name what the grant is for, and
            // leave the retry on the row — a spinner with no button is a dead
            // end, and this is a permission the user can fix in System Settings.
            return "Sonar couldn't read this. It needs this to \(permission.effect)."
        case .granted:
            return "Granted. Sonar can \(permission.effect)."
        case .tapSilent:
            return "Granted, but no system audio is reaching Sonar yet."
        case .needsGrant:
            return "Not granted. Sonar needs this to \(permission.effect)."
        case .blocked:
            // Two different things land here, and they need different words.
            // The refusal case is the OS saying no. The wedged case is the OS
            // not answering at all: on macOS 27 with Spotify 1.3.1.234,
            // `AEDeterminePermissionToAutomateTarget` never returns, so there
            // is no prompt to show and no "Grant…" that could ever work —
            // saying "Turned off" there sends someone to check a switch that
            // macOS is not reading. Naming the difference is the only thing
            // that keeps this from being a dead end with a button on it.
            return permission == .automation && automationCheckIsWedged
                ? "macOS won't answer when Sonar asks about this, so the prompt "
                    + "can't be shown. Turn it on in System Settings › Privacy & "
                    + "Security › Automation, listed under Sonar."
                : "Turned off. Sonar needs this to \(permission.effect)."
        case .targetNotRunning:
            // Apple Events cannot prompt about an app that is not running, so this
            // state has no "Grant…" button - only a re-check. Naming the thing to do
            // next matters, because otherwise the row looks identical to "granted but
            // nothing works" and a user has no reason to start Spotify.
            return "Spotify isn't running, so Sonar can't ask yet. Start Spotify, then Re-check."
        }
    }

    private func permissionAction(
        for permission: SonarPermission,
        state: SonarPermissionState
    ) {
        switch state {
        case .unknown:
            // The only action a row with no answer can offer. Everything else
            // about the state is unknown, so re-read it and let the poll carry
            // on from there.
            recheck()
        case .granted, .targetNotRunning:
            recheck()
        case .tapSilent:
            restartDetector()
        case .needsGrant:
            grant(permission)
        case .blocked:
            permissions.openSettings(for: permission)
        }
    }

    /// The label always names what the button will do next, so there is no
    /// state where it can promise the wrong thing — and every state has one, so
    /// no row is ever a dead end.
    private func actionTitle(for state: SonarPermissionState) -> String? {
        switch state {
        case .unknown:
            return "Re-check"
        case .granted, .targetNotRunning:
            return "Re-check"
        case .tapSilent:
            return "Try again"
        case .needsGrant:
            // A prompt macOS has already refused to raise. Pressing "Grant…"
            // would sit there for a minute and then admit nothing happened,
            // which is the worst thing a button can do. `request(_:)` routes
            // this to System Settings as well, so the two cannot disagree.
            return automationCheckIsWedged ? "Open System Settings" : "Grant…"
        case .blocked:
            return "Open System Settings"
        }
    }

    private func permissionIcon(_ state: SonarPermissionState) -> some View {
        let name: String = switch state {
        case .granted: "checkmark.circle.fill"
        case .needsGrant, .tapSilent: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        case .targetNotRunning: "minus.circle"
        }
        return Image(systemName: name)
    }

    private func dotColor(for state: SonarPermissionState) -> Color {
        switch state {
        case .granted: return .green
        case .needsGrant, .tapSilent: return .orange
        case .blocked: return .red
        case .unknown, .targetNotRunning: return .gray
        }
    }

    // MARK: - Actions on permissions

    /// Asking is not enough for system audio: Apple documents the prompt as
    /// implicit in capturing a tap, so the engine has to be starting one.
    private func grant(_ permission: SonarPermission) {
        permissions.request(permission)
        if permission == .screenRecording {
            restartDetector()
        }
    }

    private func recheck() {
        permissions.refresh()
        host.refreshDiagnostics()
    }

    /// Restarts the tap, which is both the honest fix for a dead tap and the
    /// way to make the system-audio prompt appear.
    private func restartDetector() {
        host.apply(model, forceTapRebuild: true)
        host.refreshDiagnostics()
        scheduleTapSettleCheck()
    }

    /// The tap takes a moment to come up, and until it does the engine drives
    /// on process polling, which is a healthy state rather than a broken one.
    /// Waiting keeps the warning row for what it is meant to describe: a
    /// detector that has been the wrong one for a while.
    private func scheduleTapSettleCheck() {
        settleTask?.cancel()
        tapSettled = host.drivingDetector == .tap
        guard model.enabled, !tapSettled else { return }
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            tapSettled = true
        }
    }

    // MARK: - On / off

    private var enableSection: some View {
        Section {
            Toggle("Pause Spotify when other apps play sound", isOn: enableBinding)
                // Only switching *on* is blocked: someone who just lost a
                // permission still has to be able to switch the feature off.
                .disabled(!model.canEnable && !model.enabled)
            if let first = missingPermissions.first {
                blockerRow(first)
            }
            if model.enabled {
                engineStateRow
            }
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    "Sonar pauses Spotify when another app makes sound, and starts "
                        + "playing again when it goes quiet."
                )
                if model.enabled {
                    Text(
                        "While Sonar holds Spotify, a manual pause, volume change, "
                            + "restart or quit hands playback back."
                    )
                }
            }
        }
    }

    private var enableBinding: Binding<Bool> {
        Binding(
            get: { model.enabled },
            set: { model.setEnabled($0) }
        )
    }

    private func blockerRow(_ permission: SonarPermission) -> some View {
        let state = stateToShow(for: permission)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(blockerText)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle = actionTitle(for: state) {
                    Button(actionTitle) {
                        permissionAction(for: permission, state: state)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var blockerText: String {
        let titles = missingPermissions.map(\.title)
        let list: String
        if titles.count == 1 {
            list = titles[0]
        } else {
            list = "\(titles.dropLast().joined(separator: ", ")) and "
                + "\(titles[titles.count - 1])"
        }
        return "Sonar needs \(list) before Auto-Pause can switch on."
    }

    private var engineStateRow: some View {
        HStack {
            Circle()
                .fill(engineStateColor)
                .frame(width: 10, height: 10)
            Text(engineStateText)
            Spacer()
            Text(host.tapStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var engineStateText: String {
        switch host.uiState {
        case .ducked: return "Holding Spotify"
        case .listening: return "Listening for other apps"
        case .tapUnavailable: return "Watching by process only"
        case .idle: return "Idle"
        }
    }

    private var engineStateColor: Color {
        switch host.uiState {
        case .ducked: return .green
        case .listening: return .blue
        case .tapUnavailable: return .orange
        case .idle: return .gray
        }
    }

    // MARK: - Presets

    private var behaviourSection: some View {
        Section {
            ForEach(AutoPausePreset.allCases) { preset in
                presetRow(
                    title: preset.title,
                    blurb: blurb(for: preset),
                    isSelected: model.currentPreset == preset,
                    apply: { model.apply(preset) }
                )
            }
            if model.currentPreset == nil {
                presetRow(
                    title: "Custom",
                    blurb: "You set the timings yourself.",
                    isSelected: true,
                    apply: nil
                )
                Text(
                    "These values no longer match Fade or Instant. Pick one above to go "
                        + "back to a starting point."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        } header: {
            Text("How Auto-Pause behaves")
        } footer: {
            Text("Pick a starting point. Open Advanced settings to fine-tune the timings.")
        }
    }

    private func blurb(for preset: AutoPausePreset) -> String {
        switch preset {
        case .fade:
            return "Music eases down and back up. The first and last moments of speech can slip under it."
        case .instant:
            return "Music cuts out and back in the moment. Nothing is clipped, but the change is abrupt."
        }
    }

    /// Hand-rolled rather than a radio `Picker`: a picker in a grouped form
    /// lays its indicators out horizontally and leaves no room for the line
    /// that says which one to pick.
    ///
    /// `Custom` is a state, not a choice. It appears because the values
    /// stopped matching, and it is not tappable - a radio that does nothing
    /// when you click it is a worse lie than a caption.
    private func presetRow(
        title: String,
        blurb: String,
        isSelected: Bool,
        apply: (() -> Void)?
    ) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)

        // A real Button, not `.onTapGesture`. These rows live inside a Form,
        // and a Form is a List: it claims taps on its rows for its own
        // selection behaviour, so the gesture never arrived. Verified by
        // clicking - Fade and Instant were simply not selectable, leaving
        // whatever the last saved values happened to be.
        if let apply {
            return AnyView(
                Button(action: apply) { row }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title). \(blurb)")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            )
        } else {
            return AnyView(row.accessibilityElement(children: .combine))
        }
    }

    // MARK: - Fade

    /// Exactly one control, and only when there is a fade to set. Instant has
    /// none, so it gets the way out instead of a slider that does nothing.
    @ViewBuilder
    private var fadeSection: some View {
        if model.currentPreset == .instant {
            Section {
                Button("Use a fade instead") {
                    model.useFade()
                }
            } footer: {
                Text("Instant has no fade, so there is nothing to set here.")
            }
        } else {
            Section {
                sliderRow(
                    title: "Fade length",
                    subtitle: "One length for both directions.",
                    value: fadeLength,
                    range: AutoPauseRanges.fade,
                    unit: "sec"
                )
            } footer: {
                Text(
                    "How gently music steps down for the other app, and back up when it stops."
                )
            }
        }
    }

    // MARK: - Advanced

    /// A preset keeps the rarely-needed controls behind a disclosure; Custom
    /// has nothing left to keep back, so its controls are already on screen.
    @ViewBuilder
    private var advancedSection: some View {
        if model.currentPreset == nil {
            Section {
                advancedControls
            } header: {
                Text("Advanced settings")
            } footer: {
                Text(advancedFooter)
            }
        } else {
            Section {
                DisclosureGroup(isExpanded: $advancedExpanded) {
                    advancedControls
                } label: {
                    Text("Advanced settings")
                }
            } footer: {
                Text(advancedFooter)
            }
        }
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            sliderRow(
                title: "Trigger delay",
                subtitle: "How long another app has to keep making sound before Sonar pauses.",
                value: triggerDelay,
                range: AutoPauseRanges.triggerDelay,
                unit: "sec"
            )
            sliderRow(
                title: "Resume delay",
                subtitle: "How long everything has to stay quiet before Sonar starts again.",
                value: resumeDelay,
                range: AutoPauseRanges.resumeDelay,
                unit: "sec"
            )
            sensitivityRow
            VStack(alignment: .leading, spacing: 2) {
                Text("Which apps count")
                Text(model.listedAppsLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Reset to \(model.nearestPreset.title)") {
                model.apply(model.nearestPreset)
            }
            // A reset with nothing to reset is a button that lies about doing
            // something, so it says so by being unavailable.
            .disabled(model.currentPreset == model.nearestPreset)
        }
        .padding(.vertical, 6)
    }

    private var advancedFooter: String {
        "Most people never need these. They control how quickly Sonar reacts, "
            + "and how quiet is quiet enough to count as silence."
    }

    /// Inverted on purpose. The engine compares `rms >= threshold`, so a higher
    /// threshold is less sensitive; without the flip, dragging right would
    /// quietly make Sonar deaf.
    private var sensitivityRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Loudness sensitivity")
                Spacer()
            }
            Slider(value: sensitivityPosition, in: 0...1)
            HStack {
                Text("Only loud sound")
                Spacer()
                Text("Even a whisper")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Sliders

    /// No `step:` on purpose: macOS draws a tick per step, and at 0.1 s over
    /// five seconds the track turns into a dotted line. The model snaps the
    /// value instead, so the numbers stay tidy without the noise.
    private func sliderRow(
        title: String,
        subtitle: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        unit: String,
        decimals: Int = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(decimals)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(unit)
                    .foregroundStyle(.secondary)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Slider(value: value, in: range)
        }
        .padding(.vertical, 2)
    }

    /// A binding that also leaves one named entry in the Edit menu, so the
    /// Custom state is recoverable for people who do not know about the Reset
    /// button.
    private func undoableSlider(
        name: String,
        read: @escaping () -> Double,
        write: @escaping (Double) -> Void
    ) -> Binding<Double> {
        Binding(
            get: read,
            set: { newValue in
                let oldValue = read()
                guard abs(newValue - oldValue) > 0.0001 else { return }
                write(newValue)
                undoLog.record(
                    name: name,
                    undo: { write(oldValue) },
                    redo: { write(newValue) }
                )
            }
        )
    }

    private var fadeLength: Binding<Double> {
        undoableSlider(
            name: "Fade Length",
            read: { model.fadeLength },
            write: { model.setFadeLength($0) }
        )
    }

    private var triggerDelay: Binding<Double> {
        undoableSlider(
            name: "Trigger Delay",
            read: { model.activeDuration },
            write: { model.setTriggerDelay($0) }
        )
    }

    private var resumeDelay: Binding<Double> {
        undoableSlider(
            name: "Resume Delay",
            read: { model.quietDuration },
            write: { model.setResumeDelay($0) }
        )
    }

    private var sensitivityPosition: Binding<Double> {
        undoableSlider(
            name: "Loudness Sensitivity",
            read: { model.sensitivityPosition },
            write: { model.setSensitivityPosition($0) }
        )
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        Section {
            Picker("Watch", selection: $model.filterMode) {
                Text("All apps").tag(SourceFilterMode.allExcept)
                Text("Only these apps").tag(SourceFilterMode.watchedOnly)
            }
            .pickerStyle(.segmented)

            Text(model.sourceSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Which apps pause your music")
        } footer: {
            Text(
                "Sonar pauses your music when any other app plays sound — a video, a "
                    + "call, a game. Spotify itself is never included."
            )
        }
    }

    // MARK: - Heard

    private var heardSection: some View {
        Section {
            if recent.entries.isEmpty {
                emptyState(
                    title: "Nothing is playing right now.",
                    hint: "Play something in another app and it will show up here."
                )
            } else {
                ForEach(recent.entries) { entry in
                    heardRow(entry)
                }
                Text("Tabs aren't listed separately — a browser counts as one app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Heard in the last 3 minutes")
        } footer: {
            Text(
                model.filterMode == .allExcept
                    ? "Sonar has heard sound from these apps recently. Ignore one to stop it pausing your music."
                    : "Sonar has heard sound from these apps recently. Watch one to let it pause your music."
            )
        }
    }

    private func heardRow(_ entry: RecentSourcesModel.Entry) -> some View {
        let isListed = model.isListed(entry.bundleID)
        let isWatched = model.isWatched(entry.bundleID)
        return HStack(alignment: .center, spacing: 10) {
            appIcon(entry.bundleID)
            // Combined on the text block only: combining the whole row would
            // swallow the button below, which is the one thing to reach.
            appNames(entry.bundleID, fallbackName: entry.name)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(appName(entry.bundleID, fallback: entry.name)), "
                        + (isWatched ? "will pause your music" : "will be ignored")
                )
            Spacer(minLength: 8)
            // The live verdict, so the row says what it will do even before
            // its button is pressed.
            Text(isWatched ? "Will pause" : "Will ignore")
                .font(.caption)
                .foregroundStyle(isWatched ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Button(model.sourceActionTitle(isListed: isListed)) {
                model.toggleSource(entry.bundleID)
            }
            .buttonStyle(.link)
        }
        .padding(.vertical, 2)
    }

    // MARK: - The listed apps

    private var listedSection: some View {
        Section {
            if model.bundleIDs.isEmpty {
                emptyState(
                    title: model.listedAppsEmptyText,
                    hint: model.listedAppsEmptyHint
                )
            } else {
                ForEach(model.bundleIDs, id: \.self) { bundleID in
                    listedRow(bundleID)
                }
            }
            DisclosureGroup("Add an app that isn't listed") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("com.example.app", text: $newBundleID)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addBundleID)
                    HStack {
                        Text("Bundle identifier")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Add", action: addBundleID)
                            .disabled(
                                newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty
                            )
                    }
                    Text("Only needed if the app isn't currently playing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .font(.callout)
        } header: {
            Text(model.listedAppsTitle)
        }
    }

    private func listedRow(_ bundleID: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            appIcon(bundleID)
            appNames(bundleID, unresolvedCaption: "Not installed on this Mac")
            Spacer(minLength: 8)
            Button(role: .destructive) {
                model.toggleSource(bundleID)
            } label: {
                Image(systemName: "trash")
            }
            // Not `.plain`: that discards the role's red tint, which is the
            // only thing telling an accidental click from a deliberate one.
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(appName(bundleID)) from the list")
        }
        .padding(.vertical, 2)
    }

    private func addBundleID() {
        model.addSource(newBundleID)
        newBundleID = ""
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            LabeledContent("Detector", value: drivingDetectorText)
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
            Text(
                "Countdowns show the time left in the current loud or quiet run. The log "
                    + "is capped at 256 KB."
            )
        }
    }

    /// Which detector is really making the decisions. The tap only counts once
    /// it is carrying audio; until then every decision is made by process
    /// polling, which cannot tell silence from sound, so the engine says so
    /// itself and the pane repeats it rather than guessing.
    private var drivingDetectorText: String {
        host.drivingDetector == .tap ? "System audio (tap)" : "Process polling only"
    }

    // MARK: - Shared row pieces

    private func emptyState(title: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let hint {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func appIcon(_ bundleID: String) -> some View {
        Image(nsImage: SourceAppIdentity.shared.icon(for: bundleID))
            .resizable()
            .interpolation(.high)
            .frame(width: 22, height: 22)
    }

    /// A name a person recognises, falling back to the raw ID when the app is
    /// not installed here and there is nothing better to show.
    private func appName(_ bundleID: String, fallback: String? = nil) -> String {
        let name = SourceAppIdentity.shared.name(for: bundleID)
        guard name == bundleID else { return name }
        return fallback ?? bundleID
    }

    /// App name first, bundle id second: a person can act on the icon, and the
    /// id is there when they need to check something.
    ///
    /// An app this Mac does not have has no name to lead with, so there the id
    /// becomes the label and the caption says why the row is still here.
    private func appNames(
        _ bundleID: String,
        fallbackName: String? = nil,
        unresolvedCaption: String? = nil
    ) -> some View {
        let name = appName(bundleID, fallback: fallbackName)
        let isResolved = name != bundleID
        return VStack(alignment: .leading, spacing: 1) {
            Text(name)
            Text(isResolved ? bundleID : (unresolvedCaption ?? bundleID))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

#Preview {
    AutoPausePreferencesView(
        model: AutoPausePreferencesModel(),
        host: SonarEngineHost()
    )
}

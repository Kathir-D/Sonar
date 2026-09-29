import AutoPauseEngine
import Combine
import Foundation

/// Ranges for the pane's sliders. The same ranges clamp values read back from
/// UserDefaults, so a slider is never handed a value outside itself.
enum AutoPauseRanges {
    /// Both fade directions share one control, so they share one range.
    static let fade: ClosedRange<Double> = 0...5
    static let fadeStep: Double = 0.5
    static let triggerDelay: ClosedRange<Double> = 0...5
    static let triggerDelayStep: Double = 0.1
    static let resumeDelay: ClosedRange<Double> = 0...10
    static let resumeDelayStep: Double = 0.1
    /// Loudness in RMS. Smaller counts as louder, so the pane inverts this
    /// slider rather than relabelling it.
    static let sensitivity: ClosedRange<Double> = 0.005...0.2
    static let sensitivityStep: Double = 0.005
}

/// Persisted Auto-Pause settings (UserDefaults, `autopause.*`).
/// New pane only — existing preference panes are untouched.
class AutoPausePreferencesModel: ObservableObject {
    private enum Key {
        static let enabled = "autopause.enabled"
        static let mode = "autopause.mode"
        static let activeDuration = "autopause.activeDuration"
        static let quietDuration = "autopause.quietDuration"
        static let fadeOut = "autopause.fadeOut"
        static let fadeIn = "autopause.fadeIn"
        static let threshold = "autopause.threshold"
        static let filterMode = "autopause.filterMode"
        static let bundleIDs = "autopause.bundleIDs"
    }

    /// Loudness the presets configure. `AutoPausePreset` owns the value and it
    /// is not the same for every preset (Fade 0.02, Instant 0.01), so the pane
    /// asks the preset rather than keeping a second copy that can drift.
    static var presetThreshold: Double { Double(AutoPausePreset.fade.threshold) }

    @Published var enabled: Bool {
        didSet {
            // Refuse rather than store: Auto-Pause switched on without its
            // permissions either does nothing (no Automation) or guesses from
            // process polling (no loudness), and the pane would be the only
            // place that knows.
            if enabled, !canEnable {
                enabled = false
                SonarLog.write("autopause: enable refused, permissions missing")
                return
            }
            save()
        }
    }
    @Published var mode: DuckMode { didSet { save() } }
    @Published var activeDuration: Double { didSet { save() } }
    @Published var quietDuration: Double { didSet { save() } }
    @Published var fadeOutDuration: Double { didSet { save() } }
    @Published var fadeInDuration: Double { didSet { save() } }
    @Published var threshold: Double { didSet { save() } }
    @Published var filterMode: SourceFilterMode { didSet { save() } }
    @Published var bundleIDs: [String] { didSet { save() } }

    private let defaults: UserDefaults
    private let permissions: SonarPermissions

    init(
        defaults: UserDefaults = .standard,
        permissions: SonarPermissions = .shared
    ) {
        self.defaults = defaults
        self.permissions = permissions
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        mode = (defaults.string(forKey: Key.mode)).flatMap(DuckMode.init(rawValue:)) ?? .fadeAndPause
        activeDuration = Self.clamp(
            defaults.object(forKey: Key.activeDuration) as? Double ?? 1.0,
            to: AutoPauseRanges.triggerDelay
        )
        quietDuration = Self.clamp(
            defaults.object(forKey: Key.quietDuration) as? Double ?? 3.0,
            to: AutoPauseRanges.resumeDelay
        )
        fadeOutDuration = Self.clamp(
            defaults.object(forKey: Key.fadeOut) as? Double ?? 2.0,
            to: AutoPauseRanges.fade
        )
        fadeInDuration = Self.clamp(
            defaults.object(forKey: Key.fadeIn) as? Double ?? 2.0,
            to: AutoPauseRanges.fade
        )
        threshold = Self.clamp(
            defaults.object(forKey: Key.threshold) as? Double ?? Self.presetThreshold,
            to: AutoPauseRanges.sensitivity
        )
        filterMode = (defaults.string(forKey: Key.filterMode)).flatMap(SourceFilterMode.init(rawValue:)) ?? .allExcept
        bundleIDs = defaults.stringArray(forKey: Key.bundleIDs) ?? []
    }

    private func save() {
        defaults.set(enabled, forKey: Key.enabled)
        defaults.set(mode.rawValue, forKey: Key.mode)
        defaults.set(activeDuration, forKey: Key.activeDuration)
        defaults.set(quietDuration, forKey: Key.quietDuration)
        defaults.set(fadeOutDuration, forKey: Key.fadeOut)
        defaults.set(fadeInDuration, forKey: Key.fadeIn)
        defaults.set(threshold, forKey: Key.threshold)
        defaults.set(filterMode.rawValue, forKey: Key.filterMode)
        defaults.set(bundleIDs, forKey: Key.bundleIDs)
    }

    // MARK: - Enabling

    /// Auto-Pause cannot be switched on without both permissions.
    var canEnable: Bool { permissions.canEnable }

    /// The only way the pane turns Auto-Pause on. The `didSet` guard covers
    /// writes from anywhere else; this exists so the UI can log the refusal
    /// against the tap that caused it.
    func setEnabled(_ newValue: Bool) {
        if newValue, !canEnable {
            SonarLog.write("autopause: enable refused from the pane")
            return
        }
        enabled = newValue
    }

    // MARK: - Presets

    /// The preset the current values describe, or nil when the values are the
    /// user's own.
    ///
    /// Derived, never stored: a stored selection can disagree with the
    /// sliders, and then the pane is showing two different truths. The engine
    /// owns the comparison, threshold included, so the pane and the engine can
    /// never disagree about what a preset is.
    var currentPreset: AutoPausePreset? {
        AutoPausePreset.allCases.first { matches($0) }
    }

    /// Which preset "Reset to ..." should name. The duck mode has to match for
    /// a preset to apply at all, so this is a lookup, not a guess.
    var nearestPreset: AutoPausePreset {
        AutoPausePreset.allCases.first { $0.mode == mode } ?? .fade
    }

    /// Apply a preset wholesale. A preset owns mode, timings *and* loudness, so
    /// "Instant" really is instant instead of inheriting the fade preset's
    /// multi-second dwell times and the wrong threshold.
    func apply(_ preset: AutoPausePreset) {
        mode = preset.mode
        activeDuration = preset.activeDuration
        quietDuration = preset.quietDuration
        fadeOutDuration = preset.fadeOutDuration
        fadeInDuration = preset.fadeInDuration
        threshold = Double(preset.threshold)
        save()
    }

    private func matches(_ preset: AutoPausePreset) -> Bool {
        preset.matches(
            mode: mode,
            activeDuration: activeDuration,
            quietDuration: quietDuration,
            fadeOutDuration: fadeOutDuration,
            fadeInDuration: fadeInDuration,
            threshold: Float(threshold)
        )
    }

    // MARK: - Single controls

    /// The one Fade slider drives both directions. "Fade" means one gesture
    /// down and one gesture back up; a control that could set them apart would
    /// be a control the pane could not explain.
    var fadeLength: Double { fadeOutDuration }

    func setFadeLength(_ seconds: Double) {
        let value = snap(seconds, to: AutoPauseRanges.fadeStep, in: AutoPauseRanges.fade)
        fadeOutDuration = value
        fadeInDuration = value
    }

    func setTriggerDelay(_ seconds: Double) {
        activeDuration = snap(
            seconds,
            to: AutoPauseRanges.triggerDelayStep,
            in: AutoPauseRanges.triggerDelay
        )
    }

    func setResumeDelay(_ seconds: Double) {
        quietDuration = snap(
            seconds,
            to: AutoPauseRanges.resumeDelayStep,
            in: AutoPauseRanges.resumeDelay
        )
    }

    /// The way out of Instant, which has no fade at all. Also switches the
    /// mode: fade durations are ignored by the instant adapter, so setting one
    /// without it would look like it did nothing.
    func useFade(_ seconds: Double = 2.0) {
        mode = .fadeAndPause
        setFadeLength(seconds)
    }

    /// 0 = only loud sound counts, 1 = even quiet sound counts.
    ///
    /// The engine compares `rms >= threshold`, so a *higher* threshold is
    /// *less* sensitive. This is deliberately the inverse of the stored value:
    /// dragging right has to mean "picks up more", otherwise the label lies
    /// and the bug is invisible.
    var sensitivityPosition: Double {
        let range = AutoPauseRanges.sensitivity
        return 1 - (threshold - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    func setSensitivityPosition(_ position: Double) {
        let range = AutoPauseRanges.sensitivity
        let clamped = min(max(position, 0), 1)
        let raw = range.upperBound - clamped * (range.upperBound - range.lowerBound)
        threshold = snap(raw, to: AutoPauseRanges.sensitivityStep, in: range)
    }

    private func snap(_ value: Double, to step: Double, in range: ClosedRange<Double>) -> Double {
        let snapped = (value / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - Sources

    func isListed(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    /// Whether this app can pause Spotify under the current mode and list.
    /// The Heard rows print this as "Will pause" / "Will ignore", so it has to
    /// be the same polarity the engine filters with.
    func isWatched(_ bundleID: String) -> Bool {
        switch filterMode {
        case .allExcept: return !bundleIDs.contains(bundleID)
        case .watchedOnly: return bundleIDs.contains(bundleID)
        }
    }

    /// The label for a Heard row's button. The list means the opposite thing in
    /// each mode, so the label has to follow the mode: a "Watch" button in
    /// "All apps" mode would be a lie, because it adds to the ignore list.
    func sourceActionTitle(isListed: Bool) -> String {
        switch (filterMode, isListed) {
        case (.allExcept, false): return "Ignore"
        case (.allExcept, true): return "Stop ignoring"
        case (.watchedOnly, false): return "Watch"
        case (.watchedOnly, true): return "Stop watching"
        }
    }

    /// The single mutation path for a listed app, so a row's label can never
    /// describe the opposite of what its button does.
    func toggleSource(_ bundleID: String) {
        if let index = bundleIDs.firstIndex(of: bundleID) {
            bundleIDs.remove(at: index)
        } else {
            bundleIDs.append(bundleID)
        }
    }

    func addSource(_ bundleID: String) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !bundleIDs.contains(id) else { return }
        bundleIDs.append(id)
    }

    /// The list means the opposite thing in each mode, so its name follows the
    /// mode instead of being called "Sources".
    var listedAppsTitle: String {
        filterMode == .allExcept ? "Ignored apps" : "Watched apps"
    }

    var listedAppsEmptyText: String {
        filterMode == .allExcept
            ? "No apps are ignored. Every app that plays sound can pause your music."
            : "No apps are watched yet, so nothing can pause your music."
    }

    var listedAppsEmptyHint: String? {
        filterMode == .allExcept ? nil : "Watch one from the list above to start."
    }

    /// What the mode and the list add up to, in one sentence. A segmented
    /// control whose meaning is polarity-dependent needs to say the result
    /// out loud, because the list alone reads the same either way.
    var sourceSummary: String {
        let count = bundleIDs.count
        let names = bundleIDs.map { SourceAppIdentity.shared.name(for: $0) }
        switch (filterMode, count) {
        case (.allExcept, 0):
            return "Every app on this Mac can pause your music."
        case (.allExcept, 1):
            return "Every app can pause your music except \(names[0])."
        case (.allExcept, _):
            return "Every app can pause your music except \(count) apps."
        case (.watchedOnly, 0):
            return "No app can pause your music yet. Watch one below to start."
        case (.watchedOnly, 1):
            return "Only \(names[0]) can pause your music."
        case (.watchedOnly, _):
            return "Only \(count) apps can pause your music."
        }
    }

    /// The list itself, as one line, for the place that says *which* apps.
    /// Deliberately not the sentence above: the sources section states the
    /// result, this one states the contents, and repeating a sentence in two
    /// places helps nobody.
    var listedAppsLine: String {
        if bundleIDs.isEmpty {
            return filterMode == .allExcept
                ? "Every app counts. Nothing is ignored."
                : "No apps are watched yet."
        }
        return bundleIDs
            .map { SourceAppIdentity.shared.name(for: $0) }
            .joined(separator: ", ")
    }

    /// What the engine runs with right now.
    var sourceFilter: SourceFilter {
        SourceFilter(mode: filterMode, bundleIDs: Set(bundleIDs))
    }

    /// Identity of the tap-affecting rules. Save restarts the tap only when
    /// this changes; timing/volume tweaks apply live without rebuild.
    var rulesFingerprint: String {
        ([filterMode.rawValue] + bundleIDs.sorted()).joined(separator: "\n")
    }
}

import AutoPauseEngine
import Combine
import Foundation

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

    @Published var enabled: Bool { didSet { save() } }
    @Published var mode: DuckMode { didSet { save() } }
    @Published var activeDuration: Double { didSet { save() } }
    @Published var quietDuration: Double { didSet { save() } }
    @Published var fadeOutDuration: Double { didSet { save() } }
    @Published var fadeInDuration: Double { didSet { save() } }
    @Published var threshold: Double { didSet { save() } }
    @Published var filterMode: SourceFilterMode { didSet { save() } }
    @Published var bundleIDs: [String] { didSet { save() } }

    init(defaults: UserDefaults = .standard) {
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        mode = (defaults.string(forKey: Key.mode)).flatMap(DuckMode.init(rawValue:)) ?? .fadeAndPause
        activeDuration = defaults.object(forKey: Key.activeDuration) as? Double ?? 1.0
        quietDuration = defaults.object(forKey: Key.quietDuration) as? Double ?? 3.0
        fadeOutDuration = defaults.object(forKey: Key.fadeOut) as? Double ?? 2.0
        fadeInDuration = defaults.object(forKey: Key.fadeIn) as? Double ?? 2.0
        threshold = defaults.object(forKey: Key.threshold) as? Double ?? 0.02
        filterMode = (defaults.string(forKey: Key.filterMode)).flatMap(SourceFilterMode.init(rawValue:)) ?? .allExcept
        bundleIDs = defaults.stringArray(forKey: Key.bundleIDs) ?? []
    }

    private func save() {
        let defaults = UserDefaults.standard
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

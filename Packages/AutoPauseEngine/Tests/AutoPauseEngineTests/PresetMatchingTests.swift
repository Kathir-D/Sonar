import Foundation
import Testing
@testable import AutoPauseEngine

/// `matches` is how the preferences pane decides between "Fade", "Instant" and
/// "Custom" (see `AutoPausePreferencesModel.currentPreset`). A false positive
/// silently relabels the user's settings, so the rule is pinned field by
/// field rather than as one "exact settings" test.
private func matches(
    _ preset: AutoPausePreset,
    mode: DuckMode? = nil,
    active: TimeInterval? = nil,
    quiet: TimeInterval? = nil,
    fadeOut: TimeInterval? = nil,
    fadeIn: TimeInterval? = nil,
    threshold: Float? = nil
) -> Bool {
    preset.matches(
        mode: mode ?? preset.mode,
        activeDuration: active ?? preset.activeDuration,
        quietDuration: quiet ?? preset.quietDuration,
        fadeOutDuration: fadeOut ?? preset.fadeOutDuration,
        fadeInDuration: fadeIn ?? preset.fadeInDuration,
        threshold: threshold ?? preset.threshold
    )
}

/// The same check, but against the configuration *`configuredBy`* writes
/// rather than the preset's own. Needed because asking a preset about its own
/// settings trivially succeeds, so a cross-preset claim can only be detected
/// this way.
private func matches(
    _ preset: AutoPausePreset,
    asConfiguredBy configuredBy: AutoPausePreset
) -> Bool {
    preset.matches(
        mode: configuredBy.mode,
        activeDuration: configuredBy.activeDuration,
        quietDuration: configuredBy.quietDuration,
        fadeOutDuration: configuredBy.fadeOutDuration,
        fadeInDuration: configuredBy.fadeInDuration,
        threshold: configuredBy.threshold
    )
}

/// A clearly-wrong value for any timing field, far outside the 0.001 match
/// tolerance.
private let otherDuration: TimeInterval = 7.5

// MARK: - The happy path

@Test func everyPresetMatchesItsOwnConfiguration() {
    for preset in AutoPausePreset.allCases {
        #expect(
            matches(preset),
            "\(preset.rawValue) does not match the settings it writes")
    }
}

@Test func exactlyOnePresetMatchesAGivenConfiguration() {
    // Two presets claiming the same settings would render two "selected"
    // buttons in the presets row and make "Custom" unreachable. Each preset's
    // own configuration is checked against *every* preset, which is the only
    // way this can actually fail: asking a preset about its own settings always
    // answers yes, so the interesting part is the other one.
    for preset in AutoPausePreset.allCases {
        let matching = AutoPausePreset.allCases.filter { matches($0, asConfiguredBy: preset) }
        #expect(
            matching == [preset],
            "\(preset.rawValue)'s settings also match \(matching.map(\.rawValue))")
    }
}

@Test func presetsAreExactlyFadeAndInstant() {
    // The preferences pane renders `ForEach(AutoPausePreset.allCases)`, and
    // the model persists `rawValue`. Both depend on this exact shape.
    #expect(AutoPausePreset.allCases == [.fade, .instant])
    #expect(AutoPausePreset.fade.rawValue == "fade")
    #expect(AutoPausePreset.instant.rawValue == "instant")
    #expect(AutoPausePreset.fade.id == "fade")
    #expect(AutoPausePreset.instant.id == "instant")
}

// MARK: - One field wrong at a time

@Test func aPresetRejectsEveryOtherDuckMode() {
    for preset in AutoPausePreset.allCases {
        for mode in DuckMode.allCases where mode != preset.mode {
            #expect(
                !matches(preset, mode: mode),
                "\(preset.rawValue) matched mode \(mode.rawValue)")
        }
    }
}

@Test func aPresetRejectsAWrongActiveDuration() {
    for preset in AutoPausePreset.allCases {
        #expect(!matches(preset, active: otherDuration), "\(preset.rawValue) active")
        #expect(!matches(preset, active: preset.activeDuration + 1), "\(preset.rawValue) active +1")
        // Zero is the other important value: "react instantly" is a legitimate
        // custom setting, not the preset.
        if preset.activeDuration != 0 {
            #expect(!matches(preset, active: 0), "\(preset.rawValue) active 0")
        }
    }
}

@Test func aPresetRejectsAWrongQuietDuration() {
    for preset in AutoPausePreset.allCases {
        #expect(!matches(preset, quiet: otherDuration), "\(preset.rawValue) quiet")
        #expect(!matches(preset, quiet: preset.quietDuration + 1), "\(preset.rawValue) quiet +1")
        if preset.quietDuration != 0 {
            #expect(!matches(preset, quiet: 0), "\(preset.rawValue) quiet 0")
        }
    }
}

@Test func aPresetRejectsAWrongFadeOutDuration() {
    for preset in AutoPausePreset.allCases {
        #expect(!matches(preset, fadeOut: otherDuration), "\(preset.rawValue) fadeOut")
        #expect(!matches(preset, fadeOut: preset.fadeOutDuration + 1), "\(preset.rawValue) fadeOut +1")
        // A non-zero fade duration is the field that separates the two
        // presets, so a mismatch here must always be detected.
        if preset.fadeOutDuration == 0 {
            #expect(!matches(preset, fadeOut: 1), "\(preset.rawValue) fadeOut 1")
        }
    }
}

@Test func aPresetRejectsAWrongFadeInDuration() {
    for preset in AutoPausePreset.allCases {
        #expect(!matches(preset, fadeIn: otherDuration), "\(preset.rawValue) fadeIn")
        #expect(!matches(preset, fadeIn: preset.fadeInDuration + 1), "\(preset.rawValue) fadeIn +1")
        if preset.fadeInDuration == 0 {
            #expect(!matches(preset, fadeIn: 1), "\(preset.rawValue) fadeIn 1")
        }
    }
}

@Test func aPresetRejectsAWrongThreshold() {
    // The threshold is the newest field and the easiest to forget: a preset
    // that ignores it would keep claiming to be "Fade" after the user dragged
    // the sensitivity slider.
    for preset in AutoPausePreset.allCases {
        #expect(
            !matches(preset, threshold: preset.threshold + 0.05),
            "\(preset.rawValue) matched a raised threshold")
        #expect(
            !matches(preset, threshold: max(0, preset.threshold - 0.01)),
            "\(preset.rawValue) matched a lowered threshold")
        #expect(
            !matches(preset, threshold: 0.5),
            "\(preset.rawValue) matched an unrelated threshold")
    }
}

@Test func aPresetRejectsTwoFieldsWrongAtOnceToo() {
    // Combined with the single-field tests, this is what "Custom" means: any
    // deviation at all.
    for preset in AutoPausePreset.allCases {
        #expect(!matches(preset, mode: .muteOnly, quiet: otherDuration), "\(preset.rawValue)")
        #expect(!matches(preset, fadeOut: 1, threshold: 0.5), "\(preset.rawValue)")
    }
}

// MARK: - Tolerance: float noise is not a deviation

@Test func aPresetToleratesSubMillisecondTimingNoise() {
    // Sliders and `UserDefaults` round-trips produce values a hair off the
    // preset. Below the 0.001 tolerance the preset must still be reported,
    // otherwise the label flickers to "Custom" on every save.
    for preset in AutoPausePreset.allCases {
        let noise: TimeInterval = 0.0005
        #expect(matches(preset, active: preset.activeDuration + noise), "\(preset.rawValue) active")
        #expect(matches(preset, quiet: preset.quietDuration - noise), "\(preset.rawValue) quiet")
        #expect(matches(preset, fadeOut: preset.fadeOutDuration + noise), "\(preset.rawValue) out")
        #expect(matches(preset, fadeIn: preset.fadeInDuration - noise), "\(preset.rawValue) in")
    }
}

@Test func aPresetToleratesSubThresholdFloatNoise() {
    // The threshold comparison uses a tighter tolerance (0.0001) because the
    // slider moves in finer steps than the timing sliders. Float storage
    // round-off on a 0.02 default is ~1e-9, so this is a real but invisible
    // difference that must not read as "Custom".
    for preset in AutoPausePreset.allCases {
        #expect(matches(preset, threshold: preset.threshold + 0.00005), "\(preset.rawValue)")
    }
}

@Test func aPresetRejectsTimingNoiseAboveTheTolerance() {
    for preset in AutoPausePreset.allCases {
        let noise: TimeInterval = 0.002
        #expect(!matches(preset, active: preset.activeDuration + noise), "\(preset.rawValue) active")
        #expect(!matches(preset, quiet: preset.quietDuration + noise), "\(preset.rawValue) quiet")
        #expect(!matches(preset, fadeOut: preset.fadeOutDuration + noise), "\(preset.rawValue) out")
        #expect(!matches(preset, fadeIn: preset.fadeInDuration + noise), "\(preset.rawValue) in")
    }
}

@Test func aPresetRejectsThresholdNoiseAboveTheTolerance() {
    for preset in AutoPausePreset.allCases {
        // The one notch a slider can actually produce, so this is not a
        // theoretical tolerance: it is a value the user can reach.
        let oneStep: Float = 0.005
        #expect(!matches(preset, threshold: preset.threshold + oneStep), "\(preset.rawValue) up")
        #expect(
            !matches(preset, threshold: max(0, preset.threshold - oneStep)),
            "\(preset.rawValue) down")
    }
}

// MARK: - The threshold argument

@Test func everyPresetMatchesItsOwnThreshold() {
    // `threshold` is a required argument on purpose. It used to default to 0.02,
    // which is `fade`'s value, so every call site that omitted it compared
    // against 0.02 regardless of which preset was being asked about: instant
    // (0.01) could then never be reported as selected, and a user who had
    // dragged the threshold was still told they were on "Fade". Passing the
    // real value is what makes the UI's derived "Custom" state trustworthy.
    for preset in AutoPausePreset.allCases {
        #expect(
            preset.matches(
                mode: preset.mode,
                activeDuration: preset.activeDuration,
                quietDuration: preset.quietDuration,
                fadeOutDuration: preset.fadeOutDuration,
                fadeInDuration: preset.fadeInDuration,
                threshold: preset.threshold
            ),
            "\(preset.rawValue) does not match itself"
        )
    }
}

@Test func onePresetsThresholdNeverMatchesTheOtherPresetsValue() {
    // The failure mode a shared default would hide: asking "is this Fade?" with
    // a threshold that belongs to Instant must say no.
    #expect(
        !AutoPausePreset.fade.matches(
            mode: .fadeAndPause,
            activeDuration: AutoPausePreset.fade.activeDuration,
            quietDuration: AutoPausePreset.fade.quietDuration,
            fadeOutDuration: AutoPausePreset.fade.fadeOutDuration,
            fadeInDuration: AutoPausePreset.fade.fadeInDuration,
            threshold: AutoPausePreset.instant.threshold
        )
    )
    #expect(
        !AutoPausePreset.instant.matches(
            mode: .instant,
            activeDuration: AutoPausePreset.instant.activeDuration,
            quietDuration: AutoPausePreset.instant.quietDuration,
            fadeOutDuration: AutoPausePreset.instant.fadeOutDuration,
            fadeInDuration: AutoPausePreset.instant.fadeInDuration,
            threshold: AutoPausePreset.fade.threshold
        )
    )
}

// MARK: - The threshold values themselves

@Test func presetThresholdsAreUsableRmsLevels() {
    // `TapConfig.threshold` is an RMS, so 0 and 1 are both broken: 0 makes
    // digital noise "loud", 1 is unreachable. The presets must stay inside.
    for preset in AutoPausePreset.allCases {
        #expect(preset.threshold > 0, "\(preset.rawValue) threshold is 0")
        #expect(preset.threshold < 1, "\(preset.rawValue) threshold is unreachable")
    }
}

@Test func thePresetsThresholdsDiffer() {
    // Instant promises to react before the sound is unambiguous, so it must
    // use a lower threshold than Fade. If the two converged, "Instant" would
    // silently become "Fade with faster timings", which is a different promise.
    #expect(AutoPausePreset.instant.threshold < AutoPausePreset.fade.threshold)
}

@Test func theFadePresetThresholdMatchesTheEngineDefault() {
    // `TapConfig.threshold` defaults to 0.02. Fade matching that default is
    // what makes an untouched config still read as "Fade" rather than
    // "Custom" on first launch.
    #expect(AutoPausePreset.fade.threshold == TapConfig().threshold)
}

@Test func thePresetThresholdsFitInsideTheSliderRange() {
    // Whatever range the preferences slider uses, the preset values have to be
    // representable in it. 0...1 is the RMS range, and a preset pinned at
    // exactly an endpoint would be a value the slider clamps away, turning the
    // preset into "Custom" the moment it is applied.
    for preset in AutoPausePreset.allCases {
        #expect(preset.threshold >= 0.005, "\(preset.rawValue) is below the useful floor")
        #expect(preset.threshold <= 0.25, "\(preset.rawValue) is above a usable ceiling")
    }
}

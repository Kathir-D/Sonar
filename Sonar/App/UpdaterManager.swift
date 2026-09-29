import AppKit
import Foundation
import OSLog
import Sparkle

/// Shared Sparkle updater controller - must be a single instance app-wide.
///
/// Two properties of a first release shape this file.
///
/// **Nothing here runs at launch.** `shared` is only reached from Preferences ›
/// About, and `SPUStandardUpdaterController`'s initializer does no network
/// work: it validates the bundle's Sparkle configuration and schedules the
/// first check for a later runloop turn. A feed URL that 404s, or one that is
/// simply unreachable, therefore cannot delay or block launch.
///
/// **Feed failures are quiet and logged.** Until 0.1.0 is actually published,
/// `SUFeedURL` resolves to nothing, and after that it can be unreachable,
/// malformed, or serve an enclosure that fails to verify. Sparkle stays silent
/// for all of those on a scheduled check on its own — it only raises UI when the
/// user started the check — and `UpdaterDelegate` adds the logging that would
/// otherwise be missing entirely.
final class UpdaterManager {
    static let shared = UpdaterManager()

    let controller: SPUStandardUpdaterController
    var updater: SPUUpdater { controller.updater }

    /// `SPUStandardUpdaterController` holds both delegates weakly, so this is
    /// owned statically for the lifetime of the process rather than by the
    /// controller.
    private static let delegate = UpdaterDelegate()

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: Self.delegate,
            userDriverDelegate: Self.delegate
        )

        // Sparkle reads `SUEnableAutomaticChecks` from user defaults, and it is
        // absent on a fresh install, so automatic checks default to off and have
        // to be turned on once. This marker keeps that to a single write, so
        // toggling the switch off in Preferences › About stays off.
        //
        // Only the default needs setting; the permission prompt that would
        // otherwise decide this is suppressed in `UpdaterDelegate`, by design
        // rather than by relying on this write landing before the updater's
        // first runloop turn.
        if !UserDefaults.standard.bool(forKey: "hasConfiguredSparkle") {
            controller.updater.automaticallyChecksForUpdates = true
            UserDefaults.standard.set(true, forKey: "hasConfiguredSparkle")
        }
    }
}

/// Sparkle's updater and user-driver delegate for Sonar.
///
/// Its whole job is to make an absent or broken update feed a non-event for the
/// user while still leaving a trace, and to make the one alert we do allow
/// actually visible from a menu-bar app.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private static let log = Logger(subsystem: "com.KathirD.sonar", category: "updater")

    // MARK: - SPUUpdaterDelegate

    /// Never ask permission to check for updates.
    ///
    /// Sparkle's prompt is a modal alert, and Sonar is an `LSUIElement` app: no
    /// Dock icon and no window to raise it from, so the dialog can land behind
    /// whatever the user is doing and read as a hung app. Sonar picks its own
    /// default in `UpdaterManager` instead, and the user can still change it in
    /// Preferences › About.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    /// The single place every aborted update cycle is reported.
    ///
    /// A 404 on `SUFeedURL`, no network, a malformed feed and a failed signature
    /// check all land here. Sparkle shows no UI for any of them unless the user
    /// asked for the check, so this is the only record that one happened.
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let failure = error as NSError
        Self.log.error("""
            update check aborted: domain=\(failure.domain, privacy: .public) \
            code=\(failure.code) \
            message=\(failure.localizedDescription, privacy: .public)
            """)
    }

    /// Log the outcome of every completed check, successful or not, so "no
    /// update offered" and "check never ran" are distinguishable after the fact.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            let failure = error as NSError
            Self.log.debug("""
                check \(String(describing: updateCheck), privacy: .public) finished: \
                domain=\(failure.domain, privacy: .public) code=\(failure.code)
                """)
        } else {
            Self.log.debug("check \(String(describing: updateCheck), privacy: .public) finished")
        }
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// Bring Sonar forward before Sparkle puts an alert on screen.
    ///
    /// The only alert a user can still reach is the result of a check they
    /// started themselves from Preferences › About. Sparkle activates the app
    /// in exactly one place — its update-permission request, which is disabled
    /// above — and runs every other alert with `-[NSAlert runModal]`, so
    /// without this the alert can open behind another app, with no Dock icon to
    /// find it by.
    func standardUserDriverWillShowModalAlert() {
        NSApp.activate()
    }
}

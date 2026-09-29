import AppKit
import SwiftUI

struct AboutPreferencesView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    /// The releases page, which is the update path now that Sonar has no
    /// in-app updater. `AboutPreferencesView` is a static screen with no state,
    /// so nothing here needs `@State`.
    private static let releasesURL = URL(string: "https://github.com/Kathir-D/Sonar/releases")!

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // App Icon and Name
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 128, height: 128)
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

                    Text("Sonar")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Version \(appVersion) (\(buildNumber))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                Divider()
                    .padding(.horizontal, 40)

                // Donation Section
                VStack(spacing: 12) {
                    Text("Support Development")
                        .font(.headline)

                    Text("Sonar is free and open source.\nMenu-bar Spotify viewer with hybrid auto-pause.\nBased on SpotMenu by @kmikiy (MIT).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)

                    Button(action: {
                        if let url = URL(string: "https://github.com/kmikiy/SpotMenu") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.white)
                            Text("SpotMenu upstream")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
                .padding(.vertical, 8)

                Divider()
                    .padding(.horizontal, 40)

                // Description
                VStack(spacing: 8) {
                    Text("Spotify in your menu bar")
                        .font(.headline)

                    Text("Built with SwiftUI for macOS")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .padding(.horizontal, 40)

                // Software Updates Section
                VStack(spacing: 12) {
                    Text("Software Updates")
                        .font(.headline)

                    Text("Sonar does not update itself. To move to a new version, either:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("brew upgrade --cask sonar")
                        .font(.system(.subheadline, design: .monospaced))
                        .textSelection(.enabled)

                    Text("if you installed it with Homebrew, or download it from the releases page.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button(action: {
                        NSWorkspace.shared.open(Self.releasesURL)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle")
                            Text("Open Releases Page")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 20)

                Divider()
                    .padding(.horizontal, 40)

                // Links
                VStack(spacing: 12) {
                    Button(action: {
                        if let url = URL(string: "https://github.com/Kathir-D/Sonar") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                            Text("View on GitHub")
                        }
                    }
                    .buttonStyle(.link)
                }

                Spacer()

                // Copyright
                Text("Based on SpotMenu by @kmikiy · MIT")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 20)
            }
            .frame(maxWidth: 400)
            .padding(20)
        }
    }
}

#Preview {
    AboutPreferencesView()
}

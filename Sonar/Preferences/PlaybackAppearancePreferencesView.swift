import SwiftUI

struct PlaybackAppearancePreferencesView: View {
    @ObservedObject var model: PlaybackAppearancePreferencesModel
    @ObservedObject var musicPlayerPreferencesModel: MusicPlayerPreferencesModel
    @ObservedObject var playbackModel: PlaybackModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Form {
                    Section {
                        ColorPicker("Hover Tint Color", selection: Binding(
                            get: { Color(model.hoverTintColor) },
                            set: { model.hoverTintColor = NSColor($0) }
                        ))

                        Picker("Foreground Color", selection: $model.foregroundColor) {
                            ForEach(
                                PlaybackAppearancePreferencesModel.ForegroundColorOption
                                    .allCases
                            ) { option in
                                Text(option.rawValue.capitalized).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Colors")
                    } footer: {
                        Text("Customize the color scheme for the playback window.")
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)

                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Blur Intensity")
                                Spacer()
                                // Double-click the number to type it.
                                SliderNumberField(
                                    value: $model.blurIntensity,
                                    range: 0...1,
                                    decimals: 0,
                                    displayScale: 100,
                                    fontSize: NSFont.smallSystemFontSize,
                                    width: 32,
                                    label: "Blur Intensity"
                                )
                                Text("%")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            Slider(value: $model.blurIntensity, in: 0...1)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Hover Tint Opacity")
                                Spacer()
                                // Double-click the number to type it.
                                SliderNumberField(
                                    value: $model.hoverTintOpacity,
                                    range: 0...1,
                                    decimals: 0,
                                    displayScale: 100,
                                    fontSize: NSFont.smallSystemFontSize,
                                    width: 32,
                                    label: "Hover Tint Opacity"
                                )
                                Text("%")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            Slider(value: $model.hoverTintOpacity, in: 0...1)
                        }
                    } header: {
                        Text("Effects")
                    } footer: {
                        Text("Adjust blur and tint intensity for the playback window.")
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)

                Form {
                    Section {
                        HStack {
                            Spacer()
                            PlaybackView(
                                model: playbackModel,
                                preferences: model,
                                musicPlayerPreferencesModel: musicPlayerPreferencesModel
                            )
                            Spacer()
                        }
                    } header: {
                        Text("Preview")
                    } footer: {
                        Text("Live preview of the playback window with your current settings.")
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        .frame(maxWidth: 600)
        .padding(20)
    }
    }
}

#Preview {
    PlaybackAppearancePreferencesView(
        model: PlaybackAppearancePreferencesModel(),
        musicPlayerPreferencesModel: MusicPlayerPreferencesModel(),
        playbackModel: PlaybackModel(preferences: MusicPlayerPreferencesModel())
    )
}

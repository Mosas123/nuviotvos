//
//  ShowAudioLanguageOverlay.swift
//  NuvioTV
//
//  Created for Issue #191: Per-show audio language playback preference.
//

import SwiftUI

struct AudioLanguageOption: Identifiable, Hashable {
    let id: String
    let value: String?
    let title: String
}

struct ShowAudioLanguageOverlay: View {
    let meta: NuvioMeta
    let onDismiss: () -> Void

    @FocusState private var focusedControl: String?
    @State private var selectedValue: String?

    private var globalAudioLanguage: String {
        ProfileSettings.current.string(forKey: SettingsKey.audioLanguage) ?? "System"
    }

    private var currentSavedLanguage: String? {
        ShowAudioLanguageStore.getLanguage(for: meta.id)
    }

    private var options: [AudioLanguageOption] {
        var items: [AudioLanguageOption] = []
        let defaultLabel = L10n.string("details_audio_language_default", fallback: "Default") + " (\(globalAudioLanguage))"
        items.append(AudioLanguageOption(id: "default", value: nil, title: defaultLabel))
        items.append(AudioLanguageOption(id: "Original", value: "Original", title: "Original"))
        for lang in SubtitleLanguagePreferences.supportedLanguages {
            items.append(AudioLanguageOption(id: lang, value: lang, title: lang))
        }
        return items
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack(spacing: 20) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 60, height: 60)
                        .modifier(TvDetailsGlassBackground(filled: false, shape: Circle()))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(meta.name)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(L10n.string("details_audio_language_title", fallback: "Playback Audio Language"))
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    Spacer()

                    Button(action: onDismiss) {
                        Text(L10n.string("action_close", fallback: "Close"))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(focusedControl == "close_button" ? .black : .white)
                            .padding(.horizontal, 26)
                            .frame(height: 52)
                            .modifier(
                                TvDetailsGlassBackground(
                                    filled: focusedControl == "close_button",
                                    shape: Capsule()
                                )
                            )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focused($focusedControl, equals: "close_button")
                }

                // Options list
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(options) { option in
                            let isSelected = isOptionSelected(option)
                            let isFocused = focusedControl == option.id

                            Button {
                                selectOption(option)
                            } label: {
                                HStack(spacing: 16) {
                                    Text(option.title)
                                        .font(.system(size: 26, weight: isSelected ? .bold : .semibold))
                                        .foregroundColor(isFocused ? .black : .white)
                                        .lineLimit(1)

                                    Spacer()

                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 22, weight: .black))
                                            .foregroundColor(isFocused ? .black : .white)
                                    }
                                }
                                .padding(.horizontal, 24)
                                .frame(height: 68)
                                .modifier(
                                    TvDetailsGlassBackground(
                                        filled: isFocused,
                                        shape: Capsule()
                                    )
                                )
                            }
                            .buttonStyle(PosterCardButtonStyle())
                            .focused($focusedControl, equals: option.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 460)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .focusSection()
            }
            .padding(38)
            .frame(width: 840)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Color(white: 0.12).opacity(0.94))
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.65), radius: 36, y: 16)
        }
        .onAppear {
            let saved = currentSavedLanguage
            selectedValue = saved
            let targetFocus = saved ?? "default"
            DispatchQueue.main.async {
                focusedControl = targetFocus
            }
        }
        .onExitCommand {
            onDismiss()
        }
    }

    private func isOptionSelected(_ option: AudioLanguageOption) -> Bool {
        if option.value == nil {
            return selectedValue == nil
        }
        return selectedValue?.caseInsensitiveCompare(option.value!) == .orderedSame
    }

    private func selectOption(_ option: AudioLanguageOption) {
        selectedValue = option.value
        ShowAudioLanguageStore.setLanguage(option.value, for: meta.id)
        onDismiss()
    }
}

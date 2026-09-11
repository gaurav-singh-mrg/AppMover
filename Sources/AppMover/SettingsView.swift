import SwiftUI
import AppMoverKit

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.title2.weight(.semibold)).padding([.horizontal, .top], 20)

            Form {
                Section("Destination") {
                    Picker("Drive", selection: destinationBinding) {
                        if state.candidateDestinations.isEmpty {
                            Text("No external drive connected").tag(String?.none)
                        }
                        ForEach(state.candidateDestinations) { volume in
                            Text("\(volume.name) — \(volume.availableBytes.asStorage) free")
                                .tag(String?.some(volume.uuid))
                        }
                    }
                    TextField("Folder on drive", text: folderBinding)
                        .help("Folders are filed under this by category.")

                    if let volume = state.destination {
                        LabeledContent("Layout") {
                            Text("\(volume.name)/\(state.settings.destinationFolder)/Application Support/…")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    if let speed = state.destinationSpeed {
                        LabeledContent("Write speed") {
                            HStack(spacing: 6) {
                                if speed.isSlow {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                }
                                Text(speed.summary).font(.callout.monospacedDigit())
                            }
                        }
                        if speed.isSlow {
                            Text(speed.warning).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("What to show") {
                    ForEach(FolderCategory.dataCategories) { category in
                        Toggle(isOn: categoryBinding(category)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.label)
                                Text(category.explanation)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Application bundles") {
                    Toggle(isOn: bundlesBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Also move applications themselves")
                            Text(FolderCategory.applications.explanation)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if state.settings.moveApplicationBundles {
                        Label("""
                            Apps installed for all users are owned by the system and will ask \
                            for an administrator. Apple's own apps are protected and cannot be \
                            moved at all — those are shown but not offered.
                            """, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520, height: 560)
    }

    // MARK: - Bindings that persist on change

    private var destinationBinding: Binding<String?> {
        Binding(get: { state.settings.destinationUUID },
                set: { value in Task { await state.updateSettings { $0.destinationUUID = value } } })
    }

    private var folderBinding: Binding<String> {
        Binding(get: { state.settings.destinationFolder },
                set: { value in
                    let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
                    Task { await state.updateSettings {
                        $0.destinationFolder = cleaned.isEmpty ? "AppMover" : cleaned
                    } }
                })
    }

    private func categoryBinding(_ category: FolderCategory) -> Binding<Bool> {
        Binding(get: { state.settings.enabledCategories.contains(category) },
                set: { on in
                    Task { await state.updateSettings {
                        if on { $0.enabledCategories.insert(category) }
                        else { $0.enabledCategories.remove(category) }
                    } }
                })
    }

    private var bundlesBinding: Binding<Bool> {
        Binding(get: { state.settings.moveApplicationBundles },
                set: { on in
                    Task { await state.updateSettings {
                        $0.moveApplicationBundles = on
                        if on { $0.enabledCategories.insert(.applications) }
                        else { $0.enabledCategories.remove(.applications) }
                    } }
                })
    }
}

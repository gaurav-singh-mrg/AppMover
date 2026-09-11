import SwiftUI
import AppMoverKit

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var pendingMove: FolderSize?

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            DestinationBar()
            Divider()

            if state.readFailed {
                FullDiskAccessNotice()
            } else {
                List {
                    if !state.ledger.links.isEmpty {
                        Section("Moved to \(state.destination?.name ?? "external storage")") {
                            ForEach(state.ledger.links) { record in
                                MovedRow(record: record)
                            }
                        }
                    }
                    if !state.unmanagedLinks.isEmpty {
                        Section("Already linked elsewhere") {
                            ForEach(state.unmanagedLinks) { folder in
                                UnmanagedRow(folder: folder)
                            }
                        }
                    }
                    Section("On your startup disk") {
                        if state.isScanning && state.folders.isEmpty {
                            HStack { ProgressView().controlSize(.small); Text("Scanning…") }
                        }
                        ForEach(state.movable) { folder in
                            FolderRow(folder: folder, largest: state.movable.first?.bytes ?? 1) {
                                pendingMove = folder
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            if let busy = state.busyMessage {
                Divider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout)
                    Spacer()
                }
                .padding(10)
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .task { await state.refresh() }
        .confirmationDialog(
            "Move \(pendingMove?.name ?? "")?",
            isPresented: .constant(pendingMove != nil),
            presenting: pendingMove
        ) { folder in
            Button("Move to \(state.destination?.name ?? "drive")") {
                let target = folder
                pendingMove = nil
                Task { await state.move(target) }
            }
            Button("Cancel", role: .cancel) { pendingMove = nil }
        } message: { folder in
            Text("""
                \(folder.name) will live on \(state.destination?.name ?? "the external drive"), \
                with a link left behind so the app still finds it.

                Quit the app that uses it first. While the drive is disconnected that app \
                cannot reach its data. Time Machine does not follow links, so this folder \
                will drop out of your backups.
                """)
        }
        .alert("Couldn't finish", isPresented: .constant(state.errorMessage != nil)) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

struct DestinationBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.title2).foregroundStyle(.tint)

            Picker("Move to", selection: $state.destinationUUID) {
                if state.candidateDestinations.isEmpty {
                    Text("No external drive connected").tag(String?.none)
                }
                ForEach(state.candidateDestinations) { volume in
                    Text("\(volume.name) — \(volume.availableBytes.asStorage) free")
                        .tag(String?.some(volume.uuid))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 300)

            Spacer()

            if state.reclaimedBytes > 0 {
                Text("\(state.reclaimedBytes.asStorage) reclaimed")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button {
                Task { await state.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(state.isScanning)
        }
        .padding(12)
    }
}

struct FullDiskAccessNotice: View {
    var body: some View {
        ContentUnavailableView {
            Label("Can't read your Library", systemImage: "lock.shield")
        } description: {
            Text("Grant AppMover Full Disk Access, then reopen it.")
        } actions: {
            Button("Open Privacy Settings") {
                let path = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                if let url = URL(string: path) { NSWorkspace.shared.open(url) }
            }
        }
    }
}

extension Int64 {
    var asStorage: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

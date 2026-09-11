import SwiftUI
import AppMoverKit

@main
struct AppMoverApp: App {
    @State private var state = AppState()

    var body: some Scene {
        Window("AppMover", id: "main") {
            ContentView().environment(state)
        }
        .defaultSize(width: 720, height: 520)

        // ponytail: menu bar shows link health at a glance. No LaunchAgent -- verification
        // happens when the window opens and when you press refresh, which is enough until
        // unplugging proves otherwise.
        MenuBarExtra("AppMover", systemImage: state.hasProblem ? "externaldrive.badge.xmark"
                                                               : "externaldrive") {
            if state.ledger.links.isEmpty {
                Text("Nothing moved yet")
            } else {
                ForEach(state.ledger.links) { record in
                    Label(record.displayName, systemImage: state.health(record).symbol)
                }
                Divider()
                Text("\(state.reclaimedBytes.asStorage) reclaimed")
            }
            Divider()
            Button("Open AppMover") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

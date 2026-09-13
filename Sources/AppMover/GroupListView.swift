import SwiftUI
import AppMoverKit

enum ListTab: Hashable {
    case onThisMac
    case moved

    var title: String {
        switch self {
        case .onThisMac: String(localized: "On This Mac")
        case .moved: String(localized: "Moved")
        }
    }
}

/// The list of app rows, shown once per tab.
struct GroupListView: View {
    @Environment(AppState.self) private var state
    let tab: ListTab
    let groups: [AppGroup]
    let move: (AppGroup) -> Void

    var body: some View {
        if groups.isEmpty {
            if state.isSearching {
                ContentUnavailableView.search(text: state.searchText)
            } else if state.isScanning {
                ContentUnavailableView {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Scanning…") }
                }
            } else {
                ContentUnavailableView(emptyTitle, systemImage: emptyIcon,
                                       description: Text(emptyMessage))
            }
        } else {
            List {
                ForEach(groups) { group in
                    AppRow(group: group) { move(group) }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
        }
    }

    private var emptyTitle: String {
        tab == .moved ? String(localized: "Nothing moved yet") : String(localized: "Nothing left to move")
    }

    private var emptyIcon: String {
        tab == .moved ? "externaldrive" : "checkmark.circle"
    }

    private var emptyMessage: String {
        switch tab {
        case .moved:
            String(localized: "Move an app from On This Mac and it appears here, with a button to put it back.")
        case .onThisMac:
            String(localized: "Every folder AppMover can see is already on the drive.")
        }
    }
}

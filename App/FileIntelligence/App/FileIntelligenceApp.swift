import FileIntelligenceKit
import SwiftUI

@main
struct FileIntelligenceApp: App {
    @State private var launch = LaunchState.make()

    var body: some Scene {
        WindowGroup("File Intelligence") {
            LaunchRootView(launch: launch)
        }
        .defaultSize(width: 1_240, height: 780)
        .commands {
            AppCommands(model: launch.model)
        }

        Settings {
            if let model = launch.model {
                SettingsView()
                    .environment(model)
                    .frame(width: 620, height: 640)
            } else {
                Text("Settings are unavailable because the index could not be opened.")
                    .padding()
            }
        }
    }
}

/// The index is opened once at launch. If that fails, the app explains why instead of showing empty data.
enum LaunchState {
    case ready(AppModel)
    case failed(String)

    @MainActor
    static func make() -> LaunchState {
        do {
            return .ready(AppModel(environment: try IndexEnvironment.production()))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    var model: AppModel? {
        if case .ready(let model) = self { return model }
        return nil
    }
}

struct LaunchRootView: View {
    let launch: LaunchState

    var body: some View {
        switch launch {
        case .ready(let model):
            ContentView()
                .environment(model)
                .task { await model.start() }
        case .failed(let message):
            ContentUnavailableView {
                Label("The Index Couldn’t Be Opened", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(message)
            }
            .frame(minWidth: 520, minHeight: 320)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Location…") { model?.presentAddLocations() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model == nil)
        }
        CommandMenu("Index") {
            Button("Scan All Locations") { model?.scanAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Process Pending Items") { model?.processNow() }
                .disabled(model == nil)
            Divider()
            ForEach(SidebarItem.allCases) { item in
                Button(item.title) { model?.selection = item }
                    .keyboardShortcut(item.shortcut, modifiers: .command)
                    .disabled(model == nil)
            }
        }
    }
}

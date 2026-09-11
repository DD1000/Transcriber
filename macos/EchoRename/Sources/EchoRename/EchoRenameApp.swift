import AppKit
import SwiftUI

@main
enum ClipNameLauncher {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--benchmark" {
            // Explicit headless test mode: never initialize the UI or rename files.
            Task {
                let code = await VideoBenchmark.run(arguments: Array(CommandLine.arguments.dropFirst(2)))
                exit(code)
            }
            dispatchMain()
        } else {
            ClipNameApp.main()
        }
    }
}

struct ClipNameApp: App {
    @StateObject private var viewModel = VideoRenameViewModel()

    init() {
        // Swift Package executables do not always opt into the normal macOS app
        // lifecycle. Mark this as a regular app so it owns a Dock icon and can
        // be brought to the foreground like any other Mac application.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 920, minHeight: 650)
        }
        .defaultSize(width: 1080, height: 760)
    }
}

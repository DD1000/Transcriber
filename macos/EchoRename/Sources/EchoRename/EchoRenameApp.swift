import SwiftUI

@main
struct EchoRenameApp: App {
    @StateObject private var viewModel = VideoRenameViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 920, minHeight: 650)
        }
        .defaultSize(width: 1080, height: 760)
    }
}

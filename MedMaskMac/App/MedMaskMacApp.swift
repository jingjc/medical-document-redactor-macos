import SwiftUI

@main
struct MedMaskMacApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            MedMaskRootView(viewModel: viewModel)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .commands {
            MedMaskCommands(viewModel: viewModel)
        }
    }
}

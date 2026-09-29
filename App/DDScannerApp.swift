// DDScannerApp —— iOS 17+ 应用入口（占位，见 docs/architecture.md）。
import SwiftUI

@main
struct DDScannerApp: App {
    private let scanEnvironment = AppCompositionRoot.makeScanEnvironment()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.scanEnvironment, scanEnvironment)
        }
    }
}

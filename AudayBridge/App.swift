import SwiftUI

@main
struct AudayBridgeApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup { ContentView(model: model).frame(minWidth: 1050, minHeight: 760) }
            .defaultSize(width: 1180, height: 850)
    }
}

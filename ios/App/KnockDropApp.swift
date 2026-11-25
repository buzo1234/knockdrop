import SwiftUI

@main
struct KnockDropApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainView(model: model)
        }
    }
}

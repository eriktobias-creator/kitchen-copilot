import SwiftUI

@main
struct KitchenCopilotApp: App {
    @State private var model = AssistantViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { await model.start() }
        }
    }
}

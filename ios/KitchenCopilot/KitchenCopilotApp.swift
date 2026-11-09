import MWDATCore
import SwiftUI

@main
struct KitchenCopilotApp: App {
    @State private var model = AssistantViewModel()

    init() {
        do {
            try Wearables.configure()
        } catch {
            print("Meta Wearables toolkit failed to configure: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { await model.start() }
                // Meta AI calls back here after registration/permission screens.
                .onOpenURL { GlassesLink.handle(url: $0) }
        }
    }
}

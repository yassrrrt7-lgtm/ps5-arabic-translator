import SwiftUI

@main
struct PS5TranslatorApp: App {

    @StateObject private var engine = TranslationEngine.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                DashboardView(engine: engine)
                    .tabItem {
                        Label("لوحة التحكم", systemImage: "gamecontroller.fill")
                    }

                ModelAndGlossaryManagerView(engine: engine)
                    .tabItem {
                        Label("النماذج والقاموس", systemImage: "cpu.fill")
                    }
            }
            .environment(\.layoutDirection, .rightToLeft)
            .preferredColorScheme(.dark)
            .task {
                if !engine.isServerRunning {
                    engine.startServer()
                }
                await engine.autoLoadPreferredModelIfPresent()
            }
        }
    }
}

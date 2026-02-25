import SwiftUI

@main
struct LLMitsApp: App {
    @StateObject private var dashboardVM = UsageDashboardViewModel()
    @StateObject private var accountsVM = AccountsViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover()
                .environmentObject(dashboardVM)
                .environmentObject(accountsVM)
        } label: {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
    }
}

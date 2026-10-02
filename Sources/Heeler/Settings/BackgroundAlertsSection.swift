import SwiftUI
import UIKit
import UserNotifications

/// The free build's notification settings: the Background Alerts switch, and
/// whether iOS lets them through at all.
struct BackgroundAlertsSection: View {
    @Bindable private var settings = BackgroundAlertsSettings.shared
    @State private var permission: UNAuthorizationStatus?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Toggle("Background Alerts", isOn: $settings.isEnabled)
            if settings.isEnabled, permission == .denied {
                Button("Allow Notifications in Settings", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        } header: {
            Text("Agent Notifications")
        } footer: {
            Text(
                "This build cannot receive push notifications, so Heeler stays running in the "
                    + "background and alerts you itself when an Agent finishes or needs your "
                    + "input. It plays silence to stay awake, which uses some battery, and stops "
                    + "if you swipe Heeler away or restart the phone — open it again to resume.")
        }
        .task { await refreshPermission() }
        .onChange(of: settings.isEnabled) {
            Task {
                // The first switch-on asks; give the prompt a moment to land.
                try? await Task.sleep(for: .seconds(1))
                await refreshPermission()
            }
        }
    }

    private func refreshPermission() async {
        permission = await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
    }
}

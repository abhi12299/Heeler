import Foundation
import Testing

@testable import Heeler

/// Background Alerts (free build): when an alert goes out as a local
/// notification, what it carries back to the tap, and the keep-alive that
/// makes background delivery possible.
@MainActor
@Suite("Background alerts")
struct BackgroundAlertsTests {
    private final class FakeKeepAlive: BackgroundKeepAlive {
        var isRunning = false
        var starts = 0
        var stops = 0
        /// A refused audio session: start runs but nothing plays.
        var refuses = false

        func start() {
            starts += 1
            isRunning = !refuses
        }

        func stop() {
            stops += 1
            isRunning = false
        }
    }

    private final class FakeNotifier: LocalNotificationPosting {
        var authorizationRequests = 0
        var posted: [LocalAgentNotification.Request] = []

        func requestAuthorization() { authorizationRequests += 1 }
        func post(_ request: LocalAgentNotification.Request) { posted.append(request) }
    }

    private let keepAlive = FakeKeepAlive()
    private let notifier = FakeNotifier()

    private func makeSettings(enabled: Bool? = nil) -> BackgroundAlertsSettings {
        let name = "background-alerts-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = BackgroundAlertsSettings(defaults: defaults)
        if let enabled { settings.isEnabled = enabled }
        return settings
    }

    private func makeController(
        settings: BackgroundAlertsSettings? = nil, isAvailable: Bool = true
    ) -> BackgroundAlertsController {
        BackgroundAlertsController(
            settings: settings ?? makeSettings(), keepAlive: keepAlive, notifier: notifier,
            isAvailable: isAvailable)
    }

    private let hostID = UUID()

    private func banner(_ paneID: String = "wV:p1") -> AgentNotificationBanner {
        AgentNotificationBanner(
            target: AgentNotificationTarget(hostID: hostID, paneID: paneID),
            alert: AgentNotificationAlert(title: "app · Claude Code", body: "Done"))
    }

    @Test func theSwitchIsOnUntilTurnedOffAndRemembersThat() {
        let name = "background-alerts-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(BackgroundAlertsSettings(defaults: defaults).isEnabled)
        BackgroundAlertsSettings(defaults: defaults).isEnabled = false
        #expect(!BackgroundAlertsSettings(defaults: defaults).isEnabled)
    }

    @Test func becomingActiveArmsTheKeepAliveAndAsksForPermissionOnce() {
        let controller = makeController()

        controller.sceneDidBecomeActive()
        controller.sceneDidEnterBackground()
        controller.sceneDidBecomeActive()

        #expect(keepAlive.isRunning)
        #expect(notifier.authorizationRequests == 1)
        #expect(controller.keepsConnectionsInBackground)
    }

    @Test func turningTheSwitchOffDisarmsEverything() {
        let settings = makeSettings()
        let controller = makeController(settings: settings)
        controller.sceneDidBecomeActive()

        settings.isEnabled = false
        controller.settingsDidChange()
        controller.sceneDidEnterBackground()

        #expect(!keepAlive.isRunning)
        #expect(!controller.keepsConnectionsInBackground)
        #expect(controller.fallbackTriggers == nil)
        #expect(!controller.deliver(banner()))
        #expect(notifier.posted.isEmpty)
    }

    /// The connections survive backgrounding only while something actually
    /// keeps the process awake; otherwise the usual grace-period teardown
    /// must run or they would freeze half-open.
    @Test func aRefusedAudioSessionLeavesTheGracePeriodInCharge() {
        keepAlive.refuses = true
        let controller = makeController()
        controller.sceneDidBecomeActive()

        #expect(keepAlive.starts == 1)
        #expect(!controller.keepsConnectionsInBackground)
    }

    @Test func aStoreBuildNeverArmsOrDelivers() {
        let controller = makeController(isAvailable: false)
        controller.sceneDidBecomeActive()
        controller.sceneDidEnterBackground()

        #expect(keepAlive.starts == 0)
        #expect(notifier.authorizationRequests == 0)
        #expect(controller.fallbackTriggers == nil)
        #expect(!controller.deliver(banner()))
    }

    @Test func onlyABackgroundedAppPostsTheAlert() {
        let controller = makeController()
        controller.sceneDidBecomeActive()

        #expect(!controller.deliver(banner()))
        controller.sceneDidEnterBackground()
        #expect(controller.deliver(banner()))

        #expect(notifier.posted == [LocalAgentNotification.request(for: banner())])
    }

    /// A free build never holds a push registration, so without fallback
    /// flags the banner gate would fail closed on every Host.
    @Test func fallbackFlagsAnnounceBothBlockedAndDone() {
        let controller = makeController()
        #expect(controller.fallbackTriggers == NotificationTriggerPreferences(blocked: true, done: true))
    }

    @Test func aRequestCarriesTheAlertAndOneIdentityPerAgent() {
        let request = LocalAgentNotification.request(for: banner())

        #expect(request.title == "app · Claude Code")
        #expect(request.body == "Done")
        #expect(request.identifier == "agent:\(hostID.uuidString):wV:p1")
        #expect(request.threadIdentifier == "host:\(hostID.uuidString)")
        #expect(
            LocalAgentNotification.request(for: banner("wV:p2")).identifier != request.identifier)
    }

    @Test func aTappedAlertLeadsBackToItsAgent() {
        let request = LocalAgentNotification.request(for: banner())
        let userInfo: [AnyHashable: Any] = request.userInfo

        #expect(
            LocalAgentNotification.target(userInfo: userInfo)
                == AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))
    }

    @Test func anythingElseIsNotALocalAlert() {
        let key = LocalAgentNotification.userInfoKey
        #expect(LocalAgentNotification.target(userInfo: [:]) == nil)
        #expect(
            LocalAgentNotification.target(userInfo: [key: ["host": "not-a-uuid", "pane": "wV:p1"]])
                == nil)
        #expect(
            LocalAgentNotification.target(userInfo: [key: ["host": UUID().uuidString, "pane": ""]])
                == nil)
        #expect(LocalAgentNotification.target(userInfo: [key: "flat string"]) == nil)
    }
}

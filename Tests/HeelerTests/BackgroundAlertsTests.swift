import AVFoundation
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
        var onDrop: (@MainActor () -> Void)?
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
        var withdrawn: [String] = []

        func requestAuthorization() { authorizationRequests += 1 }
        func post(_ request: LocalAgentNotification.Request) { posted.append(request) }
        func withdraw(identifier: String) { withdrawn.append(identifier) }
    }

    /// Silent audio that iOS can stop behind the keep-alive's back.
    private final class FakeOutput: SilentAudioOutput {
        var isPlaying = false
        var plays = 0
        var deactivations = 0
        /// The session refuses to play, as it does mid-call or once the
        /// app is backgrounded with the session inactive.
        var refuses = false

        struct Refused: Error {}

        func play() throws {
            plays += 1
            if refuses { throw Refused() }
            isPlaying = true
        }

        func halt() { isPlaying = false }
        func deactivate() { deactivations += 1 }
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

    /// Losing the connections is said once per background trip, while the
    /// process can still post, and the notice goes away on return.
    @Test func aPauseIsAnnouncedOncePerBackgroundTrip() {
        keepAlive.refuses = true
        let controller = makeController()
        controller.sceneDidBecomeActive()

        controller.sceneDidEnterBackground()
        controller.connectionsWillPause()
        controller.connectionsWillPause()
        #expect(notifier.posted == [LocalAgentNotification.pausedNotice])

        controller.sceneDidBecomeActive()
        #expect(notifier.withdrawn == [LocalAgentNotification.pausedNotice.identifier])
        controller.sceneDidEnterBackground()
        controller.connectionsWillPause()
        #expect(notifier.posted.count == 2)
    }

    /// With the switch off the user chose silence; there is nothing to warn
    /// about.
    @Test func noPauseNoticeWhileTheSwitchIsOff() {
        let controller = makeController(settings: makeSettings(enabled: false))
        controller.sceneDidBecomeActive()
        controller.sceneDidEnterBackground()
        controller.connectionsWillPause()

        #expect(notifier.posted.isEmpty)
    }

    @Test func aKeepAliveDroppedInTheBackgroundAsksForTheTeardown() {
        let controller = makeController()
        var lost = 0
        controller.onKeepAliveLost = { lost += 1 }
        controller.sceneDidBecomeActive()

        keepAlive.onDrop?()
        #expect(lost == 0)

        controller.sceneDidEnterBackground()
        keepAlive.isRunning = false
        keepAlive.onDrop?()
        #expect(lost == 1)
        #expect(!controller.keepsConnectionsInBackground)
    }

    @Test func runningIsReadFromTheOutputNotRemembered() {
        let output = FakeOutput()
        let keepAlive = SilentAudioKeepAlive(output: output, healthCheckInterval: nil)
        keepAlive.start()
        #expect(keepAlive.isRunning)

        // iOS stopped the engine and said nothing.
        output.isPlaying = false
        #expect(!keepAlive.isRunning)

        keepAlive.checkHealth()
        #expect(keepAlive.isRunning)
        #expect(output.plays == 2)
    }

    /// iOS may end an interruption without `.shouldResume`; the keep-alive
    /// restarts anyway, and a failed restart mid-interruption is no drop.
    @Test func anEndedInterruptionRestartsWithoutShouldResume() throws {
        let output = FakeOutput()
        let keepAlive = SilentAudioKeepAlive(output: output, healthCheckInterval: nil)
        var drops = 0
        keepAlive.onDrop = { drops += 1 }
        keepAlive.start()

        keepAlive.handle(.interruptionBegan)
        output.isPlaying = false
        output.refuses = true
        keepAlive.checkHealth()
        #expect(drops == 0)

        output.refuses = false
        let ended = Notification(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
            ])
        keepAlive.handle(try #require(SilentAudioKeepAlive.event(for: ended)))
        #expect(keepAlive.isRunning)
        #expect(drops == 0)
    }

    @Test func aConfigurationChangeRestartsAndARouteChangeOnlyWhenDead() {
        let output = FakeOutput()
        let keepAlive = SilentAudioKeepAlive(output: output, healthCheckInterval: nil)
        keepAlive.start()

        keepAlive.handle(.routeChanged)
        #expect(output.plays == 1)

        keepAlive.handle(.engineReconfigured)
        #expect(output.plays == 2)

        output.isPlaying = false
        keepAlive.handle(.routeChanged)
        #expect(output.plays == 3)
        #expect(keepAlive.isRunning)
    }

    @Test func aRestartThatFailsReportsADrop() {
        let output = FakeOutput()
        let keepAlive = SilentAudioKeepAlive(output: output, healthCheckInterval: nil)
        var drops = 0
        keepAlive.onDrop = { drops += 1 }
        keepAlive.start()

        output.isPlaying = false
        output.refuses = true
        keepAlive.handle(.engineReconfigured)

        #expect(drops == 1)
    }

    /// Dictation records on the shared session; playing over it would take
    /// the microphone away mid-sentence.
    @Test func aLentSessionIsLeftAloneUntilReturned() {
        let output = FakeOutput()
        let keepAlive = SilentAudioKeepAlive(output: output, healthCheckInterval: nil)
        keepAlive.start()

        keepAlive.handle(.sessionLent)
        output.isPlaying = false
        keepAlive.handle(.engineReconfigured)
        keepAlive.handle(.routeChanged)
        keepAlive.checkHealth()
        #expect(output.plays == 1)

        keepAlive.handle(.sessionReturned)
        #expect(keepAlive.isRunning)
        #expect(output.plays == 2)
    }

    @Test func aStoppedKeepAliveStaysStopped() {
        let output = FakeOutput()
        let keepAlive = SilentAudioKeepAlive(output: output, healthCheckInterval: nil)
        keepAlive.start()
        keepAlive.stop()

        keepAlive.handle(.interruptionEnded)
        keepAlive.handle(.mediaServicesReset)
        keepAlive.checkHealth()

        #expect(!keepAlive.isRunning)
        #expect(output.plays == 1)
        #expect(output.deactivations == 1)
    }

    @Test func theAudioNotificationsMapToEvents() {
        func event(_ name: Notification.Name, _ userInfo: [AnyHashable: Any]? = nil)
            -> SilentAudioKeepAlive.Event?
        {
            SilentAudioKeepAlive.event(
                for: Notification(name: name, object: nil, userInfo: userInfo))
        }
        let began = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ]
        #expect(event(AVAudioSession.interruptionNotification, began) == .interruptionBegan)
        #expect(event(AVAudioSession.interruptionNotification) == nil)
        #expect(event(AVAudioSession.routeChangeNotification) == .routeChanged)
        #expect(event(.AVAudioEngineConfigurationChange) == .engineReconfigured)
        #expect(event(AVAudioSession.mediaServicesWereResetNotification) == .mediaServicesReset)
        #expect(event(SpeechDictationEngine.audioSessionBorrowed) == .sessionLent)
        #expect(event(SpeechDictationEngine.audioSessionReleased) == .sessionReturned)
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

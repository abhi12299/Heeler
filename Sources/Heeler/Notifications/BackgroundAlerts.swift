import AVFoundation
import Foundation
import Observation
import UserNotifications

/// Background Alerts: Agent Notifications for a build that cannot receive
/// push. A free Apple ID team cannot sign `aps-environment`, so no APNs route
/// reaches the app at all; the only way it can announce a Done or Blocked
/// Agent is to stay running and post the notification itself from the live
/// event stream. It stays running by holding a silent, mixable audio session
/// (the `audio` background mode, which needs no entitlement), and keeps its
/// Host connections up instead of tearing them down after the grace period.
///
/// Available only in the free build (`HEELER_FREE_BUILD`): a store build has
/// push, and App Review would not accept the keep-alive.
enum BackgroundAlerts {
    static var isAvailable: Bool {
        #if HEELER_FREE_BUILD
            true
        #else
            false
        #endif
    }

    /// The free build's stdout diagnostics, read with `devicectl --console`.
    static func note(_ message: String) {
        #if HEELER_FREE_BUILD
            print("[BackgroundAlerts] \(message)")
        #endif
    }
}

/// A local notification's content and tap target, kept as plain values so
/// the encoding and its inverse are testable without `UNUserNotificationCenter`.
enum LocalAgentNotification {
    static let userInfoKey = "heelerLocalTarget"

    struct Request: Equatable, Sendable {
        /// One per Agent, so a newer transition replaces an older one instead
        /// of stacking.
        let identifier: String
        let title: String
        let body: String
        /// Groups a Host's notifications together.
        let threadIdentifier: String
        let userInfo: [String: [String: String]]
    }

    static func request(for banner: AgentNotificationBanner) -> Request {
        let host = banner.target.hostID.uuidString
        return Request(
            identifier: "agent:\(host):\(banner.target.paneID)",
            title: banner.alert.title,
            body: banner.alert.body,
            threadIdentifier: "host:\(host)",
            userInfo: [userInfoKey: ["host": host, "pane": banner.target.paneID]])
    }

    /// The Agent a tapped local notification points at; nil for anything
    /// else, including a push, which `AgentNotificationRouting` decrypts.
    static func target(userInfo: [AnyHashable: Any]) -> AgentNotificationTarget? {
        guard let fields = userInfo[userInfoKey] as? [String: String],
            let host = fields["host"].flatMap(UUID.init(uuidString:)),
            let pane = fields["pane"], !pane.isEmpty
        else { return nil }
        return AgentNotificationTarget(hostID: host, paneID: pane)
    }

    /// Posted while the process is still alive, once it is about to stop
    /// listening: without it, a frozen app looks exactly like quiet Agents.
    static let pausedNotice = Request(
        identifier: "heeler:paused",
        title: "Heeler paused",
        body: "Alerts are off until you open it.",
        threadIdentifier: "heeler:paused",
        userInfo: [:])
}

/// The user's switch, on by default: the point of the free build's alerts is
/// that they work without first finding a setting.
@MainActor
@Observable
final class BackgroundAlertsSettings {
    static let shared = BackgroundAlertsSettings()
    private static let defaultsKey = "backgroundAlertsEnabled"

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.defaultsKey) }
    }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }
}

/// Keeps the process running while backgrounded.
@MainActor
protocol BackgroundKeepAlive: AnyObject {
    var isRunning: Bool { get }
    /// Called when the keep-alive stopped and could not restart itself.
    var onDrop: (@MainActor () -> Void)? { get set }
    func start()
    func stop()
}

/// Posts a local notification.
@MainActor
protocol LocalNotificationPosting: AnyObject {
    func requestAuthorization()
    func post(_ request: LocalAgentNotification.Request)
    func withdraw(identifier: String)
}

/// Decides, per transition, whether the free build's alert goes out as a
/// local notification, and runs the keep-alive that makes background
/// delivery possible at all.
@MainActor
@Observable
final class BackgroundAlertsController {
    private(set) var isInBackground = false
    @ObservationIgnored private let settings: BackgroundAlertsSettings
    @ObservationIgnored private let keepAlive: any BackgroundKeepAlive
    @ObservationIgnored private let notifier: any LocalNotificationPosting
    @ObservationIgnored private let isAvailable: Bool
    @ObservationIgnored private var requestedAuthorization = false
    @ObservationIgnored private var postedPausedNotice = false
    /// Runs when the keep-alive drops while backgrounded, so the Host
    /// connections get the grace-period teardown instead of freezing open.
    @ObservationIgnored var onKeepAliveLost: (@MainActor () -> Void)?

    init(
        settings: BackgroundAlertsSettings = .shared,
        keepAlive: any BackgroundKeepAlive = SilentAudioKeepAlive(),
        notifier: any LocalNotificationPosting = UserNotificationPoster(),
        isAvailable: Bool = BackgroundAlerts.isAvailable
    ) {
        self.settings = settings
        self.keepAlive = keepAlive
        self.notifier = notifier
        self.isAvailable = isAvailable
        keepAlive.onDrop = { [weak self] in self?.keepAliveDidDrop() }
    }

    private var isOn: Bool { isAvailable && settings.isEnabled }

    /// Starts the keep-alive while in the foreground: iOS keeps an app alive
    /// in the background only if its audio was already playing when it left.
    func sceneDidBecomeActive() {
        isInBackground = false
        if postedPausedNotice {
            postedPausedNotice = false
            notifier.withdraw(identifier: LocalAgentNotification.pausedNotice.identifier)
        }
        settingsDidChange()
    }

    func sceneDidEnterBackground() {
        isInBackground = true
        note("backgrounded; keeping connections: \(keepsConnectionsInBackground)")
    }

    /// The Host connections are about to be torn down for this background
    /// trip. Says so once, while the process can still post.
    func connectionsWillPause() {
        guard isOn, isInBackground, !postedPausedNotice else { return }
        postedPausedNotice = true
        notifier.post(LocalAgentNotification.pausedNotice)
        note("posted paused notice")
    }

    private func keepAliveDidDrop() {
        note("keep-alive dropped (background: \(isInBackground))")
        guard isOn, isInBackground else { return }
        onKeepAliveLost?()
    }

    /// Applies the switch: arm on, disarm off.
    func settingsDidChange() {
        guard isOn else {
            keepAlive.stop()
            note("off")
            return
        }
        if !requestedAuthorization {
            requestedAuthorization = true
            notifier.requestAuthorization()
        }
        keepAlive.start()
        note("armed; keep-alive running: \(keepAlive.isRunning)")
    }

    /// Whether the Host connections should survive backgrounding: only while
    /// the keep-alive actually holds the process awake.
    var keepsConnectionsInBackground: Bool { isOn && keepAlive.isRunning }

    /// The notify flags to use for a Host with no push registration. A free
    /// build never has one, so without this the banner gate fails closed on
    /// every Host.
    var fallbackTriggers: NotificationTriggerPreferences? {
        isOn ? NotificationTriggerPreferences() : nil
    }

    /// Posts `banner` as a local notification when the app is in the
    /// background; false leaves it to the in-app banner.
    func deliver(_ banner: AgentNotificationBanner) -> Bool {
        guard isOn, isInBackground else {
            note("transition shown in-app (on: \(isOn), background: \(isInBackground))")
            return false
        }
        notifier.post(LocalAgentNotification.request(for: banner))
        note("posted: \(banner.alert.title) — \(banner.alert.body)")
        return true
    }

    private func note(_ message: String) { BackgroundAlerts.note(message) }
}

/// `UNUserNotificationCenter`, reduced to the two calls Background Alerts
/// makes.
@MainActor
final class UserNotificationPoster: LocalNotificationPosting {
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
            _, _ in
        }
    }

    func post(_ request: LocalAgentNotification.Request) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.threadIdentifier = request.threadIdentifier
        content.userInfo = request.userInfo
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
    }

    func withdraw(identifier: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

/// The silence the keep-alive plays, reduced to what its recovery needs so
/// that recovery can be tested without a live audio session.
@MainActor
protocol SilentAudioOutput: AnyObject {
    /// Whether silence is reaching the output now: the engine and its player
    /// both running, not merely asked to.
    var isPlaying: Bool { get }
    func play() throws
    /// Stops playback but keeps the session active: a backgrounded app cannot
    /// activate it again.
    func halt()
    func deactivate()
}

/// Plays silence through a mixable playback session, which keeps the process
/// running in the background under the `audio` background mode without
/// interrupting anything else the user is listening to.
///
/// iOS stops the engine without asking (an interruption, a route or
/// configuration change, a media-services reset) and then freezes the app
/// once nothing plays, so running is read from the output itself, every such
/// event restarts it, and a periodic health check catches whatever no
/// notification announced. A restart that fails reports `onDrop`.
@MainActor
final class SilentAudioKeepAlive: BackgroundKeepAlive {
    static let defaultHealthCheckInterval: Duration = .seconds(5)

    /// The audio-session notifications the keep-alive reacts to, as values.
    enum Event: Equatable, Sendable {
        case interruptionBegan
        case interruptionEnded
        case mediaServicesReset
        case routeChanged
        case engineReconfigured
        case sessionLent
        case sessionReturned
    }

    var onDrop: (@MainActor () -> Void)?
    private let output: any SilentAudioOutput
    private let healthCheckInterval: Duration?
    private var observers: [NSObjectProtocol] = []
    private var healthCheck: Task<Void, Never>?
    private var wanted = false
    /// The system holds the session until the interruption ends. A failed
    /// restart meanwhile is expected, not a drop.
    private var interrupted = false
    /// Dictation is recording on the shared session; playing now would take
    /// it back from under the microphone.
    private var lent = false

    var isRunning: Bool { output.isPlaying }

    /// `healthCheckInterval` nil runs no periodic check, for tests.
    init(
        output: any SilentAudioOutput = AVAudioEngineSilence(),
        healthCheckInterval: Duration? = SilentAudioKeepAlive.defaultHealthCheckInterval
    ) {
        self.output = output
        self.healthCheckInterval = healthCheckInterval
        let names: [Notification.Name] = [
            AVAudioSession.interruptionNotification,
            AVAudioSession.mediaServicesWereResetNotification,
            AVAudioSession.routeChangeNotification,
            .AVAudioEngineConfigurationChange,
            SpeechDictationEngine.audioSessionBorrowed,
            SpeechDictationEngine.audioSessionReleased,
        ]
        for name in names {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] notification in
                    guard let event = Self.event(for: notification) else { return }
                    MainActor.assumeIsolated { self?.handle(event) }
                })
        }
    }

    nonisolated static func event(for notification: Notification) -> Event? {
        switch notification.name {
        case AVAudioSession.interruptionNotification:
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            return switch type {
            case .began?: .interruptionBegan
            case .ended?: .interruptionEnded
            default: nil
            }
        case AVAudioSession.mediaServicesWereResetNotification: return .mediaServicesReset
        case AVAudioSession.routeChangeNotification: return .routeChanged
        case .AVAudioEngineConfigurationChange: return .engineReconfigured
        case SpeechDictationEngine.audioSessionBorrowed: return .sessionLent
        case SpeechDictationEngine.audioSessionReleased: return .sessionReturned
        default: return nil
        }
    }

    func start() {
        wanted = true
        startHealthChecks()
        guard !isRunning, !lent else { return }
        play()
    }

    func stop() {
        let wasWanted = wanted
        wanted = false
        healthCheck?.cancel()
        healthCheck = nil
        guard wasWanted || isRunning else { return }
        output.halt()
        if !lent { output.deactivate() }
    }

    func handle(_ event: Event) {
        switch event {
        case .interruptionBegan:
            interrupted = true
            note("interrupted")
        case .interruptionEnded:
            // Restarted whether or not iOS offers `.shouldResume`: without
            // the audio the app is frozen and every alert is lost.
            interrupted = false
            restart(after: "interruption ended")
        case .mediaServicesReset:
            restart(after: "media services reset")
        case .engineReconfigured:
            restart(after: "engine configuration change")
        case .routeChanged:
            checkHealth(after: "route change")
        case .sessionLent:
            lent = true
            note("session lent to dictation")
        case .sessionReturned:
            lent = false
            restart(after: "dictation returned the session")
        }
    }

    /// Restarts the keep-alive if it should be playing and is not.
    func checkHealth(after reason: String = "health check") {
        guard wanted, !isRunning else { return }
        restart(after: reason)
    }

    private func restart(after reason: String) {
        guard wanted, !lent else { return }
        output.halt()
        play()
        note("restarted after \(reason); running: \(isRunning)")
        if !isRunning, !interrupted { onDrop?() }
    }

    private func play() {
        do {
            try output.play()
        } catch {
            note("keep-alive could not play: \(error.localizedDescription)")
        }
        if isRunning { interrupted = false }
    }

    private func startHealthChecks() {
        guard let interval = healthCheckInterval, healthCheck == nil else { return }
        healthCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                checkHealth()
            }
        }
    }

    private func note(_ message: String) { BackgroundAlerts.note(message) }
}

/// One second of silence, looped through a muted `AVAudioEngine` on a
/// mixable playback session.
@MainActor
final class AVAudioEngineSilence: SilentAudioOutput {
    enum Failure: Error {
        /// The output route has no format yet; connecting to it would raise.
        case noOutputFormat
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    init() {
        engine.attach(player)
    }

    var isPlaying: Bool { engine.isRunning && player.isPlaying }

    func play() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
            let silence = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate))
        else { throw Failure.noOutputFormat }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        // A fresh buffer is zero-filled: one second of silence, looped.
        silence.frameLength = silence.frameCapacity
        if !engine.isRunning { try engine.start() }
        player.scheduleBuffer(silence, at: nil, options: .loops)
        player.play()
    }

    func halt() {
        player.stop()
        engine.stop()
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

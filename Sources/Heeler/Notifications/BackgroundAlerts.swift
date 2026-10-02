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
    func start()
    func stop()
}

/// Posts a local notification.
@MainActor
protocol LocalNotificationPosting: AnyObject {
    func requestAuthorization()
    func post(_ request: LocalAgentNotification.Request)
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
    }

    private var isOn: Bool { isAvailable && settings.isEnabled }

    /// Starts the keep-alive while in the foreground: iOS keeps an app alive
    /// in the background only if its audio was already playing when it left.
    func sceneDidBecomeActive() {
        isInBackground = false
        settingsDidChange()
    }

    func sceneDidEnterBackground() {
        isInBackground = true
        note("backgrounded; keeping connections: \(keepsConnectionsInBackground)")
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

    /// The free build's stdout diagnostics, read with `devicectl --console`.
    private func note(_ message: String) {
        #if HEELER_FREE_BUILD
            print("[BackgroundAlerts] \(message)")
        #endif
    }
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
}

/// Plays silence through a mixable playback session, which keeps the process
/// running in the background under the `audio` background mode without
/// interrupting anything else the user is listening to. An interruption (a
/// call, Siri) stops the engine; it is restarted when the interruption ends
/// and after a media-services reset.
@MainActor
final class SilentAudioKeepAlive: BackgroundKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var observers: [NSObjectProtocol] = []
    private var wanted = false

    private(set) var isRunning = false

    init() {
        engine.attach(player)
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                MainActor.assumeIsolated {
                    if type == .began {
                        self?.isRunning = false
                    } else if type == .ended {
                        self?.restartIfWanted()
                    }
                }
            })
        observers.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartIfWanted() }
            })
    }

    func start() {
        wanted = true
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            guard
                let silence = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate))
            else { return }
            // A fresh buffer is zero-filled: one second of silence, looped.
            silence.frameLength = silence.frameCapacity
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.play()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() {
        wanted = false
        guard isRunning || engine.isRunning else { return }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }

    private func restartIfWanted() {
        guard wanted else { return }
        isRunning = false
        player.stop()
        engine.stop()
        start()
    }
}

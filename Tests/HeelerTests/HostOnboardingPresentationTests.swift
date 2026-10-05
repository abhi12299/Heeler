import Foundation
import Testing

@testable import Heeler

@Suite("Host onboarding connection presentation")
struct HostOnboardingPresentationTests {
    /// The Host detail footer shows the Explanation during automatic
    /// `EventsSessionStatus.reconnecting`, and hides it only while a manual
    /// Reconnect request is in flight — including on `.failed` (#160).
    @Test func footerSuppressionFollowsTheManualRequestNotTransportReconnecting() {
        let automatic = HostOnboardingConnectionPresentation(
            status: .reconnecting(
                attempt: 1,
                delay: .seconds(1),
                failure: .timedOut),
            isManualReconnectInFlight: false)
        #expect(automatic.footerMessage == TransportError.timedOut.presentation.explanation)

        let manualDuringReconnect = HostOnboardingConnectionPresentation(
            status: .reconnecting(
                attempt: 1,
                delay: .seconds(1),
                failure: .timedOut),
            isManualReconnectInFlight: true)
        #expect(manualDuringReconnect.footerMessage == nil)

        let manualDuringFailure = HostOnboardingConnectionPresentation(
            status: .failed(.authenticationFailed),
            isManualReconnectInFlight: true)
        #expect(manualDuringFailure.footerMessage == nil)
    }

    @Test func reconnectingFooterIsExplanationAndNeverTheSuggestion() throws {
        let failure = TransportError.sshUnreachable(detail: "connection refused")
        let presentation = HostOnboardingConnectionPresentation(
            status: .reconnecting(
                attempt: 1,
                delay: .seconds(1),
                failure: failure),
            isManualReconnectInFlight: false)
        #expect(presentation.footerMessage == failure.presentation.explanation)
        #expect(presentation.connectionErrorMessage == failure.presentation.explanation)
        let suggestion = try #require(failure.presentation.recoverySuggestion)
        #expect(!(presentation.footerMessage?.contains(suggestion) ?? true))
    }

    @Test func failedFooterIsTheWholePresentation() {
        let failure = TransportError.authenticationFailed
        let presentation = HostOnboardingConnectionPresentation(
            status: .failed(failure),
            isManualReconnectInFlight: false)
        #expect(presentation.footerMessage == failure.presentation.message)
    }

    @Test func footerMatrixCoversEveryHostDetailRow() {
        let failure = TransportError.streamLocalOpenFailed(path: "/tmp/herdr.sock")
        let rows: [(
            EventsSessionStatus?, TransportError?, Bool, String?
        )] = [
            (nil, nil, false, nil),
            (.suspended, nil, false, nil),
            (.connected, nil, false, nil),
            (.ended, nil, false, nil),
            (.connecting, nil, false, nil),
            (.connecting, nil, true, nil),
            (.connecting, failure, false, failure.presentation.message),
            (.connecting, failure, true, nil),
            (
                .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut),
                nil, false, TransportError.timedOut.presentation.explanation
            ),
            (
                .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut),
                nil, true, nil
            ),
            (.failed(failure), nil, false, failure.presentation.message),
            (.failed(failure), nil, true, nil),
        ]
        for (status, standing, inFlight, expected) in rows {
            let presentation = HostOnboardingConnectionPresentation(
                status: status,
                standingFailure: standing,
                isManualReconnectInFlight: inFlight)
            #expect(presentation.footerMessage == expected)
            if inFlight {
                #expect(presentation.footerMessage == nil)
            }
        }
    }

    /// Opened from a "Sync issue" row, the detail says what went wrong.
    @Test func aConnectedHostExplainsItsSyncIssue() {
        let issue = "herdr rejected the Console sync: boom. Retrying…"
        let outOfSync = HostOnboardingConnectionPresentation(
            status: .connected, syncIssue: issue, isManualReconnectInFlight: false)
        #expect(outOfSync.footerMessage == issue)
        #expect(outOfSync.isSyncIssue)

        let reconnectPressed = HostOnboardingConnectionPresentation(
            status: .connected, syncIssue: issue, isManualReconnectInFlight: true)
        #expect(reconnectPressed.footerMessage == nil)

        let inSync = HostOnboardingConnectionPresentation(
            status: .connected, isManualReconnectInFlight: false)
        #expect(inSync.footerMessage == nil)
        #expect(!inSync.isSyncIssue)

        let failure = TransportError.authenticationFailed
        let stopped = HostOnboardingConnectionPresentation(
            status: .failed(failure), syncIssue: issue, isManualReconnectInFlight: false)
        #expect(stopped.footerMessage == failure.presentation.message)
        #expect(!stopped.isSyncIssue)
    }

    @Test func aManualRequestDoesNotRewriteStatusDerivedCopy() {
        let failure = TransportError.authenticationFailed
        let suppressed = HostOnboardingConnectionPresentation(
            status: .failed(failure),
            isManualReconnectInFlight: true)
        #expect(suppressed.footerMessage == nil)
        #expect(suppressed.connectionErrorMessage == failure.presentation.message)

        let automatic = HostOnboardingConnectionPresentation(
            status: .reconnecting(
                attempt: 2, delay: .seconds(2), failure: .timedOut),
            isManualReconnectInFlight: false)
        #expect(automatic.footerMessage == TransportError.timedOut.presentation.explanation)
        #expect(automatic.connectionErrorMessage == automatic.footerMessage)

        let connectingStanding = HostOnboardingConnectionPresentation(
            status: .connecting,
            standingFailure: failure,
            isManualReconnectInFlight: true)
        #expect(connectingStanding.footerMessage == nil)
        #expect(connectingStanding.connectionErrorMessage == failure.presentation.message)
    }

    /// The Console never prompts for trust: once onboarding pins the key and
    /// the preflight passes, a Console failed on that key retries once.
    @Test func passingPreflightRetriesOnlyAConsoleFailedOnHostKeyTrust() {
        let key = HostKeyFingerprint(publicKeyBlob: Data("presented".utf8))
        let rejected = TransportError.hostKeyRejected(presented: key)
        let mismatch = TransportError.hostKeyMismatch(
            known: HostKeyFingerprint(publicKeyBlob: Data("known".utf8)), presented: key)
        let rows: [(Bool, EventsSessionStatus?, Bool, HostOnboardingConsoleRecovery.Action)] = [
            (true, .failed(rejected), false, .retry),
            (true, .failed(mismatch), false, .retry),
            (true, .failed(.jumpHostFailed(rejected)), false, .retry),
            // A manual Reconnect is already retrying: decide after it.
            (true, .failed(rejected), true, .wait),
            // The Console has not settled yet.
            (true, .connecting, false, .wait),
            (true, .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut), false, .wait),
            // Any other settled state spends the proof without a retry.
            (true, .connected, false, .disarm),
            (true, .failed(.authenticationFailed), false, .disarm),
            (true, .failed(.jumpHostFailed(.authenticationFailed)), false, .disarm),
            (true, .suspended, false, .disarm),
            (true, nil, false, .disarm),
            // No passing preflight to act on.
            (false, .failed(rejected), false, .wait),
        ]
        for (isArmed, status, inFlight, expected) in rows {
            let input = HostOnboardingConsoleRecovery.Input(
                isArmed: isArmed, status: status, isManualReconnectInFlight: inFlight)
            #expect(HostOnboardingConsoleRecovery.action(for: input) == expected)
        }
    }
}

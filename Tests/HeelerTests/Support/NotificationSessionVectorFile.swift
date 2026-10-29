import Foundation

@testable import Heeler

/// The shared notification session v1 vectors from `plugin/test-vectors/`,
/// the single source of truth for how a registration entry's `session`
/// field is derived and delivered (#412). The plugin derives a hook's session
/// from `HERDR_SOCKET_PATH` and delivers entries by it; this app writes the
/// field from the Host's session. The JSON file is bundled into the test
/// target as a resource so both suites exercise the same cases.
struct NotificationSessionVectorFile: Decodable, Sendable {
    let names: [Name]
    let derivation: [Derivation]
    let delivery: [Delivery]

    /// One herdr session name and whether herdr and the app accept it.
    struct Name: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let valid: Bool
        var description: String { name.debugDescription }
    }

    /// A hook's `HERDR_SOCKET_PATH` (nil: unset) and the session it derives:
    /// "" for the default session, the name for a named one, nil for an
    /// unknown shape.
    struct Derivation: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let socketPath: String?
        let session: String?
        var description: String { name }
    }

    /// Registration entries (only their `session` field) and the indexes a
    /// hook in `ownSession` (nil: unknown) delivers to.
    struct Delivery: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let ownSession: String?
        let entries: [JSONValue]
        let delivered: [Int]
        var description: String { name }
    }

    static let shared: NotificationSessionVectorFile = {
        guard
            let url = Bundle(for: BundleLocator.self)
                .url(forResource: "notification-session-v1", withExtension: "json")
        else {
            fatalError("notification-session-v1.json is missing from the test bundle")
        }
        do {
            return try JSONDecoder().decode(
                NotificationSessionVectorFile.self, from: Data(contentsOf: url))
        } catch {
            fatalError("shared notification session vectors failed to load: \(error)")
        }
    }()

    private final class BundleLocator {}
}

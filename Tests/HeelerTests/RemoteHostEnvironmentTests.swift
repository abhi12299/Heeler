import Foundation
import Testing

@testable import Heeler

@Suite struct RemoteHostEnvironmentTests {
    @Test func noisyWindowsProbeUsesUserProfileAndConfig() throws {
        let output = Data("banner\r\n__HEELER_WINDOWS__={\"home\":\"C:\\\\Users\\\\Test User\",\"config\":\"D:\\\\Config\\\\herdr\"}\r\n".utf8)
        let environment = try #require(RemoteHostEnvironment.windows(from: output))
        #expect(environment.home == "C:\\Users\\Test User")
        #expect(try environment.socketPath(for: .namedSession("work")) == "D:\\Config\\herdr\\sessions\\work\\herdr.sock")
        #expect(try environment.socketPath(for: .defaultSession) == "D:\\Config\\herdr\\herdr.sock")
        #expect(try environment.socketPath(for: .absolutePath("E:\\Custom\\herdr.sock")) == "E:\\Custom\\herdr.sock")
    }

    @Test func invalidWindowsHomeOrEndpointIsRefused() {
        #expect(RemoteHostEnvironment.windows(from: Data("__HEELER_WINDOWS__={\"home\":\"relative\",\"config\":\"C:\\\\config\"}".utf8)) == nil)
        let environment = RemoteHostEnvironment.windows(home: "C:\\Users\\user", configDirectory: "C:\\Config\\herdr")
        #expect(throws: TransportError.self) { try environment.socketPath(for: .absolutePath("/tmp/herdr.sock")) }
        #expect(throws: TransportError.self) { try environment.socketPath(for: .namedSession("../work")) }
    }

    @Test func posixEndpointBehaviorIsPreserved() throws {
        let environment = RemoteHostEnvironment.posix(home: "/home/u")
        #expect(try environment.socketPath(for: .namedSession("work")) == "/home/u/.config/herdr/sessions/work/herdr.sock")
        #expect(try environment.socketPath(for: .absolutePath("/tmp/custom.sock")) == "/tmp/custom.sock")
        #expect(!environment.isWindows)
    }

    @Test(arguments: ["/tmp/it's-a.sock", "/tmp/herdr\\custom.sock"])
    func customPosixEndpointPreservesLiteralPathWithoutHomeResolution(path: String) throws {
        let environment = RemoteHostEnvironment.posix(home: "relative and invalid HOME")
        #expect(try environment.socketPath(for: .absolutePath(path)) == path)
    }

    @Test func encodedCommandPreservesUnicodeAndShellMetacharacters() throws {
        let script = "[Console]::WriteLine('测试 $HOME ` whoami & café')"
        #expect(try decode(PowerShellCommand.encoded(script)) == script)
        let command = PowerShellCommand.herdr(
            arguments: ["terminal", "session", "control", "opaque'$(whoami)"],
            socketPath: "C:\\Users\\Test User\\herdr.sock",
            location: .absolutePath("C:\\Users\\Test User\\herdr.sock"))
        let decoded = try decode(command)
        #expect(decoded.contains("$env:HERDR_SOCKET_PATH = 'C:\\Users\\Test User\\herdr.sock'"))
        #expect(decoded.contains("'opaque''$(whoami)'"))
        #expect(!command.contains("$(whoami)"))
    }

    @Test(arguments: [
        HerdrSocketLocation.defaultSession,
        .namedSession("work"),
        .absolutePath("C:/Custom/herdr.sock"),
    ], [
        ["remote-api-bridge"],
        ["terminal", "session", "control", "w1:p1"],
    ])
    func windowsAPIAndTerminalCommandsIsolateTheSelectedSession(
        location: HerdrSocketLocation, arguments: [String]
    ) throws {
        let environment = RemoteHostEnvironment.windows(
            home: "C:\\Users\\user", configDirectory: "C:\\Config\\herdr")
        let socketPath = try environment.socketPath(for: location)
        let script = try decode(PowerShellCommand.herdr(
            arguments: arguments, socketPath: socketPath, location: location, streaming: true))
        let invocation = try #require(script.range(of: "& herdr.exe "))
        let clientReset = try #require(script.range(of:
            "Remove-Item Env:HERDR_CLIENT_SOCKET_PATH -ErrorAction SilentlyContinue"))
        #expect(clientReset.upperBound < invocation.lowerBound)
        #expect(!script.contains("$env:HERDR_CLIENT_SOCKET_PATH ="))

        switch location {
        case .defaultSession, .namedSession:
            let apiReset = try #require(script.range(of:
                "Remove-Item Env:HERDR_SOCKET_PATH -ErrorAction SilentlyContinue"))
            #expect(apiReset.upperBound < invocation.lowerBound)
            #expect(!script.contains("$env:HERDR_SOCKET_PATH ="))
        case .absolutePath(let path):
            #expect(script.contains("$env:HERDR_SOCKET_PATH = \(PowerShellCommand.literal(path))\n"))
            #expect(!script.contains("Remove-Item Env:HERDR_SOCKET_PATH"))
        }

        switch location {
        case .namedSession(let name):
            #expect(script.contains("$env:HERDR_SESSION = \(PowerShellCommand.literal(name))\n"))
            #expect(!script.contains("Remove-Item Env:HERDR_SESSION"))
        case .defaultSession, .absolutePath:
            let sessionReset = try #require(script.range(of:
                "Remove-Item Env:HERDR_SESSION -ErrorAction SilentlyContinue"))
            #expect(sessionReset.upperBound < invocation.lowerBound)
            #expect(!script.contains("$env:HERDR_SESSION ="))
        }
    }

    @Test func platformFeatureFailuresDoNotReconnect() {
        let error = TransportError.hostFeatureUnavailable(feature: "Changes")
        #expect(!error.isRetryable)
        #expect(error.presentation.detail == "Changes")
    }

    private func decode(_ command: String) throws -> String {
        let encoded = try #require(command.split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(encoded)))
        return try #require(String(data: data, encoding: .utf16LittleEndian))
    }
}

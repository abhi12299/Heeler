import Foundation
import HeelerSSH
import Testing

@testable import Heeler

@Suite("Windows terminal controller")
struct WindowsTerminalChannelTests {
    @Test func binaryInputPreservesAllBytesAndDoesNotSubmit() async throws {
        let exec = ControllerExecProbe()
        let channel = WindowsTerminalChannel(channel: exec)
        let input = Data([0, 0x1B, 0xFF, 0x0A])
        try await channel.write(input, timeout: .seconds(1))
        let records = try records(await exec.writtenData())
        #expect(records.count == 1)
        #expect(records[0]["type"] as? String == "terminal.input")
        #expect(records[0]["bytes"] as? String == input.base64EncodedString())
        #expect(records[0]["text"] == nil)
    }

    @Test func coalescedWheelReportsBecomeSemanticScrollCommands() async throws {
        let exec = ControllerExecProbe()
        let channel = WindowsTerminalChannel(channel: exec)
        try await channel.write(
            Data("\u{1B}[<64;12;9M\u{1B}[<65;12;9M".utf8), timeout: .seconds(1))
        let records = try records(await exec.writtenData())
        #expect(records.count == 2)
        #expect(records[0]["type"] as? String == "terminal.scroll")
        #expect(records[0]["direction"] as? String == "up")
        #expect(records[1]["direction"] as? String == "down")
        #expect(records[0]["column"] as? Int == 11)
        #expect(records[0]["row"] as? Int == 8)
        #expect(records[0]["lines"] as? Int == 1)
    }

    @Test func clickReportsBecomeSemanticMouseCommands() async throws {
        let exec = ControllerExecProbe()
        let channel = WindowsTerminalChannel(channel: exec)
        try await channel.write(
            Data("\u{1B}[<0;7;4M\u{1B}[<0;7;4m".utf8), timeout: .seconds(1))
        let records = try records(await exec.writtenData())
        #expect(records.count == 2)
        #expect(records[0]["type"] as? String == "terminal.mouse")
        #expect(records[0]["action"] as? String == "down")
        #expect(records[1]["action"] as? String == "up")
    }

    @Test func textContainingMouseBytesRemainsOneBinaryInput() async throws {
        let input = Data("prefix\u{1B}[<64;12;9M".utf8)
        let records = try records(WindowsTerminalCommandCodec.input(input))
        #expect(records.count == 1)
        #expect(records[0]["bytes"] as? String == input.base64EncodedString())
    }

    @Test func resizeUsesControllerGeometryAndRejectsOutOfRangeSizes() async throws {
        let exec = ControllerExecProbe()
        let channel = WindowsTerminalChannel(channel: exec)
        try await channel.resize(columns: 81, rows: 25, timeout: .seconds(1))
        let records = try records(await exec.writtenData())
        #expect(records[0]["type"] as? String == "terminal.resize")
        #expect(records[0]["cols"] as? Int == 81)
        #expect(records[0]["rows"] as? Int == 25)
        await #expect(throws: TransportError.self) {
            try await channel.resize(columns: 0, rows: 25, timeout: .seconds(1))
        }
        await #expect(throws: TransportError.self) {
            try await channel.resize(columns: 81, rows: 65_536, timeout: .seconds(1))
        }
        #expect(await exec.writeCount == 1)
    }

    @Test func fragmentedFramesSurviveReadTimeoutAndBootstrapOnlyOnce() async throws {
        let first = try frame(sequence: 1, full: true, bytes: Data("first".utf8))
        let split = first.count / 2
        let exec = ControllerExecProbe(reads: [
            .bytes(Data(first.prefix(split))), .timeout,
            .bytes(try Data(first.dropFirst(split)) + frame(sequence: 2, full: false, bytes: Data("delta".utf8))),
        ])
        let channel = WindowsTerminalChannel(channel: exec)
        await #expect(throws: SSHError.timedOut) {
            _ = try await channel.read(maximumBytes: 16_384, timeout: .seconds(1))
        }
        let initial = try await channel.read(maximumBytes: 16_384, timeout: .seconds(1))
        #expect(initial == AttachBootstrapHandshake.marker + WindowsTerminalChannel.screenStart + Data("first".utf8))
        let delta = try await channel.read(maximumBytes: 16_384, timeout: .seconds(1))
        #expect(delta == Data("delta".utf8))
    }

    @Test func decodedOutputHonorsReadSizeWithoutLosingTheGateMarker() async throws {
        let exec = ControllerExecProbe(reads: [.bytes(try frame(sequence: 1, full: true, bytes: Data("rendered".utf8))), .eof])
        let channel = WindowsTerminalChannel(channel: exec)
        let expected = AttachBootstrapHandshake.marker + WindowsTerminalChannel.screenStart + Data("rendered".utf8)
        var received = Data()
        while received.count < expected.count {
            let chunk = try #require(await channel.read(maximumBytes: 3, timeout: .seconds(1)))
            #expect(chunk.count <= 3)
            received.append(chunk)
        }
        #expect(received == expected)
        var gate = AttachBootstrapGate()
        #expect(gate.admit(received) == WindowsTerminalChannel.screenStart + Data("rendered".utf8))
    }

    @Test func unknownMetadataIsIgnoredAndCleanDetachRestoresScreenModes() async throws {
        let exec = ControllerExecProbe(reads: [.bytes(
            try Data("{\"type\":\"terminal.metadata\",\"width\":\"future metadata\"}\n".utf8)
                + frame(sequence: 1, full: true, bytes: Data("a".utf8))
                + Data("{\"type\":\"terminal.closed\",\"reason\":\"detached\"}\n".utf8))])
        let channel = WindowsTerminalChannel(channel: exec)
        _ = try await channel.read(maximumBytes: 16_384, timeout: .seconds(1))
        #expect(try await channel.read(maximumBytes: 16_384, timeout: .seconds(1)) == WindowsTerminalChannel.screenEnd)
        #expect(try await channel.read(maximumBytes: 16_384, timeout: .seconds(1)) == nil)
        #expect(try await channel.exitStatus(timeout: .seconds(1)) == 0)
    }

    @Test func rejectedTargetAndTakeoverRemainFailuresDespiteZeroRemoteExit() async throws {
        for reason in ["terminal session control failed: terminal target w1:p1 not found", "terminal attach taken over"] {
            let exec = ControllerExecProbe(reads: [.bytes(
                try WindowsTerminalCommandCodec.record(["type": "terminal.closed", "reason": reason]))])
            let channel = WindowsTerminalChannel(channel: exec)
            await #expect(throws: TransportError.channelFailed(detail: "terminal controller: \(reason)")) {
                _ = try await channel.read(maximumBytes: 16_384, timeout: .seconds(1))
            }
            #expect(try await channel.exitStatus(timeout: .seconds(1)) == 1)
        }
    }

    @Test func malformedOversizedAndIncompleteRecordsAreRejected() async throws {
        let records = [
            Data("{\"type\":\"terminal.frame\",\"seq\":1,\"encoding\":\"ansi\",\"width\":80,\"height\":24,\"full\":true,\"bytes\":\"!invalid!\"}\n".utf8),
            Data("{\"type\":\"terminal.frame\"".utf8),
            Data(repeating: 0x41, count: 201),
            try frame(sequence: 1, full: false, bytes: Data("delta".utf8)),
        ]
        for record in records {
            let exec = ControllerExecProbe(reads: [.bytes(record), .eof])
            let channel = WindowsTerminalChannel(channel: exec, maximumRecordBytes: 200)
            await #expect(throws: TransportError.self) {
                _ = try await channel.read(maximumBytes: 16_384, timeout: .seconds(1))
            }
            #expect(try await channel.exitStatus(timeout: .seconds(1)) == 1)
        }
    }

    @Test func aMissingDeltaCannotSilentlyCorruptTheViewport() async throws {
        let exec = ControllerExecProbe(reads: [.bytes(
            try frame(sequence: 1, full: true, bytes: Data("a".utf8))
                + frame(sequence: 3, full: false, bytes: Data("b".utf8)))])
        let channel = WindowsTerminalChannel(channel: exec)
        _ = try await channel.read(maximumBytes: 16_384, timeout: .seconds(1))
        await #expect(throws: TransportError.self) {
            _ = try await channel.read(maximumBytes: 16_384, timeout: .seconds(1))
        }
    }

    @Test func logicalCloseDrainsRealSSHEOFBeforeReadingExitStatus() async throws {
        let exec = ControllerExecProbe(reads: [.bytes(
            try frame(sequence: 1, full: true, bytes: Data("a".utf8))
                + WindowsTerminalCommandCodec.record(["type": "terminal.closed", "reason": "detached"])), .eof])
        let channel = WindowsTerminalChannel(channel: exec)
        _ = try await channel.read(maximumBytes: 16_384, timeout: .seconds(1))
        _ = try await channel.read(maximumBytes: 16_384, timeout: .seconds(1))
        #expect(try await channel.read(maximumBytes: 16_384, timeout: .seconds(1)) == nil)
        #expect(await exec.readCount == 1)
        #expect(try await channel.exitStatus(timeout: .seconds(1)) == 0)
        #expect(await exec.readCount == 2)
    }

    @Test func exitStatusPreservesATimeoutWhileDrainingTheRemoteProcess() async throws {
        let exec = ControllerExecProbe(reads: [.bytes(
            try WindowsTerminalCommandCodec.record(["type": "terminal.closed", "reason": "terminal attach taken over"])),
            .timeout, .eof])
        let channel = WindowsTerminalChannel(channel: exec)
        await #expect(throws: TransportError.self) {
            _ = try await channel.read(maximumBytes: 16_384, timeout: .seconds(1))
        }
        await #expect(throws: SSHError.timedOut) {
            _ = try await channel.exitStatus(timeout: .seconds(1))
        }
        #expect(try await channel.exitStatus(timeout: .seconds(1)) == 1)
    }

    @Test func virtualViewportRoutesScrollingAndPasteThroughTheController() throws {
        var tracker = TerminalModeTracker()
        tracker.receive(WindowsTerminalChannel.screenStart)
        #expect(tracker.isAlternateScreen)
        #expect(tracker.tracksMouse)
        #expect(tracker.usesBracketedPaste)
        let wheel = try #require(tracker.remoteScrollSequence(
            towardOlderContent: true, columns: 80, rows: 24))
        let scroll = try records(WindowsTerminalCommandCodec.input(wheel))
        #expect(scroll[0]["type"] as? String == "terminal.scroll")
        let paste = Data("\u{1B}[200~first\nsecond\u{1B}[201~".utf8)
        let pasted = try records(WindowsTerminalCommandCodec.input(paste))
        #expect(pasted[0]["bytes"] as? String == paste.base64EncodedString())
        tracker.receive(WindowsTerminalChannel.screenEnd)
        #expect(!tracker.isAlternateScreen)
        #expect(!tracker.tracksMouse)
        #expect(!tracker.usesBracketedPaste)
    }

    @Test func closeReleasesOwnershipAndClosesOnlyOnce() async throws {
        let exec = ControllerExecProbe()
        let channel = WindowsTerminalChannel(channel: exec)
        try await channel.close(timeout: .seconds(1))
        try await channel.close(timeout: .seconds(1))
        let records = try records(await exec.writtenData())
        #expect(records.count == 1)
        #expect(records[0]["type"] as? String == "terminal.release")
        #expect(await exec.closeCount == 1)
    }

    private func frame(sequence: UInt64, full: Bool, bytes: Data) throws -> Data {
        try WindowsTerminalCommandCodec.record([
            "type": "terminal.frame", "seq": sequence, "encoding": "ansi",
            "width": 80, "height": 24, "full": full, "bytes": bytes.base64EncodedString(),
        ])
    }

    private func records(_ bytes: Data) throws -> [[String: Any]] {
        try bytes.split(separator: 0x0A).map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        }
    }
}

@Suite("Windows exec stream bootstrap")
struct BootstrappedExecChannelTests {
    @Test func markerAndLargeFirstFrameInOneReadRemainIntact() async throws {
        let payload = Data(repeating: 0x41, count: 10_000)
        let exec = ControllerExecProbe(reads: [.bytes(Data("profile chatter\n".utf8) + marker + payload)])
        let channel = BootstrappedExecChannel(channel: exec)
        #expect(try await channel.read(maximumBytes: 16_384, timeout: .seconds(1)) == payload)
    }

    @Test func bootstrapPayloadRespectsEveryReadSize() async throws {
        let exec = ControllerExecProbe(reads: [.bytes(marker + Data("abcdef".utf8)), .eof])
        let channel = BootstrappedExecChannel(channel: exec)
        #expect(try await channel.read(maximumBytes: 2, timeout: .seconds(1)) == Data("ab".utf8))
        #expect(try await channel.read(maximumBytes: 3, timeout: .seconds(1)) == Data("cde".utf8))
        #expect(try await channel.read(maximumBytes: 1, timeout: .seconds(1)) == Data("f".utf8))
        #expect(try await channel.read(maximumBytes: 2, timeout: .seconds(1)) == nil)
    }

    @Test func fragmentedMarkerSurvivesAReadTimeout() async throws {
        let split = marker.count / 2
        let payload = Data("中文 JSON payload\n".utf8)
        let exec = ControllerExecProbe(reads: [
            .bytes(Data(repeating: 0x41, count: 10_000) + Data(marker.prefix(split))),
            .timeout, .bytes(Data(marker.dropFirst(split)) + payload),
        ])
        let channel = BootstrappedExecChannel(channel: exec)
        await #expect(throws: SSHError.timedOut) {
            _ = try await channel.read(maximumBytes: 16_384, timeout: .seconds(1))
        }
        #expect(try await channel.read(maximumBytes: 16_384, timeout: .seconds(1)) == payload)
    }

    @Test func aMarkerWithoutPayloadKeepsReadinessAfterATimeout() async throws {
        let payload = Data("reply\n".utf8)
        let exec = ControllerExecProbe(reads: [.bytes(marker), .timeout, .bytes(payload)])
        let channel = BootstrappedExecChannel(channel: exec)
        await #expect(throws: SSHError.timedOut) {
            _ = try await channel.read(maximumBytes: 16_384, timeout: .seconds(1))
        }
        #expect(try await channel.read(maximumBytes: 16_384, timeout: .seconds(1)) == payload)
    }

    @Test func aMarkerAtTheDeadlineDoesNotStartAnExpiredRead() async throws {
        let exec = ControllerExecProbe(reads: [.delayedBytes(marker, .milliseconds(20)), .bytes(Data("reply".utf8))])
        let channel = BootstrappedExecChannel(channel: exec)
        await #expect(throws: SSHError.timedOut) {
            _ = try await channel.read(maximumBytes: 16_384, timeout: .milliseconds(1))
        }
        #expect(await exec.readCount == 1)
        #expect(try await channel.read(maximumBytes: 16_384, timeout: .seconds(1)) == Data("reply".utf8))
    }

    @Test func lineFeedMarkerWorksAndEarlyEOFIsAnError() async throws {
        let exec = ControllerExecProbe(reads: [.bytes(
            Data((PowerShellCommand.streamMarker + "\nreply").utf8))])
        let channel = BootstrappedExecChannel(channel: exec)
        #expect(try await channel.read(maximumBytes: 16_384, timeout: .seconds(1)) == Data("reply".utf8))
        let failed = BootstrappedExecChannel(channel: ControllerExecProbe(reads: [.bytes(Data("chatter".utf8)), .eof]))
        await #expect(throws: TransportError.self) {
            _ = try await failed.read(maximumBytes: 16_384, timeout: .seconds(1))
        }
    }

    private var marker: Data { Data((PowerShellCommand.streamMarker + "\r\n").utf8) }
}

private actor ControllerExecProbe: WindowsTerminalExecChannel {
    enum Read: Sendable {
        case bytes(Data)
        case delayedBytes(Data, Duration)
        case timeout
        case eof
    }

    private var reads: [Read]
    private var writes: [Data] = []
    private var reachedEOF = false
    private(set) var closeCount = 0
    private(set) var readCount = 0
    var writeCount: Int { writes.count }

    init(reads: [Read] = []) { self.reads = reads }

    func write(_ data: Data, timeout _: Duration) async throws { writes.append(data) }

    func read(maximumBytes _: Int, timeout _: Duration) async throws -> Data? {
        readCount += 1
        guard !reads.isEmpty else {
            reachedEOF = true
            return nil
        }
        switch reads.removeFirst() {
        case .bytes(let bytes): return bytes
        case .delayedBytes(let bytes, let duration):
            try await Task.sleep(for: duration)
            return bytes
        case .timeout: throw SSHError.timedOut
        case .eof:
            reachedEOF = true
            return nil
        }
    }

    func exitStatus(timeout _: Duration) async throws -> Int32 {
        guard reachedEOF else { throw SSHError.channelFailed }
        return 0
    }
    func close(timeout _: Duration) async throws { closeCount += 1 }

    func writtenData() -> Data {
        writes.reduce(into: Data()) { $0.append($1) }
    }
}

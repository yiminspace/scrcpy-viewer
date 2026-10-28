import XCTest
@testable import ViewerCore

final class ScrcpyProtocolTests: XCTestCase {
    func testPacketFlagsAreRemovedFromMicrosecondTimestamp() throws {
        let packet = try ScrcpyProtocol.packetHeader(Data([
            0x40, 0, 0, 0, 0, 0x12, 0x34, 0x56, 0, 0, 1, 0,
        ]))
        XCTAssertTrue(packet.isKeyFrame)
        XCTAssertFalse(packet.isConfiguration)
        XCTAssertEqual(packet.presentationTime, 0x123456)
        XCTAssertEqual(packet.length, 256)
    }

    func testConfigurationFlagAndUnsafePacketLengths() throws {
        let config = try ScrcpyProtocol.packetHeader(Data([0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 20]))
        XCTAssertTrue(config.isConfiguration)
        XCTAssertEqual(config.presentationTime, 0)
        XCTAssertThrowsError(try ScrcpyProtocol.packetHeader(Data(repeating: 0, count: 12)))
        XCTAssertThrowsError(try ScrcpyProtocol.packetHeader(Data([0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1])))
        XCTAssertThrowsError(try ScrcpyProtocol.packetHeader(Data(repeating: 0, count: 11)))
    }

    func testVideoHandshakeValidatesCodecAndDimensions() throws {
        let valid = Data([0x68, 0x32, 0x36, 0x34, 0, 0, 4, 0x38, 0, 0, 9, 0x60])
        XCTAssertEqual(try ScrcpyProtocol.videoHeader(valid), .init(width: 1080, height: 2400))
        var invalid = valid; invalid[3] = 0x35
        XCTAssertThrowsError(try ScrcpyProtocol.videoHeader(invalid))
        invalid = valid; invalid.replaceSubrange(4..<8, with: [0, 0, 0, 0])
        XCTAssertThrowsError(try ScrcpyProtocol.videoHeader(invalid))
    }

    func testDecodedPixelBudgetRejectsHugeFramesIncludingResolutionChanges() {
        XCTAssertTrue(ScrcpyProtocol.allowsFrame(width: 3840, height: 2160))
        XCTAssertTrue(ScrcpyProtocol.allowsFrame(width: 2160, height: 3840))
        for (width, height) in [(8192, 8192), (16384, 1), (0, 1), (1, 0), (1, -1), (Int.max, Int.max)] {
            XCTAssertFalse(ScrcpyProtocol.allowsFrame(width: width, height: height))
        }
        XCTAssertThrowsError(try ScrcpyProtocol.videoHeader(Data([
            0x68, 0x32, 0x36, 0x34, 0, 0, 0x20, 0, 0, 0, 0x20, 0,
        ])))
    }

    func testNALFloodIsRejectedBeforeAllocatingMillionsOfUnits() {
        let unit = Data([0, 0, 1, 0x65])
        var packet = Data()
        for _ in 0..<4097 { packet.append(unit) }
        XCTAssertThrowsError(try ScrcpyProtocol.nalUnits(packet))
    }

    func testAnnexBPreservesSeveralNALsWithMixedStartCodeLengths() throws {
        let input = Data([0, 0, 0, 1, 0x67, 0x64, 0, 0, 1, 0x68, 0x22,
                          0, 0, 0, 1, 0x65, 0, 0, 3, 1, 0x33])
        let units = try ScrcpyProtocol.nalUnits(input)
        XCTAssertEqual(units, [Data([0x67, 0x64]), Data([0x68, 0x22]), Data([0x65, 0, 0, 3, 1, 0x33])])
        XCTAssertEqual(ScrcpyProtocol.lengthPrefixed(units), Data([
            0, 0, 0, 2, 0x67, 0x64, 0, 0, 0, 2, 0x68, 0x22,
            0, 0, 0, 6, 0x65, 0, 0, 3, 1, 0x33,
        ]))
    }

    func testMalformedNALBoundariesAreRejected() {
        for bytes: [UInt8] in [[], [1, 2, 3], [0, 0, 1], [5, 0, 0, 1, 0x67], [0, 0, 1, 0, 0, 1, 0x67]] {
            XCTAssertThrowsError(try ScrcpyProtocol.nalUnits(Data(bytes)))
        }
    }
}

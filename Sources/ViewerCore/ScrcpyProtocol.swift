import Foundation

enum ScrcpyProtocolError: LocalizedError {
    case malformed(String)
    var errorDescription: String? {
        switch self { case .malformed(let message): return message }
    }
}

enum ScrcpyProtocol {
    static let maximumPacketSize = 16 * 1024 * 1024
    static let h264Codec: UInt32 = 0x68323634

    struct VideoHeader: Equatable {
        let width: Int
        let height: Int
    }

    struct PacketHeader: Equatable {
        let presentationTime: UInt64
        let isConfiguration: Bool
        let isKeyFrame: Bool
        let length: Int
    }

    static func videoHeader(_ data: Data) throws -> VideoHeader {
        guard data.count == 12 else { throw ScrcpyProtocolError.malformed("视频握手长度不正确") }
        let bytes = Array(data)
        guard uint32(bytes, 0) == h264Codec else {
            throw ScrcpyProtocolError.malformed("设备未返回 H.264 视频")
        }
        let width = Int(uint32(bytes, 4)), height = Int(uint32(bytes, 8))
        guard (1...16384).contains(width), (1...16384).contains(height) else {
            throw ScrcpyProtocolError.malformed("设备返回了无效的视频尺寸")
        }
        return VideoHeader(width: width, height: height)
    }

    static func packetHeader(_ data: Data) throws -> PacketHeader {
        guard data.count == 12 else { throw ScrcpyProtocolError.malformed("视频包头长度不正确") }
        let bytes = Array(data)
        let flags = bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let length = Int(uint32(bytes, 8))
        guard length > 0, length <= maximumPacketSize else {
            throw ScrcpyProtocolError.malformed("视频包大小超出允许范围")
        }
        return PacketHeader(presentationTime: flags & ((UInt64(1) << 62) - 1),
                            isConfiguration: flags & (UInt64(1) << 63) != 0,
                            isKeyFrame: flags & (UInt64(1) << 62) != 0, length: length)
    }

    /// MediaCodec produces Annex-B H.264; a packet may contain several NAL units.
    static func nalUnits(_ data: Data) throws -> [Data] {
        let bytes = Array(data)
        var boundaries: [(start: Int, payload: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    boundaries.append((index, index + 3)); index += 3; continue
                }
                if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    boundaries.append((index, index + 4)); index += 4; continue
                }
            }
            index += 1
        }
        guard let first = boundaries.first,
              bytes[..<first.start].allSatisfy({ $0 == 0 }) else {
            throw ScrcpyProtocolError.malformed("H.264 视频缺少 Annex-B 起始码")
        }
        var result: [Data] = []
        for (offset, boundary) in boundaries.enumerated() {
            let end = offset + 1 < boundaries.count ? boundaries[offset + 1].start : bytes.count
            guard boundary.payload < end else {
                throw ScrcpyProtocolError.malformed("H.264 视频包含空 NAL")
            }
            result.append(Data(bytes[boundary.payload..<end]))
        }
        return result
    }

    static func lengthPrefixed(_ units: [Data]) -> Data {
        var result = Data()
        for unit in units {
            let size = UInt32(unit.count)
            result.append(contentsOf: [UInt8((size >> 24) & 255), UInt8((size >> 16) & 255),
                                      UInt8((size >> 8) & 255), UInt8(size & 255)])
            result.append(unit)
        }
        return result
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

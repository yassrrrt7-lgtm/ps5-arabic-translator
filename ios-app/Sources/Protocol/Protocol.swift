import Foundation

// MARK: - Protocol Constants

public enum PS5TProtocol {
    /// "PS5T" in little-endian wire order (0x50, 0x53, 0x35, 0x54)
    public static let magic: UInt32 = 0x54355350
    public static let version: UInt8 = 1

    public static let discoveryPort: UInt16 = 55000
    public static let dataPort: UInt16 = 55001
    public static let lanPS5IP: String = "10.0.0.1"
    public static let lanIPhoneIP: String = "10.0.0.2"

    public static let maxUDPPacket: Int = 1400
    public static let maxChunkData: Int = 1344
    public static let maxROIBytes: Int = 20480
    public static let maxChunks: Int = 16
    public static let titleIDLength: Int = 16
    public static let maxUTF8Bytes: Int = 1024

    public static let headerSize: Int = 8
    public static let discoverSize: Int = 28
    public static let discoverAckSize: Int = 16
    public static let roiHeaderSize: Int = 40
    public static let translationHeaderSize: Int = 20
    public static let heartbeatSize: Int = 16
}

// MARK: - Enums & OptionSets

public enum PS5TPacketType: UInt8, Sendable {
    case discover          = 0x01
    case discoverAck       = 0x02
    case roiFrame          = 0x03
    case translationStream = 0x04
    case heartbeat         = 0x05
    case heartbeatAck      = 0x06
}

public enum PS5TPixelFormat: UInt8, Sendable {
    case gray8    = 0x01
    case gray8RLE = 0x02
    case rgb565   = 0x03
}

public enum PS5TTransportMode: UInt8, Sendable {
    case unknown = 0x00
    case lan     = 0x01
    case wifi    = 0x02
}

public struct PS5TROIFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let forceRefresh = PS5TROIFlags(rawValue: 1 << 0)
}

public struct PS5TTranslationFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let final    = PS5TTranslationFlags(rawValue: 1 << 0)
    public static let cacheHit = PS5TTranslationFlags(rawValue: 1 << 1)
    public static let clear    = PS5TTranslationFlags(rawValue: 1 << 2)
}

public struct PS5TServerStatusFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let modelReady  = PS5TServerStatusFlags(rawValue: 1 << 0)
    public static let thermalWarn = PS5TServerStatusFlags(rawValue: 1 << 1)
}

// MARK: - Errors

public enum PS5TProtocolError: Error, Sendable {
    case packetTooShort
    case invalidMagic(UInt32)
    case unsupportedVersion(UInt8)
    case unknownPacketType(UInt8)
    case payloadLengthMismatch(expected: Int, actual: Int)
    case invalidChunkMetadata
    case utf8PayloadTooLarge(Int)
}

// MARK: - Packet Structs

public struct PS5THeader: Sendable {
    public let magic: UInt32
    public let version: UInt8
    public let type: PS5TPacketType
    public let payloadLen: UInt16

    public init(type: PS5TPacketType, payloadLen: UInt16) {
        self.magic = PS5TProtocol.magic
        self.version = PS5TProtocol.version
        self.type = type
        self.payloadLen = payloadLen
    }

    public static func decode(from data: Data) throws -> PS5THeader {
        guard data.count >= PS5TProtocol.headerSize else {
            throw PS5TProtocolError.packetTooShort
        }
        let magic = data.readUInt32LE(at: 0)
        guard magic == PS5TProtocol.magic else {
            throw PS5TProtocolError.invalidMagic(magic)
        }
        let version = data[data.startIndex + 4]
        guard version == PS5TProtocol.version else {
            throw PS5TProtocolError.unsupportedVersion(version)
        }
        let rawType = data[data.startIndex + 5]
        guard let type = PS5TPacketType(rawValue: rawType) else {
            throw PS5TProtocolError.unknownPacketType(rawType)
        }
        let payloadLen = data.readUInt16LE(at: 6)
        guard data.count >= PS5TProtocol.headerSize + Int(payloadLen) else {
            throw PS5TProtocolError.payloadLengthMismatch(
                expected: PS5TProtocol.headerSize + Int(payloadLen),
                actual: data.count
            )
        }
        return PS5THeader(type: type, payloadLen: payloadLen)
    }

    public func append(to buffer: inout Data) {
        buffer.appendUInt32LE(magic)
        buffer.append(version)
        buffer.append(type.rawValue)
        buffer.appendUInt16LE(payloadLen)
    }
}

public struct DiscoverPacket: Sendable {
    public let clientNonce: UInt32
    public let titleID: String

    public static func decode(from data: Data) throws -> DiscoverPacket {
        guard data.count >= PS5TProtocol.discoverSize else {
            throw PS5TProtocolError.packetTooShort
        }
        let nonce = data.readUInt32LE(at: 8)
        let titleID = data.readFixedASCII(at: 12, length: PS5TProtocol.titleIDLength)
        return DiscoverPacket(clientNonce: nonce, titleID: titleID)
    }
}

public struct DiscoverAckPacket: Sendable {
    public let clientNonce: UInt32
    public let dataPort: UInt16
    public let transportHint: PS5TTransportMode
    public let serverReady: Bool

    public init(
        clientNonce: UInt32,
        dataPort: UInt16 = PS5TProtocol.dataPort,
        transportHint: PS5TTransportMode,
        serverReady: Bool
    ) {
        self.clientNonce = clientNonce
        self.dataPort = dataPort
        self.transportHint = transportHint
        self.serverReady = serverReady
    }

    public func encode() -> Data {
        var data = Data(capacity: PS5TProtocol.discoverAckSize)
        PS5THeader(type: .discoverAck, payloadLen: 8).append(to: &data)
        data.appendUInt32LE(clientNonce)
        data.appendUInt16LE(dataPort)
        data.append(transportHint.rawValue)
        data.append(serverReady ? 1 : 0)
        return data
    }
}

public struct ROIFrameChunkPacket: Sendable {
    public let frameID: UInt32
    public let titleID: String
    public let width: UInt16
    public let height: UInt16
    public let pixelFormat: PS5TPixelFormat
    public let chunkIndex: UInt8
    public let totalChunks: UInt8
    public let flags: PS5TROIFlags
    public let payload: Data

    public static func decode(from data: Data) throws -> ROIFrameChunkPacket {
        guard data.count >= PS5TProtocol.roiHeaderSize else {
            throw PS5TProtocolError.packetTooShort
        }
        let frameID = data.readUInt32LE(at: 8)
        let titleID = data.readFixedASCII(at: 12, length: PS5TProtocol.titleIDLength)
        let width = data.readUInt16LE(at: 28)
        let height = data.readUInt16LE(at: 30)
        let rawFmt = data[data.startIndex + 32]
        guard let pixelFormat = PS5TPixelFormat(rawValue: rawFmt) else {
            throw PS5TProtocolError.invalidChunkMetadata
        }
        let chunkIndex = data[data.startIndex + 33]
        let totalChunks = data[data.startIndex + 34]
        let flags = PS5TROIFlags(rawValue: data[data.startIndex + 35])
        let chunkBytes = Int(data.readUInt16LE(at: 36))

        guard totalChunks >= 1,
              Int(totalChunks) <= PS5TProtocol.maxChunks,
              chunkIndex < totalChunks,
              chunkBytes <= PS5TProtocol.maxChunkData,
              data.count >= PS5TProtocol.roiHeaderSize + chunkBytes else {
            throw PS5TProtocolError.invalidChunkMetadata
        }

        let start = data.startIndex + PS5TProtocol.roiHeaderSize
        let payload = data.subdata(in: start..<(start + chunkBytes))

        return ROIFrameChunkPacket(
            frameID: frameID,
            titleID: titleID,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            chunkIndex: chunkIndex,
            totalChunks: totalChunks,
            flags: flags,
            payload: payload
        )
    }
}

public struct TranslationStreamPacket: Sendable {
    public let frameID: UInt32
    public let seqNum: UInt16
    public let flags: PS5TTranslationFlags
    public let latencyMs: UInt16
    public let shapedUTF8Text: String

    public init(
        frameID: UInt32,
        seqNum: UInt16,
        flags: PS5TTranslationFlags,
        latencyMs: UInt16,
        shapedUTF8Text: String
    ) {
        self.frameID = frameID
        self.seqNum = seqNum
        self.flags = flags
        self.latencyMs = latencyMs
        self.shapedUTF8Text = shapedUTF8Text
    }

    public func encode() throws -> Data {
        var utf8Bytes = Data(shapedUTF8Text.utf8)
        if utf8Bytes.count > PS5TProtocol.maxUTF8Bytes {
            utf8Bytes = utf8Bytes.prefix(PS5TProtocol.maxUTF8Bytes)
            while let last = utf8Bytes.last, (last & 0xC0) == 0x80 {
                utf8Bytes.removeLast()
            }
            if let last = utf8Bytes.last, (last & 0x80) != 0 {
                utf8Bytes.removeLast()
            }
        }

        let utf8Len = UInt16(utf8Bytes.count)
        let payloadLen = UInt16(12 + utf8Bytes.count)
        var data = Data(capacity: PS5TProtocol.translationHeaderSize + utf8Bytes.count)
        PS5THeader(type: .translationStream, payloadLen: payloadLen).append(to: &data)
        data.appendUInt32LE(frameID)
        data.appendUInt16LE(seqNum)
        data.appendUInt16LE(utf8Len)
        data.append(flags.rawValue)
        data.append(0) // reserved
        data.appendUInt16LE(latencyMs)
        data.append(utf8Bytes)
        return data
    }
}

public struct HeartbeatPacket: Sendable {
    public let timestampMs: UInt32
    public let transportMode: PS5TTransportMode
    public let statusFlags: PS5TServerStatusFlags

    public init(
        timestampMs: UInt32,
        transportMode: PS5TTransportMode,
        statusFlags: PS5TServerStatusFlags = []
    ) {
        self.timestampMs = timestampMs
        self.transportMode = transportMode
        self.statusFlags = statusFlags
    }

    public static func decode(from data: Data) throws -> HeartbeatPacket {
        guard data.count >= PS5TProtocol.heartbeatSize else {
            throw PS5TProtocolError.packetTooShort
        }
        let ts = data.readUInt32LE(at: 8)
        let mode = PS5TTransportMode(rawValue: data[data.startIndex + 12]) ?? .unknown
        let status = PS5TServerStatusFlags(rawValue: data[data.startIndex + 13])
        return HeartbeatPacket(timestampMs: ts, transportMode: mode, statusFlags: status)
    }

    public func encode(asAck: Bool) -> Data {
        var data = Data(capacity: PS5TProtocol.heartbeatSize)
        PS5THeader(type: asAck ? .heartbeatAck : .heartbeat, payloadLen: 8).append(to: &data)
        data.appendUInt32LE(timestampMs)
        data.append(transportMode.rawValue)
        data.append(statusFlags.rawValue)
        data.appendUInt16LE(0) // reserved
        return data
    }
}

// MARK: - Unified Incoming Packet Parser

public enum IncomingPS5Packet: Sendable {
    case discover(DiscoverPacket)
    case roiFrameChunk(ROIFrameChunkPacket)
    case heartbeat(HeartbeatPacket)

    public static func parse(_ data: Data) throws -> IncomingPS5Packet {
        let header = try PS5THeader.decode(from: data)
        switch header.type {
        case .discover:
            return .discover(try DiscoverPacket.decode(from: data))
        case .roiFrame:
            return .roiFrameChunk(try ROIFrameChunkPacket.decode(from: data))
        case .heartbeat:
            return .heartbeat(try HeartbeatPacket.decode(from: data))
        default:
            throw PS5TProtocolError.unknownPacketType(header.type.rawValue)
        }
    }
}

// MARK: - Safe Alignment-Independent Little-Endian Data Helpers

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | (UInt16(self[i + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i])
            | (UInt32(self[i + 1]) << 8)
            | (UInt32(self[i + 2]) << 16)
            | (UInt32(self[i + 3]) << 24)
    }

    func readFixedASCII(at offset: Int, length: Int) -> String {
        let start = startIndex + offset
        let slice = self[start..<(start + length)]
        let trimmed = slice.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

import Foundation
import Combine
import Darwin
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Completed Reassembled ROI Frame

public struct AssembledROIFrame: Sendable {
    public let frameID: UInt32
    public let titleID: String
    public let width: Int
    public let height: Int
    public let pixelFormat: PS5TPixelFormat
    public let flags: PS5TROIFlags
    public let pixelData: Data
    public let senderIP: String
    public let senderPort: UInt16
    public let transport: PS5TTransportMode
    public let arrivalTime: CFAbsoluteTime
}

public struct LocalNetworkInterface: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let ip: String
    public let isEthernet: Bool
}

// MARK: - Low-Latency Dual-Mode BSD UDP Server (Ethernet LAN + Wi-Fi Simultaneously)

public final class DualNetworkServer: @unchecked Sendable {

    public var onFrameAssembled: ((AssembledROIFrame) -> Void)?
    public var onHeartbeatReceived: ((_ senderIP: String, _ transport: PS5TTransportMode, _ timestampMs: UInt32) -> Void)?
    public var statusProvider: (() -> PS5TServerStatusFlags)?

    private let ioQueue = DispatchQueue(label: "com.ps5translator.udp.io", qos: .userInteractive)
    private var dataSocketFD: Int32 = -1
    private var discoverySocketFD: Int32 = -1
    private var dataReadSource: DispatchSourceRead?
    private var discoveryReadSource: DispatchSourceRead?

    // Frame reassembly state (protected exclusively by ioQueue)
    private struct PendingFrame {
        let frameID: UInt32
        let titleID: String
        let width: Int
        let height: Int
        let pixelFormat: PS5TPixelFormat
        let totalChunks: Int
        let flags: PS5TROIFlags
        let senderIP: String
        let senderPort: UInt16
        let transport: PS5TTransportMode
        let firstArrival: CFAbsoluteTime
        var chunks: [Data?]
        var receivedCount: Int
    }

    private var highestFrameID: UInt32 = 0
    private var pendingFrame: PendingFrame?
    private var lastPeerAddress: sockaddr_in?

    public init() {}

    deinit {
        stop()
    }

    public func start() throws {
        stop()

        let dataFD = try createUDPSocket(port: PS5TProtocol.dataPort, enableBroadcast: false)
        let discFD = try createUDPSocket(port: PS5TProtocol.discoveryPort, enableBroadcast: true)

        self.dataSocketFD = dataFD
        self.discoverySocketFD = discFD

        self.dataReadSource = attachReadSource(fd: dataFD) { [weak self] in
            self?.drainSocket(fd: dataFD, isDiscovery: false)
        }
        self.discoveryReadSource = attachReadSource(fd: discFD) { [weak self] in
            self?.drainSocket(fd: discFD, isDiscovery: true)
        }
    }

    public func stop() {
        ioQueue.sync {
            dataReadSource?.cancel()
            discoveryReadSource?.cancel()
            dataReadSource = nil
            discoveryReadSource = nil

            if dataSocketFD >= 0 { close(dataSocketFD); dataSocketFD = -1 }
            if discoverySocketFD >= 0 { close(discoverySocketFD); discoverySocketFD = -1 }
            pendingFrame = nil
        }
    }

    /// Sends a pre-shaped UTF-8 translation update immediately back to the PS5.
    public func sendTranslation(_ packet: TranslationStreamPacket, toIP ip: String, port: UInt16) {
        guard let encoded = try? packet.encode() else { return }
        ioQueue.async { [weak self] in
            guard let self, self.dataSocketFD >= 0 else { return }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, ip, &addr.sin_addr)
            self.sendDatagram(encoded, fd: self.dataSocketFD, to: addr)
        }
    }

    // MARK: - Socket Setup & Event Handling

    private func createUDPSocket(port: UInt16, enableBroadcast: Bool) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        if enableBroadcast {
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        }

        // Large receive buffer prevents packet drops during bursty 16-chunk ROI uploads
        var rcvBuf: Int32 = 262_144
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY) // 0.0.0.0 -> listens on LAN + Wi-Fi simultaneously

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }

        return fd
    }

    private func attachReadSource(fd: Int32, handler: @escaping () -> Void) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }

    private func drainSocket(fd: Int32, isDiscovery: Bool) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            var senderAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let bytesRead = withUnsafeMutablePointer(to: &senderAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(fd, &buffer, buffer.count, 0, sockPtr, &addrLen)
                }
            }

            if bytesRead <= 0 { break }

            let data = Data(bytes: buffer, count: bytesRead)
            let ipStr = Self.ipString(from: senderAddr.sin_addr)
            let port = UInt16(bigEndian: senderAddr.sin_port)
            let transport: PS5TTransportMode = ipStr.hasPrefix("10.0.0.") ? .lan : .wifi

            guard let parsed = try? IncomingPS5Packet.parse(data) else { continue }

            switch parsed {
            case .discover(let disc):
                let flags = statusProvider?() ?? []
                let ack = DiscoverAckPacket(
                    clientNonce: disc.clientNonce,
                    dataPort: PS5TProtocol.dataPort,
                    transportHint: transport,
                    serverReady: flags.contains(.modelReady)
                )
                sendDatagram(ack.encode(), fd: fd, to: senderAddr)

            case .heartbeat(let hb):
                lastPeerAddress = senderAddr
                let flags = statusProvider?() ?? []
                let reply = HeartbeatPacket(
                    timestampMs: hb.timestampMs,
                    transportMode: transport,
                    statusFlags: flags
                )
                sendDatagram(reply.encode(asAck: true), fd: fd, to: senderAddr)
                onHeartbeatReceived?(ipStr, transport, hb.timestampMs)

            case .roiFrameChunk(let chunk):
                guard !isDiscovery else { continue }
                lastPeerAddress = senderAddr
                handleROIChunk(chunk, senderIP: ipStr, senderPort: port, transport: transport)
            }
        }
    }

    private func handleROIChunk(
        _ chunk: ROIFrameChunkPacket,
        senderIP: String,
        senderPort: UInt16,
        transport: PS5TTransportMode
    ) {
        // Drop stale frames immediately if a newer frame_id has already arrived
        if chunk.frameID < highestFrameID {
            return
        }

        if chunk.frameID > highestFrameID || pendingFrame?.frameID != chunk.frameID {
            highestFrameID = chunk.frameID
            pendingFrame = PendingFrame(
                frameID: chunk.frameID,
                titleID: chunk.titleID,
                width: Int(chunk.width),
                height: Int(chunk.height),
                pixelFormat: chunk.pixelFormat,
                totalChunks: Int(chunk.totalChunks),
                flags: chunk.flags,
                senderIP: senderIP,
                senderPort: senderPort,
                transport: transport,
                firstArrival: CFAbsoluteTimeGetCurrent(),
                chunks: Array(repeating: nil, count: Int(chunk.totalChunks)),
                receivedCount: 0
            )
        }

        guard var current = pendingFrame else { return }
        let idx = Int(chunk.chunkIndex)
        guard idx < current.chunks.count else { return }

        if current.chunks[idx] == nil {
            current.chunks[idx] = chunk.payload
            current.receivedCount += 1
        }

        if current.receivedCount == current.totalChunks {
            var fullData = Data()
            fullData.reserveCapacity(current.totalChunks * PS5TProtocol.maxChunkData)
            for part in current.chunks {
                if let part { fullData.append(part) }
            }

            let assembled = AssembledROIFrame(
                frameID: current.frameID,
                titleID: current.titleID,
                width: current.width,
                height: current.height,
                pixelFormat: current.pixelFormat,
                flags: current.flags,
                pixelData: fullData,
                senderIP: current.senderIP,
                senderPort: current.senderPort,
                transport: current.transport,
                arrivalTime: current.firstArrival
            )
            pendingFrame = nil
            onFrameAssembled?(assembled)
        } else {
            pendingFrame = current
        }
    }

    private func sendDatagram(_ data: Data, fd: Int32, to address: sockaddr_in) {
        var addr = address
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    _ = sendto(fd, base, data.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private static func ipString(from addr: in_addr) -> String {
        var copy = addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &copy, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    /// Lists active IPv4 interfaces on the iPhone (Ethernet adapter `10.0.0.2` + Wi-Fi/Hotspot).
    public static func currentLocalInterfaces() -> [LocalNetworkInterface] {
        var results: [LocalNetworkInterface] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return results }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let ifa = current.pointee
            let flags = Int32(ifa.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0 && (flags & IFF_LOOPBACK) == 0

            if isUp, let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostBuf)
                        let isEth = ip.hasPrefix("10.0.0.") || (name != "en0" && name.hasPrefix("en"))
                        results.append(LocalNetworkInterface(id: "\(name)-\(ip)", name: name, ip: ip, isEthernet: isEth))
                    }
                }
            }
            cursor = ifa.ifa_next
        }
        return results
    }
}

// MARK: - Main Translation Pipeline Coordinator (Observed by SwiftUI Dashboard)

@MainActor
public final class TranslationEngine: ObservableObject {

    public static let shared = TranslationEngine()

    @Published public var isServerRunning: Bool = false
    @Published public var isModelLoaded: Bool = false
    @Published public var isLoadingModel: Bool = false
    @Published public var loadedModelName: String = "لا يوجد نموذج محمّل"
    @Published public var qualityMode: TranslationQualityMode = .cinematicPro

    @Published public var connectionMode: PS5TTransportMode = .unknown
    @Published public var ps5IP: String = "بانتظار اتصال السوني..."
    @Published public var localInterfaces: [LocalNetworkInterface] = []
    @Published public var activeTitleID: String = "GLOBAL"

    @Published public var lastOCRText: String = ""
    @Published public var lastArabicText: String = ""
    @Published public var lastOCRMs: Double = 0
    @Published public var lastTTFTMs: Double = 0
    @Published public var lastTotalMs: Double = 0
    @Published public var lastWasCacheHit: Bool = false
    @Published public var cachedEntriesCount: Int = 0
    @Published public var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published public var statusMessage: String = "جاهز للتشغيل"

    public let cache = TranslationCache()
    public let ocr = FastOCREngine()
    public let translator = CinematicTranslator()
    private let server = DualNetworkServer()

    private var activeTask: Task<Void, Never>?
    private var thermalObserver: NSObjectProtocol?
    private var lastHeartbeatAt: Date = .distantPast
    private var modelReadyFlag: Bool = false

    public var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        wireServerCallbacks()
        observeThermalState()
        refreshNetworkInterfaces()
        Task { await refreshCacheCount() }
    }

    private func wireServerCallbacks() {
        server.statusProvider = { [weak self] in
            var flags: PS5TServerStatusFlags = []
            if self?.modelReadyFlag == true {
                flags.insert(.modelReady)
            }
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .serious || thermal == .critical {
                flags.insert(.thermalWarn)
            }
            return flags
        }

        server.onHeartbeatReceived = { [weak self] ip, transport, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ps5IP = ip
                self.connectionMode = transport
                self.lastHeartbeatAt = Date()
            }
        }

        server.onFrameAssembled = { [weak self] frame in
            Task { @MainActor [weak self] in
                self?.processIncomingFrame(frame)
            }
        }
    }

    private func observeThermalState() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.thermalState = ProcessInfo.processInfo.thermalState
            }
        }
    }

    public func refreshNetworkInterfaces() {
        localInterfaces = DualNetworkServer.currentLocalInterfaces()
    }

    public func refreshCacheCount() async {
        cachedEntriesCount = await cache.totalCachedEntries()
    }

    public func startServer() {
        do {
            try server.start()
            isServerRunning = true
            statusMessage = "السيرفر يعمل على السلك (10.0.0.2) والواي فاي معاً"
            refreshNetworkInterfaces()
        } catch {
            isServerRunning = false
            statusMessage = "تعذر تشغيل السيرفر: \(error.localizedDescription)"
        }
    }

    public func stopServer() {
        activeTask?.cancel()
        server.stop()
        isServerRunning = false
        connectionMode = .unknown
        statusMessage = "تم إيقاف السيرفر"
    }

    public func loadModelFile(at url: URL) async {
        isLoadingModel = true
        statusMessage = "جاري تحميل النموذج على شريحة A18 Metal..."
        do {
            try await translator.loadModel(at: url)
            isModelLoaded = true
            modelReadyFlag = true
            loadedModelName = url.lastPathComponent
            statusMessage = "النموذج جاهز للترجمة الأوفلاين"
        } catch {
            isModelLoaded = false
            modelReadyFlag = false
            statusMessage = error.localizedDescription
        }
        isLoadingModel = false
    }

    public func autoLoadPreferredModelIfPresent() async {
        let preferred = modelsDirectory.appendingPathComponent(qualityMode.recommendedFileName)
        if FileManager.default.fileExists(atPath: preferred.path) {
            await loadModelFile(at: preferred)
            return
        }
        let files = listInstalledModelURLs()
        if let first = files.first {
            await loadModelFile(at: first)
        }
    }

    public func listInstalledModelURLs() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "gguf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Core Low-Latency Frame Pipeline

    private func processIncomingFrame(_ frame: AssembledROIFrame) {
        ps5IP = frame.senderIP
        connectionMode = frame.transport
        if !frame.titleID.isEmpty {
            activeTitleID = frame.titleID
        }

        // Cancel any previous in-flight generation immediately so latest subtitle wins
        activeTask?.cancel()
        let currentTitle = frame.titleID.isEmpty ? "GLOBAL" : frame.titleID
        let forceRefresh = frame.flags.contains(.forceRefresh)

        activeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.translator.cancelInFlight()

            do {
                // 1. Apple Vision OCR (<25ms)
                let ocrResult = try await self.ocr.recognize(
                    rawPixels: frame.pixelData,
                    width: frame.width,
                    height: frame.height,
                    pixelFormat: frame.pixelFormat,
                    titleID: currentTitle,
                    forceRefresh: forceRefresh
                )

                if Task.isCancelled || ocrResult.isDuplicate { return }

                // Empty ROI -> clear PS5 overlay immediately
                if ocrResult.isEmpty {
                    let clearPkt = TranslationStreamPacket(
                        frameID: frame.frameID,
                        seqNum: 0,
                        flags: [.final, .clear],
                        latencyMs: UInt16(min(65535, Int(ocrResult.latencyMs))),
                        shapedUTF8Text: ""
                    )
                    self.server.sendTranslation(clearPkt, toIP: frame.senderIP, port: frame.senderPort)
                    await MainActor.run {
                        self.lastOCRText = ""
                        self.lastArabicText = ""
                        self.lastOCRMs = ocrResult.latencyMs
                    }
                    return
                }

                // 2. Instant SQLite Cache Lookup (<3ms)
                if !forceRefresh, let cachedArabic = await self.cache.lookup(titleID: currentTitle, englishText: ocrResult.text) {
                    let shaped = ArabicTextShaper.shapeAndReorder(cachedArabic)
                    let totalMs = (CFAbsoluteTimeGetCurrent() - frame.arrivalTime) * 1000.0
                    let pkt = TranslationStreamPacket(
                        frameID: frame.frameID,
                        seqNum: 1,
                        flags: [.final, .cacheHit],
                        latencyMs: UInt16(min(65535, Int(totalMs))),
                        shapedUTF8Text: shaped
                    )
                    self.server.sendTranslation(pkt, toIP: frame.senderIP, port: frame.senderPort)
                    await MainActor.run {
                        self.lastOCRText = ocrResult.text
                        self.lastArabicText = cachedArabic
                        self.lastOCRMs = ocrResult.latencyMs
                        self.lastTTFTMs = totalMs
                        self.lastTotalMs = totalMs
                        self.lastWasCacheHit = true
                    }
                    return
                }

                // 3. Offline Metal LLM Streaming Translation
                let glossary = await self.cache.loadGlossary(for: currentTitle)
                var seq: UInt16 = 0

                let output = try await self.translator.translateStreaming(
                    englishText: ocrResult.text,
                    titleID: currentTitle,
                    glossary: glossary
                ) { [weak self] partialArabic, _ in
                    guard let self else { return }
                    seq &+= 1
                    let shaped = ArabicTextShaper.shapeAndReorder(partialArabic)
                    let elapsed = (CFAbsoluteTimeGetCurrent() - frame.arrivalTime) * 1000.0
                    let streamPkt = TranslationStreamPacket(
                        frameID: frame.frameID,
                        seqNum: seq,
                        flags: [],
                        latencyMs: UInt16(min(65535, Int(elapsed))),
                        shapedUTF8Text: shaped
                    )
                    self.server.sendTranslation(streamPkt, toIP: frame.senderIP, port: frame.senderPort)
                }

                if Task.isCancelled { return }

                // 4. Send final complete shaped subtitle + save to SQLite cache
                seq &+= 1
                let finalShaped = ArabicTextShaper.shapeAndReorder(output.arabicText)
                let totalMs = (CFAbsoluteTimeGetCurrent() - frame.arrivalTime) * 1000.0
                let finalPkt = TranslationStreamPacket(
                    frameID: frame.frameID,
                    seqNum: seq,
                    flags: [.final],
                    latencyMs: UInt16(min(65535, Int(totalMs))),
                    shapedUTF8Text: finalShaped
                )
                self.server.sendTranslation(finalPkt, toIP: frame.senderIP, port: frame.senderPort)
                await self.cache.store(titleID: currentTitle, englishText: ocrResult.text, arabicText: output.arabicText)

                let newCount = await self.cache.totalCachedEntries()
                await MainActor.run {
                    self.lastOCRText = ocrResult.text
                    self.lastArabicText = output.arabicText
                    self.lastOCRMs = ocrResult.latencyMs
                    self.lastTTFTMs = output.ttftMs
                    self.lastTotalMs = totalMs
                    self.lastWasCacheHit = false
                    self.cachedEntriesCount = newCount
                }
            } catch TranslatorError.cancelled {
                return
            } catch {
                await MainActor.run {
                    self.statusMessage = "تنبيه المحرك: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - One-Tap Offline Self-Test (Works in Airplane Mode)

    public func runOfflineSelfTest(sampleSubtitle: String = "Watch your six! They're flanking us from the rooftops.") async {
        guard let cgImage = renderTestSubtitleImage(text: sampleSubtitle) else { return }
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let ocrRes = try await ocr.recognize(cgImage: cgImage, titleID: "TEST00001", forceRefresh: true)
            lastOCRText = ocrRes.text
            lastOCRMs = ocrRes.latencyMs

            guard isModelLoaded else {
                lastArabicText = "تمت قراءة النص بـ Apple Vision في \(Int(ocrRes.latencyMs))ms — حمّل نموذج GGUF لتجربة الترجمة."
                lastTotalMs = ocrRes.latencyMs
                return
            }

            let glossary = await cache.loadGlossary(for: "TEST00001")
            let output = try await translator.translateStreaming(
                englishText: ocrRes.text,
                titleID: "TEST00001",
                glossary: glossary
            ) { [weak self] partial, _ in
                Task { @MainActor [weak self] in
                    self?.lastArabicText = partial
                }
            }

            lastArabicText = output.arabicText
            lastTTFTMs = output.ttftMs
            lastTotalMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            lastWasCacheHit = false
        } catch {
            statusMessage = "فشل الاختبار: \(error.localizedDescription)"
        }
    }

    private func renderTestSubtitleImage(text: String) -> CGImage? {
        #if canImport(UIKit)
        let size = CGSize(width: 640, height: 100)
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 22),
                .foregroundColor: UIColor.white
            ]
            let rect = CGRect(x: 16, y: 24, width: size.width - 32, height: size.height - 32)
            (text as NSString).draw(in: rect, withAttributes: attrs)
        }
        return uiImage.cgImage
        #else
        return nil
        #endif
    }
}

import Foundation
import CoreGraphics
import Vision

public struct OCRResult: Sendable {
    public let text: String
    public let latencyMs: Double
    public let isDuplicate: Bool
    public let isEmpty: Bool
}

/// Ultra-fast Apple Vision OCR engine tailored for cropped PS5 subtitle ROIs (<25ms on A18).
public actor FastOCREngine {

    public var recognitionLevel: VNRequestTextRecognitionLevel = .fast
    public var similarityThreshold: Double = 0.92

    private var lastRecognizedNormalized: String = ""
    private var lastTitleID: String = ""
    private let grayColorSpace = CGColorSpaceCreateDeviceGray()

    public init() {}

    public func setRecognitionLevel(_ level: VNRequestTextRecognitionLevel) {
        self.recognitionLevel = level
    }

    public func resetDeduplication() {
        lastRecognizedNormalized = ""
    }

    /// Runs Vision OCR on raw Gray8 / RLE-Gray8 / RGB565 bytes from `PKT_ROI_FRAME`.
    public func recognize(
        rawPixels: Data,
        width: Int,
        height: Int,
        pixelFormat: PS5TPixelFormat,
        titleID: String,
        forceRefresh: Bool
    ) throws -> OCRResult {
        let start = CFAbsoluteTimeGetCurrent()

        guard width > 4, height > 4,
              let cgImage = makeCGImage(rawPixels: rawPixels, width: width, height: height, format: pixelFormat) else {
            return OCRResult(text: "", latencyMs: 0, isDuplicate: false, isEmpty: true)
        }

        return try recognize(cgImage: cgImage, titleID: titleID, forceRefresh: forceRefresh, startTime: start)
    }

    /// Convenience overload used by the Dashboard's offline self-test.
    public func recognize(
        cgImage: CGImage,
        titleID: String,
        forceRefresh: Bool,
        startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.08

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        let sorted = observations.sorted { lhs, rhs in
            let dy = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
            if dy > 0.12 {
                // Vision origin is bottom-left: higher midY is higher on screen
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        let lines = sorted.compactMap { obs -> String? in
            guard let candidate = obs.topCandidates(1).first, candidate.confidence >= 0.30 else {
                return nil
            }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        let joined = lines.joined(separator: " ")
        let latencyMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

        if joined.isEmpty {
            let wasAlreadyEmpty = lastRecognizedNormalized.isEmpty && lastTitleID == titleID
            lastRecognizedNormalized = ""
            lastTitleID = titleID
            return OCRResult(text: "", latencyMs: latencyMs, isDuplicate: wasAlreadyEmpty && !forceRefresh, isEmpty: true)
        }

        let normalized = TranslationCache.normalize(joined)
        let isSameGame = (lastTitleID == titleID)
        let duplicate = !forceRefresh && isSameGame && !lastRecognizedNormalized.isEmpty &&
            Self.levenshteinSimilarity(normalized, lastRecognizedNormalized) >= similarityThreshold

        if !duplicate {
            lastRecognizedNormalized = normalized
            lastTitleID = titleID
        }

        return OCRResult(text: joined, latencyMs: latencyMs, isDuplicate: duplicate, isEmpty: false)
    }

    // MARK: - Zero-Copy / Fast Pixel Buffer -> CGImage Conversion

    private func makeCGImage(
        rawPixels: Data,
        width: Int,
        height: Int,
        format: PS5TPixelFormat
    ) -> CGImage? {
        let expectedGrayCount = width * height
        let grayData: Data

        switch format {
        case .gray8:
            guard rawPixels.count >= expectedGrayCount else { return nil }
            grayData = rawPixels.count == expectedGrayCount ? rawPixels : rawPixels.prefix(expectedGrayCount)

        case .gray8RLE:
            var decoded = Data()
            decoded.reserveCapacity(expectedGrayCount)
            rawPixels.withUnsafeBytes { buf in
                let ptr = buf.bindMemory(to: UInt8.self)
                var i = 0
                while i + 1 < ptr.count && decoded.count < expectedGrayCount {
                    let runLen = min(Int(ptr[i]), expectedGrayCount - decoded.count)
                    let value = ptr[i + 1]
                    decoded.append(contentsOf: repeatElement(value, count: runLen))
                    i += 2
                }
            }
            guard decoded.count == expectedGrayCount else { return nil }
            grayData = decoded

        case .rgb565:
            guard rawPixels.count >= expectedGrayCount * 2 else { return nil }
            var converted = Data(count: expectedGrayCount)
            rawPixels.withUnsafeBytes { srcBuf in
                converted.withUnsafeMutableBytes { dstBuf in
                    let src = srcBuf.bindMemory(to: UInt8.self)
                    let dst = dstBuf.bindMemory(to: UInt8.self)
                    for px in 0..<expectedGrayCount {
                        let lo = UInt16(src[px * 2])
                        let hi = UInt16(src[px * 2 + 1])
                        let rgb = lo | (hi << 8)
                        let r = Int((rgb >> 11) & 0x1F) * 255 / 31
                        let g = Int((rgb >> 5) & 0x3F) * 255 / 63
                        let b = Int(rgb & 0x1F) * 255 / 31
                        dst[px] = UInt8((r * 77 + g * 150 + b * 29) >> 8)
                    }
                }
            }
            grayData = converted
        }

        guard let provider = CGDataProvider(data: grayData as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: grayColorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Fuzzy Deduplication (Levenshtein Similarity)

    public nonisolated static func levenshteinSimilarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        let s1 = Array(a.unicodeScalars)
        let s2 = Array(b.unicodeScalars)
        let m = s1.count
        let n = s2.count
        if m == 0 || n == 0 { return 0.0 }

        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = (s1[i - 1] == s2[j - 1]) ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,
                    curr[j - 1] + 1,
                    prev[j - 1] + cost
                )
            }
            swap(&prev, &curr)
        }

        let distance = prev[n]
        return 1.0 - (Double(distance) / Double(max(m, n)))
    }
}

import Foundation

/// Pure-Swift Arabic contextual shaper + visual BiDi reorderer.
/// Produces UTF-8 strings ready for direct left-to-right glyph rendering on PS5 (`stb_truetype`).
public enum ArabicTextShaper {

    // [Isolated, Final, Initial, Medial] in Unicode Arabic Presentation Forms-B
    private static let formsMap: [UInt32: (iso: UInt32, fin: UInt32?, ini: UInt32?, med: UInt32?)] = [
        0x0621: (0xFE80, nil,    nil,    nil),    // ء
        0x0622: (0xFE81, 0xFE82, nil,    nil),    // آ
        0x0623: (0xFE83, 0xFE84, nil,    nil),    // أ
        0x0624: (0xFE85, 0xFE86, nil,    nil),    // ؤ
        0x0625: (0xFE87, 0xFE88, nil,    nil),    // إ
        0x0626: (0xFE89, 0xFE8A, 0xFE8B, 0xFE8C), // ئ
        0x0627: (0xFE8D, 0xFE8E, nil,    nil),    // ا
        0x0628: (0xFE8F, 0xFE90, 0xFE91, 0xFE92), // ب
        0x0629: (0xFE93, 0xFE94, nil,    nil),    // ة
        0x062A: (0xFE95, 0xFE96, 0xFE97, 0xFE98), // ت
        0x062B: (0xFE99, 0xFE9A, 0xFE9B, 0xFE9C), // ث
        0x062C: (0xFE9D, 0xFE9E, 0xFE9F, 0xFEA0), // ج
        0x062D: (0xFEA1, 0xFEA2, 0xFEA3, 0xFEA4), // ح
        0x062E: (0xFEA5, 0xFEA6, 0xFEA7, 0xFEA8), // خ
        0x062F: (0xFEA9, 0xFEAA, nil,    nil),    // د
        0x0630: (0xFEAB, 0xFEAC, nil,    nil),    // ذ
        0x0631: (0xFEAD, 0xFEAE, nil,    nil),    // ر
        0x0632: (0xFEAF, 0xFEB0, nil,    nil),    // ز
        0x0633: (0xFEB1, 0xFEB2, 0xFEB3, 0xFEB4), // س
        0x0634: (0xFEB5, 0xFEB6, 0xFEB7, 0xFEB8), // ش
        0x0635: (0xFEB9, 0xFEBA, 0xFEBB, 0xFEBC), // ص
        0x0636: (0xFEBD, 0xFEBE, 0xFEBF, 0xFEC0), // ض
        0x0637: (0xFEC1, 0xFEC2, 0xFEC3, 0xFEC4), // ط
        0x0638: (0xFEC5, 0xFEC6, 0xFEC7, 0xFEC8), // ظ
        0x0639: (0xFEC9, 0xFECA, 0xFECB, 0xFECC), // ع
        0x063A: (0xFECD, 0xFECE, 0xFECF, 0xFED0), // غ
        0x0640: (0x0640, 0x0640, 0x0640, 0x0640), // ـ Tatweel
        0x0641: (0xFED1, 0xFED2, 0xFED3, 0xFED4), // ف
        0x0642: (0xFED5, 0xFED6, 0xFED7, 0xFED8), // ق
        0x0643: (0xFED9, 0xFEDA, 0xFEDB, 0xFEDC), // ك
        0x0644: (0xFEDD, 0xFEDE, 0xFEDF, 0xFEE0), // ل
        0x0645: (0xFEE1, 0xFEE2, 0xFEE3, 0xFEE4), // م
        0x0646: (0xFEE5, 0xFEE6, 0xFEE7, 0xFEE8), // ن
        0x0647: (0xFEE9, 0xFEEA, 0xFEEB, 0xFEEC), // ه
        0x0648: (0xFEED, 0xFEEE, nil,    nil),    // و
        0x0649: (0xFEEF, 0xFEF0, nil,    nil),    // ى
        0x064A: (0xFEF1, 0xFEF2, 0xFEF3, 0xFEF4)  // ي
    ]

    // Lam (0x0644) + Alef variants -> [Isolated, Final]
    private static let lamAlefLigatures: [UInt32: (iso: UInt32, fin: UInt32)] = [
        0x0622: (0xFEF5, 0xFEF6), // لآ
        0x0623: (0xFEF7, 0xFEF8), // لأ
        0x0625: (0xFEF9, 0xFEFA), // لإ
        0x0627: (0xFEFB, 0xFEFC)  // لا
    ]

    private static let mirroredBrackets: [UInt32: UInt32] = [
        0x0028: 0x0029, 0x0029: 0x0028, // ( )
        0x005B: 0x005D, 0x005D: 0x005B, // [ ]
        0x007B: 0x007D, 0x007D: 0x007B, // { }
        0x003C: 0x003E, 0x003E: 0x003C, // < >
        0x00AB: 0x00BB, 0x00BB: 0x00AB  // « »
    ]

    /// Shapes, wraps logically into <= maxCharsPerLine, and applies visual RTL->LTR BiDi reordering per line.
    public static func shapeAndReorder(_ input: String, maxCharsPerLine: Int = 46) -> String {
        let cleaned = stripDiacritics(input)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return "" }

        let rawParagraphs = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
        var visualLines: [String] = []

        for paragraph in rawParagraphs {
            let wrapped = wrapLogicalLine(String(paragraph), maxChars: maxCharsPerLine)
            for line in wrapped {
                let shaped = shapeArabicScalars(Array(line.unicodeScalars))
                let reordered = reorderVisualRTL(shaped)
                visualLines.append(reordered)
            }
        }

        return visualLines.joined(separator: "\n")
    }

    // MARK: - Step 1: Remove Tashkeel / Zero-Width Marks

    private static func stripDiacritics(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        for s in text.unicodeScalars {
            let v = s.value
            if (v >= 0x064B && v <= 0x065F) || v == 0x0670 || v == 0x200E || v == 0x200F {
                continue
            }
            out.append(s)
        }
        return String(out)
    }

    // MARK: - Step 2: Logical Word Wrapping (Before BiDi Reversal)

    private static func wrapLogicalLine(_ line: String, maxChars: Int) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > maxChars, maxChars > 8 else { return [trimmed] }

        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        var lines: [String] = []
        var current = ""

        for word in words {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= maxChars {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }

    // MARK: - Step 3: Arabic Contextual Shaping + Lam-Alef Ligatures

    private static func connectsLeft(_ code: UInt32) -> Bool {
        guard let forms = formsMap[code] else { return false }
        return forms.ini != nil
    }

    private static func connectsRight(_ code: UInt32) -> Bool {
        guard let forms = formsMap[code] else { return false }
        return forms.fin != nil
    }

    private static func shapeArabicScalars(_ scalars: [UnicodeScalar]) -> [UnicodeScalar] {
        var result: [UnicodeScalar] = []
        result.reserveCapacity(scalars.count)

        let count = scalars.count
        var i = 0
        var prevConnectedLeft = false

        while i < count {
            let cur = scalars[i].value

            // Handle Lam-Alef ligatures (لا لأ لإ لآ)
            if cur == 0x0644, i + 1 < count, let lig = lamAlefLigatures[scalars[i + 1].value] {
                let targetCode = prevConnectedLeft ? lig.fin : lig.iso
                if let sc = UnicodeScalar(targetCode) {
                    result.append(sc)
                }
                prevConnectedLeft = false // Lam-Alef never connects to the following character
                i += 2
                continue
            }

            if let forms = formsMap[cur] {
                let nextConnectsRight: Bool = {
                    guard i + 1 < count else { return false }
                    return connectsRight(scalars[i + 1].value)
                }()

                let canJoinPrev = prevConnectedLeft && (forms.fin != nil)
                let canJoinNext = nextConnectsRight && (forms.ini != nil)

                let chosen: UInt32
                if canJoinPrev && canJoinNext, let med = forms.med {
                    chosen = med
                } else if canJoinPrev, let fin = forms.fin {
                    chosen = fin
                } else if canJoinNext, let ini = forms.ini {
                    chosen = ini
                } else {
                    chosen = forms.iso
                }

                if let sc = UnicodeScalar(chosen) {
                    result.append(sc)
                }
                prevConnectedLeft = connectsLeft(cur)
            } else {
                result.append(scalars[i])
                prevConnectedLeft = false
            }

            i += 1
        }

        return result
    }

    // MARK: - Step 4: Visual BiDi Reordering (RTL Base Paragraph -> LTR Render Stream)

    private static func isLTRChar(_ v: UInt32) -> Bool {
        return (v >= 0x0030 && v <= 0x0039) || // 0-9
               (v >= 0x0041 && v <= 0x005A) || // A-Z
               (v >= 0x0061 && v <= 0x007A) || // a-z
               (v >= 0x0660 && v <= 0x0669)    // Arabic-Indic digits (read LTR)
    }

    private static func isLTRConnector(_ v: UInt32) -> Bool {
        return v == 0x002E || v == 0x002C || v == 0x002D || v == 0x003A || v == 0x002F || v == 0x002B || v == 0x0025
    }

    private static func isArabicScalar(_ v: UInt32) -> Bool {
        return (v >= 0x0600 && v <= 0x06FF) ||
               (v >= 0xFB50 && v <= 0xFDFF) ||
               (v >= 0xFE70 && v <= 0xFEFF)
    }

    private static func reorderVisualRTL(_ scalars: [UnicodeScalar]) -> String {
        // If line contains no Arabic at all (pure English / symbols), leave LTR as-is
        guard scalars.contains(where: { isArabicScalar($0.value) }) else {
            return String(String.UnicodeScalarView(scalars))
        }

        // Segment into runs: RTL runs (reversed) and embedded LTR runs (kept forward)
        var visualRuns: [[UnicodeScalar]] = []
        var i = 0
        let n = scalars.count

        while i < n {
            if isLTRChar(scalars[i].value) {
                var ltrRun: [UnicodeScalar] = []
                while i < n {
                    let v = scalars[i].value
                    if isLTRChar(v) {
                        ltrRun.append(scalars[i])
                        i += 1
                    } else if (v == 0x0020 || isLTRConnector(v)),
                              i + 1 < n,
                              isLTRChar(scalars[i + 1].value) {
                        ltrRun.append(scalars[i])
                        i += 1
                    } else {
                        break
                    }
                }
                visualRuns.append(ltrRun)
            } else {
                var rtlRun: [UnicodeScalar] = []
                while i < n && !isLTRChar(scalars[i].value) {
                    let v = scalars[i].value
                    if let mirrored = mirroredBrackets[v], let msc = UnicodeScalar(mirrored) {
                        rtlRun.append(msc)
                    } else {
                        rtlRun.append(scalars[i])
                    }
                    i += 1
                }
                visualRuns.append(rtlRun.reversed())
            }
        }

        // Reverse run order so rightmost logical run appears on the right in LTR draw space
        var output = String.UnicodeScalarView()
        output.reserveCapacity(n)
        for run in visualRuns.reversed() {
            output.append(contentsOf: run)
        }
        return String(output)
    }
}

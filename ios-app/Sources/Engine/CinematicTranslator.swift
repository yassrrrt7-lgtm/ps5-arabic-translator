import Foundation
#if canImport(llama)
import llama
#endif

public enum TranslationQualityMode: String, CaseIterable, Identifiable, Sendable {
    case ultraFast = "ultra_fast"
    case cinematicPro = "cinematic_pro"

    public var id: String { rawValue }

    public var arabicTitle: String {
        switch self {
        case .ultraFast: return "فائق السرعة (1.5B)"
        case .cinematicPro: return "احترافي سينمائي (3B)"
        }
    }

    public var recommendedFileName: String {
        switch self {
        case .ultraFast: return "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
        case .cinematicPro: return "Qwen2.5-3B-Instruct-Q4_K_M.gguf"
        }
    }

    public var downloadURLString: String {
        switch self {
        case .ultraFast:
            return "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"
        case .cinematicPro:
            return "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf"
        }
    }
}

public enum TranslatorError: LocalizedError, Sendable {
    case modelNotLoaded
    case backendUnavailable
    case modelLoadFailed(String)
    case contextInitFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "لم يتم تحميل نموذج الترجمة الأوفلاين بعد."
        case .backendUnavailable:
            return "مكتبة llama.cpp غير مرتبطة في هذا البناء."
        case .modelLoadFailed(let path):
            return "فشل تحميل ملف النموذج: \(path)"
        case .contextInitFailed:
            return "فشل تهيئة ذاكرة المعالجة على Metal."
        case .cancelled:
            return "تم إلغاء الترجمة لوصول جملة أحدث."
        }
    }
}

public struct TranslationOutput: Sendable {
    public let arabicText: String
    public let ttftMs: Double
    public let totalMs: Double
}

/// Offline Metal-accelerated cinematic Arabic game translator with KV/Prompt Caching & 5-line rolling context.
public actor CinematicTranslator {

    private struct DialogueTurn {
        let english: String
        let arabic: String
    }

    private let maxContextTurns = 5
    private var rollingHistory: [String: [DialogueTurn]] = [:]
    private var loadedModelURL: URL?

    // Cached KV prefix metadata (System Prompt + Glossary stay hot in Metal VRAM)
    private var cachedPrefixKey: String = ""
    private var cachedPrefixTokenCount: Int32 = 0

    // Monotonic generation ID to preempt stale frames immediately
    private var activeGenerationID: UInt64 = 0

    #if canImport(llama)
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var backendInitialized = false
    #endif

    public init() {}

    deinit {
        #if canImport(llama)
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        #endif
    }

    public var isLoaded: Bool {
        #if canImport(llama)
        return model != nil && ctx != nil
        #else
        return false
        #endif
    }

    public var currentModelName: String? {
        loadedModelURL?.lastPathComponent
    }

    public func cancelInFlight() {
        activeGenerationID &+= 1
    }

    public func clearRollingContext(for titleID: String? = nil) {
        if let titleID {
            rollingHistory.removeValue(forKey: titleID)
        } else {
            rollingHistory.removeAll()
        }
    }

    // MARK: - Model Loading (Full Metal GPU Offload on A18)

    public func loadModel(at url: URL) throws {
        #if canImport(llama)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranslatorError.modelLoadFailed(url.lastPathComponent)
        }

        unloadModel()

        if !backendInitialized {
            llama_backend_init()
            backendInitialized = true
        }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99 // Offload all transformer layers to Apple A18 Metal GPU

        guard let loadedModel = llama_model_load_from_file(url.path, modelParams) else {
            throw TranslatorError.modelLoadFailed(url.lastPathComponent)
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 1536
        ctxParams.n_batch = 512
        ctxParams.n_ubatch = 256
        ctxParams.n_threads = 4
        ctxParams.n_threads_batch = 6

        guard let createdCtx = llama_init_from_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            throw TranslatorError.contextInitFailed
        }

        self.model = loadedModel
        self.ctx = createdCtx
        self.vocab = llama_model_get_vocab(loadedModel)
        self.loadedModelURL = url
        self.cachedPrefixKey = ""
        self.cachedPrefixTokenCount = 0
        #else
        throw TranslatorError.backendUnavailable
        #endif
    }

    public func unloadModel() {
        #if canImport(llama)
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil
        model = nil
        vocab = nil
        #endif
        loadedModelURL = nil
        cachedPrefixKey = ""
        cachedPrefixTokenCount = 0
    }

    // MARK: - Prompt Engineering (Cinematic Arabic Localization)

    private func buildSystemPrefix(glossary: [String: String]) -> String {
        var glossarySection = ""
        if !glossary.isEmpty {
            let sortedTerms = glossary
                .sorted { $0.key.lowercased() < $1.key.lowercased() }
                .prefix(40)
                .map { "- \($0.key) => \($0.value)" }
                .joined(separator: "\n")
            glossarySection = "\nGame Glossary (MUST follow strictly):\n\(sortedTerms)\n"
        }

        return """
        <|im_start|>system
        You are an elite Arabic video game localizer. Translate the English game subtitle into natural, idiomatic, cinematic Arabic.
        Rules:
        1. Translate meaning, emotion, and idioms naturally (never literal word-for-word Google Translate).
        2. Use the recent dialogue context to maintain exact speaker tone, gender (مذكر/مؤنث), and narrative flow.
        3. Keep proper names of characters, cities, and button prompts (X, O, L1, R1) natural and consistent.
        4. Output ONLY the final Arabic subtitle line. No quotes, no notes, no explanations, no English.\(glossarySection)<|im_end|>
        """
    }

    private func buildUserTurn(titleID: String, englishText: String) -> String {
        let turns = rollingHistory[titleID] ?? []
        var contextBlock = ""
        if !turns.isEmpty {
            let lines = turns.map { "EN: \($0.english)\nAR: \($0.arabic)" }.joined(separator: "\n")
            contextBlock = "Recent dialogue context:\n\(lines)\n\n"
        }

        return """
        <|im_start|>user
        \(contextBlock)Translate this subtitle to cinematic Arabic:
        \(englishText)<|im_end|>
        <|im_start|>assistant
        """
    }

    // MARK: - Streaming Translation with KV Prefix Caching

    public func translateStreaming(
        englishText: String,
        titleID: String,
        glossary: [String: String],
        onTokenChunk: @escaping @Sendable (_ cumulativeArabic: String, _ elapsedMs: Double) -> Void
    ) throws -> TranslationOutput {
        #if canImport(llama)
        guard let ctx, let vocab else {
            throw TranslatorError.modelNotLoaded
        }

        let start = CFAbsoluteTimeGetCurrent()
        activeGenerationID &+= 1
        let myGenID = activeGenerationID

        let systemPrefix = buildSystemPrefix(glossary: glossary)
        let userSuffix = buildUserTurn(titleID: titleID, englishText: englishText)

        // 1. Reuse KV cache for System Prompt + Glossary whenever unchanged
        if cachedPrefixKey != systemPrefix {
            clearKVCache(ctx: ctx, fromPos: 0)
            let prefixTokens = tokenize(vocab: vocab, text: systemPrefix, addSpecial: true)
            try evaluateTokens(ctx: ctx, tokens: prefixTokens, startPos: 0, computeLastLogit: false)
            cachedPrefixKey = systemPrefix
            cachedPrefixTokenCount = Int32(prefixTokens.count)
        } else {
            // Trim only the previous dynamic user/assistant turn while preserving System Prompt KV!
            clearKVCache(ctx: ctx, fromPos: cachedPrefixTokenCount)
        }

        // 2. Evaluate dynamic context + current English subtitle
        let suffixTokens = tokenize(vocab: vocab, text: userSuffix, addSpecial: false)
        try evaluateTokens(ctx: ctx, tokens: suffixTokens, startPos: cachedPrefixTokenCount, computeLastLogit: true)

        // 3. Fast low-temperature sampler for faithful, crisp localization
        let chainParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(chainParams) else {
            throw TranslatorError.contextInitFailed
        }
        defer { llama_sampler_free(sampler) }

        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(24))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.85, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.22))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(42))

        var currentPos = cachedPrefixTokenCount + Int32(suffixTokens.count)
        let maxNewTokens = 96
        var rawUTF8Bytes = Data()
        rawUTF8Bytes.reserveCapacity(512)
        var ttftMs: Double = 0
        var lastEmittedText = ""
        var tokenIndex = 0

        var singleBatch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(singleBatch) }

        while tokenIndex < maxNewTokens {
            if activeGenerationID != myGenID {
                throw TranslatorError.cancelled
            }

            let nextToken = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, nextToken) {
                break
            }

            let pieceBytes = tokenToUTF8Bytes(vocab: vocab, token: nextToken)
            rawUTF8Bytes.append(pieceBytes)

            if let decoded = String(data: rawUTF8Bytes, encoding: .utf8) {
                let cleaned = sanitizePartialArabic(decoded)
                if !cleaned.isEmpty && cleaned != lastEmittedText {
                    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                    if ttftMs == 0 {
                        ttftMs = elapsed
                    }
                    // Stream every 2 tokens or on spaces/punctuation for smooth zero-jitter UDP updates
                    if tokenIndex == 0 || tokenIndex % 2 == 0 || cleaned.last == " " || cleaned.last == "." {
                        lastEmittedText = cleaned
                        onTokenChunk(cleaned, elapsed)
                    }
                }
            }

            // Prepare next token decode step
            singleBatch.n_tokens = 1
            singleBatch.token[0] = nextToken
            singleBatch.pos[0] = currentPos
            singleBatch.n_seq_id[0] = 1
            singleBatch.seq_id[0]![0] = 0
            singleBatch.logits[0] = 1

            if llama_decode(ctx, singleBatch) != 0 {
                break
            }

            currentPos += 1
            tokenIndex += 1
        }

        let finalArabic = sanitizePartialArabic(String(decoding: rawUTF8Bytes, as: UTF8.self))
        let totalMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        if ttftMs == 0 { ttftMs = totalMs }

        if !finalArabic.isEmpty {
            appendRollingTurn(titleID: titleID, english: englishText, arabic: finalArabic)
        }

        return TranslationOutput(arabicText: finalArabic, ttftMs: ttftMs, totalMs: totalMs)
        #else
        throw TranslatorError.backendUnavailable
        #endif
    }

    private func appendRollingTurn(titleID: String, english: String, arabic: String) {
        var list = rollingHistory[titleID] ?? []
        list.append(DialogueTurn(english: english, arabic: arabic))
        if list.count > maxContextTurns {
            list.removeFirst(list.count - maxContextTurns)
        }
        rollingHistory[titleID] = list
    }

    private func sanitizePartialArabic(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .replacingOccurrences(of: "<|endoftext|>", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"«» \t\r\n"))
    }

    // MARK: - Low-Level llama.cpp Helpers

    #if canImport(llama)
    private func clearKVCache(ctx: OpaquePointer, fromPos: Int32) {
        if let mem = llama_get_memory(ctx) {
            _ = llama_memory_seq_rm(mem, 0, fromPos, -1)
        }
    }

    private func tokenize(vocab: OpaquePointer, text: String, addSpecial: Bool) -> [llama_token] {
        let utf8Count = text.utf8.count
        let maxTokens = utf8Count + 16
        var buffer = [llama_token](repeating: 0, count: maxTokens)

        let count = text.withCString { cStr in
            llama_tokenize(vocab, cStr, Int32(utf8Count), &buffer, Int32(maxTokens), addSpecial, true)
        }

        if count < 0 {
            let needed = Int(-count)
            buffer = [llama_token](repeating: 0, count: needed)
            let retry = text.withCString { cStr in
                llama_tokenize(vocab, cStr, Int32(utf8Count), &buffer, Int32(needed), addSpecial, true)
            }
            return Array(buffer.prefix(max(0, Int(retry))))
        }
        return Array(buffer.prefix(Int(count)))
    }

    private func evaluateTokens(
        ctx: OpaquePointer,
        tokens: [llama_token],
        startPos: Int32,
        computeLastLogit: Bool
    ) throws {
        guard !tokens.isEmpty else { return }
        let chunkSize = 256
        var offset = 0

        while offset < tokens.count {
            let count = min(chunkSize, tokens.count - offset)
            var batch = llama_batch_init(Int32(count), 0, 1)
            defer { llama_batch_free(batch) }

            batch.n_tokens = Int32(count)
            for i in 0..<count {
                let globalIdx = offset + i
                batch.token[i] = tokens[globalIdx]
                batch.pos[i] = startPos + Int32(globalIdx)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = 0
                let isVeryLast = (globalIdx == tokens.count - 1)
                batch.logits[i] = (computeLastLogit && isVeryLast) ? 1 : 0
            }

            if llama_decode(ctx, batch) != 0 {
                throw TranslatorError.contextInitFailed
            }
            offset += count
        }
    }

    private func tokenToUTF8Bytes(vocab: OpaquePointer, token: llama_token) -> Data {
        var buf = [CChar](repeating: 0, count: 64)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
        if n > 0 {
            return Data(bytes: buf, count: Int(n))
        } else if n < 0 {
            let needed = Int(-n)
            var large = [CChar](repeating: 0, count: needed)
            let retry = llama_token_to_piece(vocab, token, &large, Int32(needed), 0, true)
            if retry > 0 {
                return Data(bytes: large, count: Int(retry))
            }
        }
        return Data()
    }
    #endif
}

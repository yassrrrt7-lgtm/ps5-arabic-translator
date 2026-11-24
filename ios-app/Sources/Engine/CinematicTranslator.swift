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
            return "لم يتم تحميل نموذج الترجمة الأوفلاين أو إضافة مفتاح سحابي بعد."
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

/// Hybrid ultra-fast cinematic Arabic game translator:
/// 1) Ultra-low-latency Cloud Streaming (Groq Llama 3.3 70B / Google Gemini 2.5 Flash)
/// 2) Instant automatic fallback to Metal-accelerated offline llama.cpp (Qwen / Gemma)
public actor CinematicTranslator {

    private struct DialogueTurn {
        let english: String
        let arabic: String
    }

    private enum CloudProvider {
        case groq
        case gemini
    }

    private static let groqKeyStorage = "ps5_hybrid_groq_key"
    private static let geminiKeyStorage = "ps5_hybrid_gemini_key"
    private static let cloudModeStorage = "ps5_hybrid_cloud_mode"

    private let maxContextTurns = 5
    private var rollingHistory: [String: [DialogueTurn]] = [:]
    private var loadedModelURL: URL?

    // Cached KV prefix metadata for local offline fallback
    private var cachedPrefixKey: String = ""
    private var cachedPrefixTokenCount: Int32 = 0

    // Monotonic generation ID to preempt stale frames immediately
    private var activeGenerationID: UInt64 = 0

    // Hybrid cloud state & low-latency HTTP session
    private let cloudSession: URLSession
    private var cachedGroqKey: String
    private var cachedGeminiKey: String
    private var preferredCloudMode: String
    private var lastDiskScanTime: CFAbsoluteTime = 0

    #if canImport(llama)
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var backendInitialized = false
    #endif

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.5
        config.timeoutIntervalForResource = 6.0
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        self.cloudSession = URLSession(configuration: config)

        self.cachedGroqKey = UserDefaults.standard.string(forKey: Self.groqKeyStorage) ?? ""
        self.cachedGeminiKey = UserDefaults.standard.string(forKey: Self.geminiKeyStorage) ?? ""
        self.preferredCloudMode = UserDefaults.standard.string(forKey: Self.cloudModeStorage) ?? "auto"
    }

    deinit {
        cloudSession.invalidateAndCancel()
        #if canImport(llama)
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        #endif
    }

    private var hasActiveCloudProvider: Bool {
        preferredCloudMode != "offline" && (!cachedGroqKey.isEmpty || !cachedGeminiKey.isEmpty)
    }

    public var isLoaded: Bool {
        if hasActiveCloudProvider {
            return true
        }
        #if canImport(llama)
        return model != nil && ctx != nil
        #else
        return false
        #endif
    }

    public var currentModelName: String? {
        let localName = loadedModelURL?.lastPathComponent
        if hasActiveCloudProvider {
            let cloudLabel: String
            if preferredCloudMode == "gemini", !cachedGeminiKey.isEmpty {
                cloudLabel = "هجين: Gemini Flash"
            } else if !cachedGroqKey.isEmpty && !cachedGeminiKey.isEmpty {
                cloudLabel = "هجين: Groq 70B + Gemini"
            } else if !cachedGroqKey.isEmpty {
                cloudLabel = "هجين: Groq 70B"
            } else {
                cloudLabel = "هجين: Gemini Flash"
            }
            if let localName {
                return "\(cloudLabel) + \(localName)"
            }
            return cloudLabel
        }
        return localName
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
        ctxParams.n_ctx = 1024
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

    // MARK: - Prompt Engineering (Studio-Grade Cinematic Arabic Localization)

    private var isGemmaModel: Bool {
        loadedModelURL?.lastPathComponent.lowercased().contains("gemma") == true
    }

    private func buildCoreInstructions(glossary: [String: String]) -> String {
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
        You are a senior Arabic AAA video game localizer for PlayStation exclusives. Translate the English game subtitle into natural, sharp, cinematic Arabic.
        Rules:
        1. Translate idioms, slang, military callouts, and emotions naturally—NEVER translate literally.
        2. Use recent dialogue context to maintain exact speaker tone, gender (مذكر/مؤنث), and narrative flow.
        3. Keep proper names and controller buttons (X, O, L1, R1) natural and consistent.
        4. Avoid unnecessary Arabic diacritics (تشكيل) unless essential for clarity.
        5. Output ONLY the final Arabic subtitle line. No quotes, no explanations, no English.
        Examples:
        - Watch your six! They're flanking us from the rooftops. => انتبه خلفك! إنهم يلتفون حولنا من الأسطح.
        - Hold your fire! He's with us. => أوقف إطلاق النار! إنه معنا.
        - You've got to be kidding me. => لا بد أنك تمزح معي.\(glossarySection)
        """
    }

    private func buildPlainUserMessage(titleID: String, englishText: String) -> String {
        let turns = rollingHistory[titleID] ?? []
        if turns.isEmpty {
            return "Translate to cinematic Arabic:\n\(englishText)"
        }
        let lines = turns.map { "EN: \($0.english)\nAR: \($0.arabic)" }.joined(separator: "\n")
        return """
        Recent dialogue context:
        \(lines)

        Translate this subtitle to cinematic Arabic:
        \(englishText)
        """
    }

    private func buildLocalSystemPrefix(glossary: [String: String]) -> String {
        let core = buildCoreInstructions(glossary: glossary)
        if isGemmaModel {
            return "<start_of_turn>user\n\(core)\n\n"
        }
        return "<|im_start|>system\n\(core)<|im_end|>\n"
    }

    private func buildLocalUserTurn(titleID: String, englishText: String) -> String {
        let body = buildPlainUserMessage(titleID: titleID, englishText: englishText)
        if isGemmaModel {
            return "\(body)<end_of_turn>\n<start_of_turn>model\n"
        }
        return "<|im_start|>user\n\(body)<|im_end|>\n<|im_start|>assistant\n"
    }

    // MARK: - Hybrid Streaming Translation (Cloud First -> Instant Offline Fallback)

    public func translateStreaming(
        englishText: String,
        titleID: String,
        glossary: [String: String],
        onTokenChunk: @escaping @Sendable (_ cumulativeArabic: String, _ elapsedMs: Double) -> Void
    ) async throws -> TranslationOutput {
        let start = CFAbsoluteTimeGetCurrent()
        activeGenerationID &+= 1
        let myGenID = activeGenerationID

        let cleanGlossary = syncCloudConfigAndSanitizeGlossary(glossary)

        // 1. Try Ultra-Fast Cloud Providers first (if configured & not forced offline)
        if preferredCloudMode != "offline" {
            let order: [CloudProvider] = (preferredCloudMode == "gemini") ? [.gemini, .groq] : [.groq, .gemini]
            let systemPrompt = buildCoreInstructions(glossary: cleanGlossary)
            let userMessage = buildPlainUserMessage(titleID: titleID, englishText: englishText)

            for provider in order {
                if activeGenerationID != myGenID {
                    throw TranslatorError.cancelled
                }

                do {
                    let output: TranslationOutput?
                    switch provider {
                    case .groq where !cachedGroqKey.isEmpty:
                        output = try await translateViaGroq(
                            apiKey: cachedGroqKey,
                            systemPrompt: systemPrompt,
                            userMessage: userMessage,
                            myGenID: myGenID,
                            start: start,
                            onTokenChunk: onTokenChunk
                        )
                    case .gemini where !cachedGeminiKey.isEmpty:
                        output = try await translateViaGemini(
                            apiKey: cachedGeminiKey,
                            systemPrompt: systemPrompt,
                            userMessage: userMessage,
                            myGenID: myGenID,
                            start: start,
                            onTokenChunk: onTokenChunk
                        )
                    default:
                        output = nil
                    }

                    if let output, !output.arabicText.isEmpty {
                        appendRollingTurn(titleID: titleID, english: englishText, arabic: output.arabicText)
                        return output
                    }
                } catch TranslatorError.cancelled {
                    throw TranslatorError.cancelled
                } catch {
                    // Silently fall through to next cloud provider or instant local offline fallback
                    continue
                }
            }
        }

        // 2. Instant Offline Metal Fallback (llama.cpp)
        return try translateLocally(
            englishText: englishText,
            titleID: titleID,
            glossary: cleanGlossary,
            myGenID: myGenID,
            start: start,
            onTokenChunk: onTokenChunk
        )
    }

    // MARK: - Cloud Provider 1: Groq Streaming (Llama 3.3 70B — Ultra Low Latency)

    private func translateViaGroq(
        apiKey: String,
        systemPrompt: String,
        userMessage: String,
        myGenID: UInt64,
        start: CFAbsoluteTime,
        onTokenChunk: @escaping @Sendable (_ cumulativeArabic: String, _ elapsedMs: Double) -> Void
    ) async throws -> TranslationOutput {
        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": "llama-3.3-70b-versatile",
            "stream": true,
            "temperature": 0.2,
            "max_tokens": 120,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (bytes, response) = try await cloudSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        var accumulated = ""
        var lastEmittedText = ""
        var ttftMs: Double = 0

        for try await rawLine in bytes.lines {
            if activeGenerationID != myGenID {
                throw TranslatorError.cancelled
            }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let dataPart = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if dataPart.isEmpty || dataPart == "[DONE]" { continue }

            guard let jsonData = dataPart.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let piece = delta["content"] as? String, !piece.isEmpty else {
                continue
            }

            accumulated += piece
            let cleaned = sanitizePartialArabic(accumulated)
            if !cleaned.isEmpty && cleaned != lastEmittedText {
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                if ttftMs == 0 { ttftMs = elapsed }
                lastEmittedText = cleaned
                onTokenChunk(cleaned, elapsed)
            }
        }

        let finalArabic = sanitizePartialArabic(accumulated)
        guard !finalArabic.isEmpty else {
            throw URLError(.cannotDecodeContentData)
        }
        let totalMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        if ttftMs == 0 { ttftMs = totalMs }
        if finalArabic != lastEmittedText {
            onTokenChunk(finalArabic, totalMs)
        }
        return TranslationOutput(arabicText: finalArabic, ttftMs: ttftMs, totalMs: totalMs)
    }

    // MARK: - Cloud Provider 2: Google Gemini Flash Streaming (Instant No-Thinking Mode)

    private func translateViaGemini(
        apiKey: String,
        systemPrompt: String,
        userMessage: String,
        myGenID: UInt64,
        start: CFAbsoluteTime,
        onTokenChunk: @escaping @Sendable (_ cumulativeArabic: String, _ elapsedMs: Double) -> Void
    ) async throws -> TranslationOutput {
        do {
            return try await callGeminiEndpoint(
                modelName: "gemini-2.5-flash",
                disableThinking: true,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                myGenID: myGenID,
                start: start,
                onTokenChunk: onTokenChunk
            )
        } catch TranslatorError.cancelled {
            throw TranslatorError.cancelled
        } catch {
            return try await callGeminiEndpoint(
                modelName: "gemini-2.0-flash",
                disableThinking: false,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                myGenID: myGenID,
                start: start,
                onTokenChunk: onTokenChunk
            )
        }
    }

    private func callGeminiEndpoint(
        modelName: String,
        disableThinking: Bool,
        apiKey: String,
        systemPrompt: String,
        userMessage: String,
        myGenID: UInt64,
        start: CFAbsoluteTime,
        onTokenChunk: @escaping @Sendable (_ cumulativeArabic: String, _ elapsedMs: Double) -> Void
    ) async throws -> TranslationOutput {
        let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? apiKey
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):streamGenerateContent?alt=sse&key=\(encodedKey)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var genConfig: [String: Any] = [
            "temperature": 0.2,
            "maxOutputTokens": 120
        ]
        if disableThinking {
            genConfig["thinkingConfig"] = ["thinkingBudget": 0]
        }

        let payload: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": systemPrompt]]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": userMessage]]
                ]
            ],
            "generationConfig": genConfig
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (bytes, response) = try await cloudSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        var accumulated = ""
        var lastEmittedText = ""
        var ttftMs: Double = 0

        for try await rawLine in bytes.lines {
            if activeGenerationID != myGenID {
                throw TranslatorError.cancelled
            }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let dataPart = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if dataPart.isEmpty { continue }

            guard let jsonData = dataPart.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                continue
            }

            for part in parts {
                if let piece = part["text"] as? String, !piece.isEmpty {
                    accumulated += piece
                }
            }

            let cleaned = sanitizePartialArabic(accumulated)
            if !cleaned.isEmpty && cleaned != lastEmittedText {
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                if ttftMs == 0 { ttftMs = elapsed }
                lastEmittedText = cleaned
                onTokenChunk(cleaned, elapsed)
            }
        }

        let finalArabic = sanitizePartialArabic(accumulated)
        guard !finalArabic.isEmpty else {
            throw URLError(.cannotDecodeContentData)
        }
        let totalMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        if ttftMs == 0 { ttftMs = totalMs }
        if finalArabic != lastEmittedText {
            onTokenChunk(finalArabic, totalMs)
        }
        return TranslationOutput(arabicText: finalArabic, ttftMs: ttftMs, totalMs: totalMs)
    }

    // MARK: - Local Offline Metal Engine (llama.cpp)

    private func translateLocally(
        englishText: String,
        titleID: String,
        glossary: [String: String],
        myGenID: UInt64,
        start: CFAbsoluteTime,
        onTokenChunk: @escaping @Sendable (_ cumulativeArabic: String, _ elapsedMs: Double) -> Void
    ) throws -> TranslationOutput {
        #if canImport(llama)
        guard let ctx, let vocab else {
            throw TranslatorError.modelNotLoaded
        }

        let systemPrefix = buildLocalSystemPrefix(glossary: glossary)
        let userSuffix = buildLocalUserTurn(titleID: titleID, englishText: englishText)

        // 1. Reuse KV cache for System Prompt + Glossary whenever unchanged
        if cachedPrefixKey != systemPrefix {
            clearKVCache(ctx: ctx, fromPos: 0)
            let prefixTokens = tokenize(vocab: vocab, text: systemPrefix, addSpecial: true)
            try evaluateTokens(ctx: ctx, tokens: prefixTokens, startPos: 0, computeLastLogit: false)
            cachedPrefixKey = systemPrefix
            cachedPrefixTokenCount = Int32(prefixTokens.count)
        } else {
            clearKVCache(ctx: ctx, fromPos: cachedPrefixTokenCount)
        }

        // 2. Evaluate dynamic context + current English subtitle
        let suffixTokens = tokenize(vocab: vocab, text: userSuffix, addSpecial: false)
        try evaluateTokens(ctx: ctx, tokens: suffixTokens, startPos: cachedPrefixTokenCount, computeLastLogit: true)

        // 3. Fastest greedy sampler for zero-overhead deterministic translation
        let chainParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(chainParams) else {
            throw TranslatorError.contextInitFailed
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var currentPos = cachedPrefixTokenCount + Int32(suffixTokens.count)
        let maxNewTokens = 64
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
                    if tokenIndex == 0 || tokenIndex % 2 == 0 || cleaned.last == " " || cleaned.last == "." {
                        lastEmittedText = cleaned
                        onTokenChunk(cleaned, elapsed)
                    }
                }
            }

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

    // MARK: - Secure Local API Key Sync (From In-App Glossary & Local Storage)

    private func syncCloudConfigAndSanitizeGlossary(_ glossary: [String: String]) -> [String: String] {
        var clean: [String: String] = [:]
        clean.reserveCapacity(glossary.count)

        for (rawKey, rawVal) in glossary {
            let k = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let v = rawVal.trimmingCharacters(in: .whitespacesAndNewlines)

            if k == "groq" || k == "groq_api_key" || k == "groq_key" || v.hasPrefix("gsk_") {
                if !v.isEmpty {
                    cachedGroqKey = v
                    UserDefaults.standard.set(v, forKey: Self.groqKeyStorage)
                }
                continue
            }

            if k == "gemini" || k == "gemini_api_key" || k == "gemini_key" || v.hasPrefix("AIza") {
                if !v.isEmpty {
                    cachedGeminiKey = v
                    UserDefaults.standard.set(v, forKey: Self.geminiKeyStorage)
                }
                continue
            }

            if k == "cloud_mode" || k == "mode" {
                let mode = v.lowercased()
                if mode == "offline" || mode == "groq" || mode == "gemini" || mode == "auto" {
                    preferredCloudMode = mode
                    UserDefaults.standard.set(mode, forKey: Self.cloudModeStorage)
                }
                continue
            }

            if k == "clear_keys" {
                cachedGroqKey = ""
                cachedGeminiKey = ""
                UserDefaults.standard.removeObject(forKey: Self.groqKeyStorage)
                UserDefaults.standard.removeObject(forKey: Self.geminiKeyStorage)
                continue
            }

            clean[rawKey] = rawVal
        }

        // Also scan local app glossary files/UserDefaults in case the test button passed an empty glossary
        discoverKeysFromLocalStorageIfNeeded()
        return clean
    }

    private func discoverKeysFromLocalStorageIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        if (!cachedGroqKey.isEmpty && !cachedGeminiKey.isEmpty) || (now - lastDiskScanTime < 3.0) {
            return
        }
        lastDiskScanTime = now

        func inspect(_ text: String) {
            if cachedGroqKey.isEmpty, let found = extractAPIKey(prefix: "gsk_", minLen: 25, in: text) {
                cachedGroqKey = found
                UserDefaults.standard.set(found, forKey: Self.groqKeyStorage)
            }
            if cachedGeminiKey.isEmpty, let found = extractAPIKey(prefix: "AIza", minLen: 35, in: text) {
                cachedGeminiKey = found
                UserDefaults.standard.set(found, forKey: Self.geminiKeyStorage)
            }
        }

        // 1. Scan UserDefaults entries saved by the app
        for (_, value) in UserDefaults.standard.dictionaryRepresentation() {
            if let str = value as? String {
                inspect(str)
            } else if let data = value as? Data, data.count < 150_000,
                      let str = String(data: data, encoding: .utf8) {
                inspect(str)
            } else if let dict = value as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: dict),
                      data.count < 150_000,
                      let str = String(data: data, encoding: .utf8) {
                inspect(str)
            }
        }

        // 2. Scan small JSON/TXT files inside Documents & Application Support
        let dirs = [
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ].compactMap { $0 }

        for dir in dirs {
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard ext == "json" || ext == "txt" || ext == "ini" else { continue }
                guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let size = values.fileSize, size > 0, size < 150_000 else { continue }
                if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                    inspect(text)
                }
            }
        }
    }

    private func extractAPIKey(prefix: String, minLen: Int, in text: String) -> String? {
        guard let range = text.range(of: prefix) else { return nil }
        var idx = range.lowerBound
        var chars: [Character] = []
        while idx < text.endIndex {
            let ch = text[idx]
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-") {
                chars.append(ch)
                idx = text.index(after: idx)
            } else {
                break
            }
        }
        guard chars.count >= minLen else { return nil }
        return String(chars)
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
            .replacingOccurrences(of: "<end_of_turn>", with: "")
            .replacingOccurrences(of: "<start_of_turn>", with: "")
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

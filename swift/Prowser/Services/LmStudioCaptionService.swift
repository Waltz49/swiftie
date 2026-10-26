import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Native LM Studio captioning (port of `imagegen_plugins/lmstudio_caption.py` via OpenAI-compatible HTTP API).
@MainActor
final class LmStudioCaptionService {
    enum SessionState: Equatable {
        case unknown
        case unavailable
        case available
    }

    static let shared = LmStudioCaptionService()

    static let visionRequiredMessage =
        "The loaded LM Studio model does not support image input.\n\n"
        + "Please load a vision-capable model in LMStudio."

    private(set) var sessionState: SessionState = .unknown
    private var activeTask: Task<Void, Never>?

    private static let probeCacheTTL: TimeInterval = 30
    private var lastProbeCache: (hostKey: String, ok: Bool, checked: Date)?
    private var inFlightProbe: Task<Bool, Never>?

    private static let logTag = "imagegen_plugins.lmstudio_caption"

    var isCaptionInProgress: Bool { activeTask != nil }

    private init() {}

    func resetSessionState() {
        sessionState = .unknown
    }

    var isUIAvailable: Bool {
        sessionState == .available
    }

    func probeServices(config: AppConfig) async {
        _ = await probeServicesIfNeeded(config: config)
    }

    /// Single coalesced LM Studio reachability probe (shared by flux + foreground task bridges).
    func probeServicesIfNeeded(config: AppConfig) async -> Bool {
        let hostKey = captionHost(config: config).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = lastProbeCache,
           cached.hostKey == hostKey,
           Date().timeIntervalSince(cached.checked) < Self.probeCacheTTL {
            sessionState = cached.ok ? .available : .unavailable
            return cached.ok
        }
        if let inFlightProbe {
            return await inFlightProbe.value
        }
        let task = Task { @MainActor in
            let reachable = await networkProbe(config: config)
            sessionState = reachable ? .available : .unavailable
            lastProbeCache = (hostKey, reachable, Date())
            return reachable
        }
        inFlightProbe = task
        let ok = await task.value
        inFlightProbe = nil
        return ok
    }

    func cancelCaption() {
        activeTask?.cancel()
        activeTask = nil
    }

    /// Port of Python ``unload_all_lmstudio_models`` (frees RAM before image generation).
    func unloadAllModelsBeforeImageGeneration(config: AppConfig, skipUnload: Bool) async {
        sessionState = .unavailable
        lastProbeCache = nil
        if skipUnload {
            if config.bool(forKey: "debug_mode", default: false) {
                NSLog("[%@] skipping model unload while LM Studio prediction is active", Self.logTag)
            }
            return
        }
        let host = captionHost(config: config)
        guard let nativeBase = nativeAPIBaseURL(host: host) else {
            return
        }
        var loadedIDs: [String] = []
        if let openAIBase = apiBaseURL(host: host) {
            loadedIDs = (try? await fetchLoadedModelIDs(baseURL: openAIBase, config: config)) ?? []
        }
        if loadedIDs.isEmpty {
            let modelsURL = nativeBase.appending(path: "models")
            SessionViewLog.logLMStudioCall(
                method: "GET \(modelsURL.path)",
                payload: ["url": modelsURL.absoluteString, "reason": "image_gen_unload"],
                config: config
            )
            if let (data, response) = try? await URLSession.shared.data(from: modelsURL),
               let http = response as? HTTPURLResponse,
               (200 ..< 300).contains(http.statusCode) {
                logHTTPResponseData(data, status: http.statusCode, config: config)
                loadedIDs = parseLoadedNativeModelIDs(from: data)
            }
        }
        if loadedIDs.isEmpty {
            if config.bool(forKey: "debug_mode", default: false) {
                NSLog("[%@] image_gen_unload: no loaded LM Studio instances found", Self.logTag)
            }
            return
        }
        if let first = loadedIDs.first {
            persistLastModelKey(first, config: config)
        }
        let unloadURL = nativeBase.appending(path: "models/unload")
        for instanceID in loadedIDs {
            let body: [String: Any] = ["instance_id": instanceID]
            SessionViewLog.logLMStudioCall(
                method: "POST /api/v1/models/unload",
                payload: body,
                config: config
            )
            var request = URLRequest(url: unloadURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { continue }
            request.httpBody = httpBody
            if let (unloadData, unloadResponse) = try? await URLSession.shared.data(for: request),
               let unloadHTTP = unloadResponse as? HTTPURLResponse {
                logHTTPResponseData(unloadData, status: unloadHTTP.statusCode, config: config)
            }
        }
    }

    /// OpenAI-compatible streaming chat (flux prompt refinement, grammar, etc.).
    func streamChatCompletion(
        systemPrompt: String,
        userPrompt: String,
        imagePaths: [String],
        config: AppConfig,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        guard let base = apiBaseURL(host: captionHost(config: config)) else {
            throw CaptionError.runtime("Invalid LM Studio host.\n\nUse a value like localhost:1234")
        }
        let settings = captionSettings(config: config)
        var system = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var user = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        system = AIPromptExitService.applyTextAIExit(system, config: config)
        user = AIPromptExitService.applyTextAIExit(user, config: config)

        let normalizedPaths = imagePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && FileManager.default.isReadableFile(atPath: $0) }
        let uniquePaths: [String] = normalizedPaths.reduce(into: []) { acc, path in
            if !acc.contains(path) { acc.append(path) }
        }

        let modelID = try await resolveModelID(baseURL: base, config: config)

        SessionViewLog.logModelInput(
            tag: Self.logTag,
            payload: [
                "system_prompt": system,
                "user_prompt": user,
                "image_paths": uniquePaths,
                "config": ["temperature": settings.temperature, "model": modelID],
            ],
            config: config
        )

        if uniquePaths.isEmpty {
            return try await streamTextChatRequest(
                baseURL: base,
                modelID: modelID,
                systemPrompt: system,
                userPrompt: user,
                temperature: settings.temperature,
                config: config,
                onChunk: onChunk
            )
        }

        var lastImageError = ""
        for imagePath in uniquePaths {
            let encoded = try prepareVisionImagePayloads(imagePath: imagePath)
            for imageURL in lmStudioImageURLCandidates(jpegBase64: encoded.jpegBase64, pngBase64: encoded.pngBase64) {
                do {
                    return try await streamVisionChatRequest(
                        baseURL: base,
                        modelID: modelID,
                        systemPrompt: system,
                        userPrompt: user,
                        temperature: settings.temperature,
                        imageURL: imageURL,
                        config: config,
                        onChunk: onChunk
                    )
                } catch CaptionError.runtime(let message) {
                    if impliesVisionRequired(message) {
                        throw CaptionError.runtime(message)
                    }
                    if isLMStudioImagePayloadError(message) {
                        lastImageError = message
                        continue
                    }
                    throw CaptionError.runtime(message)
                }
            }
        }
        let finalMessage = lastImageError.isEmpty
            ? "Prompt refinement failed.\n\nCould not send image to LM Studio."
            : "Prompt refinement failed.\n\nDetail: \(lastImageError)"
        throw CaptionError.runtime(finalMessage)
    }

    private func streamTextChatRequest(
        baseURL: URL,
        modelID: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        config: AppConfig,
        onChunk: @escaping @MainActor (String) -> Void,
        retriedModelLoad: Bool = false
    ) async throws -> String {
        let url = baseURL.appending(path: "chat/completions")
        let body: [String: Any] = [
            "model": modelID,
            "stream": true,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
        ]
        return try await performStreamingChatRequest(
            url: url,
            body: body,
            baseURL: baseURL,
            modelID: modelID,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: temperature,
            imageURL: nil,
            config: config,
            onChunk: onChunk,
            retriedModelLoad: retriedModelLoad
        )
    }

    private func streamVisionChatRequest(
        baseURL: URL,
        modelID: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        imageURL: String,
        config: AppConfig,
        onChunk: @escaping @MainActor (String) -> Void,
        retriedModelLoad: Bool = false
    ) async throws -> String {
        let url = baseURL.appending(path: "chat/completions")
        let body: [String: Any] = [
            "model": modelID,
            "stream": true,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": userPrompt],
                        ["type": "image_url", "image_url": ["url": imageURL, "detail": "auto"]],
                    ],
                ],
            ],
        ]
        return try await performStreamingChatRequest(
            url: url,
            body: body,
            baseURL: baseURL,
            modelID: modelID,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: temperature,
            imageURL: imageURL,
            config: config,
            onChunk: onChunk,
            retriedModelLoad: retriedModelLoad
        )
    }

    private func performStreamingChatRequest(
        url: URL,
        body: [String: Any],
        baseURL: URL,
        modelID: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        imageURL: String?,
        config: AppConfig,
        onChunk: @escaping @MainActor (String) -> Void,
        retriedModelLoad: Bool
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        SessionViewLog.logLMStudioCall(method: "POST \(url.path)", payload: body, config: config)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CaptionError.runtime("No response from LM Studio.")
        }
        if http.statusCode == 400 || http.statusCode == 422 || !(200 ..< 300).contains(http.statusCode) {
            let msg = try await readErrorBody(from: bytes)
            SessionViewLog.logLMStudioError("Chat HTTP \(http.statusCode)", detail: msg, config: config)
            if impliesVisionRequired(msg) {
                throw CaptionError.runtime(Self.visionRequiredMessage)
            }
            if imageURL != nil {
                return try await retryCaptionAfterModelLoadIfNeeded(
                    errorMessage: msg,
                    baseURL: baseURL,
                    modelID: modelID,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    temperature: temperature,
                    imageURL: imageURL!,
                    config: config,
                    onChunk: onChunk,
                    retriedModelLoad: retriedModelLoad
                ) {
                    throw CaptionError.runtime("Prompt refinement failed.\n\nDetail: \(msg)")
                }
            }
            if retriedModelLoad || !isNoModelLoadedMessage(msg) {
                throw CaptionError.runtime("Prompt refinement failed.\n\nDetail: \(msg)")
            }
            let saved = savedModelKey(config: config)
            let reloadKey = saved.isEmpty ? modelID : saved
            try await reloadSavedCaptionModel(savedKey: reloadKey, config: config)
            if imageURL != nil {
                return try await streamVisionChatRequest(
                    baseURL: baseURL,
                    modelID: reloadKey,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    temperature: temperature,
                    imageURL: imageURL!,
                    config: config,
                    onChunk: onChunk,
                    retriedModelLoad: true
                )
            }
            return try await streamTextChatRequest(
                baseURL: baseURL,
                modelID: reloadKey,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                temperature: temperature,
                config: config,
                onChunk: onChunk,
                retriedModelLoad: true
            )
        }

        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            SessionViewLog.logLMStudioSSELine(String(payload), config: config)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any],
                  let chunk = delta["content"] as? String,
                  !chunk.isEmpty else {
                continue
            }
            accumulated += chunk
            onChunk(chunk)
        }

        let final = Self.stripThinkTags(accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
        if final.isEmpty {
            throw CaptionError.runtime(
                "The model returned an empty response.\n\n"
                    + "Try a different prompt or check the loaded model."
            )
        }
        SessionViewLog.logModelOutput(tag: Self.logTag, text: final, config: config)
        persistLastModelKey(modelID, config: config)
        return final
    }

    func startCaption(
        imagePath: String,
        userPromptOverride: String?,
        config: AppConfig,
        onChunk: @escaping @MainActor (String) -> Void,
        onFinished: @escaping @MainActor (Result<String, Error>) -> Void
    ) {
        cancelCaption()
        activeTask = Task {
            do {
                let caption = try await streamCaption(
                    imagePath: imagePath,
                    userPromptOverride: userPromptOverride,
                    config: config,
                    onChunk: onChunk
                )
                guard !Task.isCancelled else {
                    onFinished(.failure(CaptionError.cancelled))
                    activeTask = nil
                    return
                }
                sessionState = .available
                onFinished(.success(caption))
            } catch {
                if error is CancellationError || (error as? CaptionError) == .cancelled {
                    onFinished(.failure(CaptionError.cancelled))
                } else {
                    sessionState = .unavailable
                    logCaptionFailure(error, config: config)
                    onFinished(.failure(error))
                }
            }
            activeTask = nil
        }
    }

    private func logCaptionFailure(_ error: Error, config: AppConfig) {
        if error is CancellationError || (error as? CaptionError) == .cancelled { return }
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        SessionViewLog.logLMStudioError(message, detail: nil, config: config)
    }

    // MARK: - Network

    private func networkProbe(config: AppConfig) async -> Bool {
        guard let base = apiBaseURL(host: captionHost(config: config)) else { return false }
        let modelsURL = base.appending(path: "models")
        SessionViewLog.logLMStudioCall(
            method: "GET \(modelsURL.path)",
            payload: ["url": modelsURL.absoluteString],
            config: config
        )
        do {
            let (data, response) = try await URLSession.shared.data(from: modelsURL)
            guard let http = response as? HTTPURLResponse else {
                SessionViewLog.logLMStudioError("Probe failed: no HTTP response", config: config)
                return false
            }
            logHTTPResponseData(data, status: http.statusCode, config: config)
            guard (200 ..< 300).contains(http.statusCode) else {
                SessionViewLog.logLMStudioError(
                    "Probe failed: HTTP \(http.statusCode)",
                    detail: String(data: data, encoding: .utf8),
                    config: config
                )
                return false
            }
            let ids = parseModelIDs(from: data)
            if !ids.isEmpty { return true }
            let saved = savedModelKey(config: config)
            return !saved.isEmpty
        } catch {
            SessionViewLog.logLMStudioError("Probe failed", detail: error.localizedDescription, config: config)
            return false
        }
    }

    private func streamCaption(
        imagePath: String,
        userPromptOverride: String?,
        config: AppConfig,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        guard let base = apiBaseURL(host: captionHost(config: config)) else {
            throw CaptionError.runtime("Invalid LM Studio host.\n\nUse a value like localhost:1234")
        }
        let settings = captionSettings(config: config)
        let wordCount = settings.maxWords
        var systemPrompt = settings.systemPrompt.replacingOccurrences(of: "{CAPTION_WORD_COUNT}", with: "\(wordCount)")
        var userPrompt: String
        if let override = userPromptOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            userPrompt = override
        } else {
            userPrompt = settings.userPrompt.replacingOccurrences(of: "{CAPTION_WORD_COUNT}", with: "\(wordCount)")
        }
        systemPrompt = AIPromptExitService.applyTextAIExit(systemPrompt, config: config)
        userPrompt = AIPromptExitService.applyTextAIExit(userPrompt, config: config)

        let modelID = try await resolveModelID(baseURL: base, config: config)
        let encoded = try prepareVisionImagePayloads(imagePath: imagePath)
        let imageURLCandidates = lmStudioImageURLCandidates(jpegBase64: encoded.jpegBase64, pngBase64: encoded.pngBase64)

        SessionViewLog.logModelInput(
            tag: Self.logTag,
            payload: [
                "system_prompt": systemPrompt,
                "user_prompt": userPrompt,
                "image_path": imagePath,
                "config": ["temperature": settings.temperature, "model": modelID],
            ],
            config: config
        )

        var lastImageError = ""
        for imageURL in imageURLCandidates {
            SessionViewLog.appendTimestampedBlock(
                header: "\(Self.logTag) image_url_candidate",
                body: SessionViewLog.sanitizeStringForLog(imageURL),
                config: config
            )
            do {
                return try await streamCaptionRequest(
                    baseURL: base,
                    modelID: modelID,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    temperature: settings.temperature,
                    imageURL: imageURL,
                    config: config,
                    onChunk: onChunk
                )
            } catch CaptionError.runtime(let message) {
                if impliesVisionRequired(message) {
                    throw CaptionError.runtime(message)
                }
                if isLMStudioImagePayloadError(message) {
                    lastImageError = message
                    SessionViewLog.logLMStudioError("Image payload rejected", detail: message, config: config)
                    continue
                }
                throw CaptionError.runtime(message)
            }
        }
        let finalMessage = lastImageError.isEmpty
            ? "Caption generation failed.\n\nCould not send image to LM Studio."
            : "Caption generation failed.\n\nDetail: \(lastImageError)"
        SessionViewLog.logLMStudioError(finalMessage, config: config)
        throw CaptionError.runtime(finalMessage)
    }

    private struct VisionImagePayloads {
        var jpegBase64: String
        var pngBase64: String
    }

    private func streamCaptionRequest(
        baseURL: URL,
        modelID: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        imageURL: String,
        config: AppConfig,
        onChunk: @escaping @MainActor (String) -> Void,
        retriedModelLoad: Bool = false
    ) async throws -> String {
        let url = baseURL.appending(path: "chat/completions")

        let body: [String: Any] = [
            "model": modelID,
            "stream": true,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": userPrompt],
                        ["type": "image_url", "image_url": ["url": imageURL, "detail": "auto"]],
                    ],
                ],
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        SessionViewLog.logLMStudioCall(
            method: "POST \(url.path)",
            payload: body,
            config: config
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            SessionViewLog.logLMStudioError("No response from LM Studio.", config: config)
            throw CaptionError.runtime("No response from LM Studio.")
        }
        if http.statusCode == 400 || http.statusCode == 422 {
            let msg = try await readErrorBody(from: bytes)
            SessionViewLog.logLMStudioError(
                "Caption HTTP \(http.statusCode)",
                detail: msg,
                config: config
            )
            if impliesVisionRequired(msg) {
                throw CaptionError.runtime(Self.visionRequiredMessage)
            }
            return try await retryCaptionAfterModelLoadIfNeeded(
                errorMessage: msg,
                baseURL: baseURL,
                modelID: modelID,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                temperature: temperature,
                imageURL: imageURL,
                config: config,
                onChunk: onChunk,
                retriedModelLoad: retriedModelLoad
            ) {
                throw CaptionError.runtime("Caption generation failed.\n\nDetail: \(msg)")
            }
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let msg = try await readErrorBody(from: bytes)
            SessionViewLog.logLMStudioError(
                "Caption HTTP \(http.statusCode)",
                detail: msg,
                config: config
            )
            return try await retryCaptionAfterModelLoadIfNeeded(
                errorMessage: msg,
                baseURL: baseURL,
                modelID: modelID,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                temperature: temperature,
                imageURL: imageURL,
                config: config,
                onChunk: onChunk,
                retriedModelLoad: retriedModelLoad
            ) {
                throw CaptionError.runtime("Caption generation failed.\n\nDetail: \(msg)")
            }
        }

        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            SessionViewLog.logLMStudioSSELine(String(payload), config: config)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any],
                  let chunk = delta["content"] as? String,
                  !chunk.isEmpty else {
                continue
            }
            accumulated += chunk
            onChunk(chunk)
        }

        let final = Self.stripThinkTags(accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
        if final.isEmpty {
            SessionViewLog.logLMStudioError("Empty caption.", config: config)
            throw CaptionError.runtime("Empty caption.")
        }
        SessionViewLog.logModelOutput(tag: Self.logTag, text: final, config: config)
        persistLastModelKey(modelID, config: config)
        return final
    }

    private func retryCaptionAfterModelLoadIfNeeded(
        errorMessage: String,
        baseURL: URL,
        modelID: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        imageURL: String,
        config: AppConfig,
        onChunk: @escaping @MainActor (String) -> Void,
        retriedModelLoad: Bool,
        onFailure: () throws -> Void
    ) async throws -> String {
        if retriedModelLoad || !isNoModelLoadedMessage(errorMessage) {
            try onFailure()
        }
        let saved = savedModelKey(config: config)
        let reloadKey = saved.isEmpty ? modelID : saved
        if reloadKey.isEmpty {
            try onFailure()
        }
        try await reloadSavedCaptionModel(savedKey: reloadKey, config: config)
        return try await streamCaptionRequest(
            baseURL: baseURL,
            modelID: reloadKey,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: temperature,
            imageURL: imageURL,
            config: config,
            onChunk: onChunk,
            retriedModelLoad: true
        )
    }

    private func resolveModelID(baseURL: URL, config: AppConfig) async throws -> String {
        let ids = try await fetchLoadedModelIDs(baseURL: baseURL, config: config)
        if let first = ids.first {
            persistLastModelKey(first, config: config)
            return first
        }
        let saved = savedModelKey(config: config)
        if saved.isEmpty {
            throw CaptionError.runtime(
                "No model is currently loaded in LMStudio.\n\n"
                    + "Please load a vision-capable model (VLM) before using AI captioning."
            )
        }
        try await reloadSavedCaptionModel(savedKey: saved, config: config)
        let idsAfterLoad = try await fetchLoadedModelIDs(baseURL: baseURL, config: config)
        if let first = idsAfterLoad.first {
            persistLastModelKey(first, config: config)
            return first
        }
        return saved
    }

    private func fetchLoadedModelIDs(baseURL: URL, config: AppConfig) async throws -> [String] {
        let modelsURL = baseURL.appending(path: "models")
        SessionViewLog.logLMStudioCall(
            method: "GET \(modelsURL.path)",
            payload: ["url": modelsURL.absoluteString],
            config: config
        )
        let (data, response) = try await URLSession.shared.data(from: modelsURL)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)
            SessionViewLog.logLMStudioError(
                "Could not contact LMStudio server at \(captionHost(config: config)).",
                detail: detail,
                config: config
            )
            throw CaptionError.runtime(
                "Could not contact LMStudio server at \(captionHost(config: config)).\n\n"
                    + "Please start LMStudio and enable the local API server."
            )
        }
        logHTTPResponseData(data, status: http.statusCode, config: config)
        return parseModelIDs(from: data)
    }

    /// `POST /api/v1/models/load` — port of Python `client.llm.model(saved_key)`.
    private func reloadSavedCaptionModel(savedKey: String, config: AppConfig) async throws {
        guard let nativeBase = nativeAPIBaseURL(host: captionHost(config: config)) else {
            throw CaptionError.runtime("Invalid LM Studio host.\n\nUse a value like localhost:1234")
        }
        let loadURL = nativeBase.appending(path: "models/load")
        let body: [String: Any] = ["model": savedKey]
        SessionViewLog.logLMStudioCall(
            method: "POST /api/v1/models/load",
            payload: body,
            config: config
        )
        var request = URLRequest(url: loadURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CaptionError.runtime(
                "Could not reload the last LM Studio caption model.\n\n"
                    + "Saved model: \(savedKey)\n\nDetail: No HTTP response."
            )
        }
        logHTTPResponseData(data, status: http.statusCode, config: config)
        guard (200 ..< 300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            SessionViewLog.logLMStudioError("Model load failed", detail: detail, config: config)
            throw CaptionError.runtime(
                "Could not reload the last LM Studio caption model.\n\n"
                    + "Saved model: \(savedKey)\n\nDetail: \(detail)"
            )
        }
        persistLastModelKey(savedKey, config: config)
    }

    private func persistLastModelKey(_ modelKey: String, config: AppConfig) {
        let trimmed = modelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if savedModelKey(config: config) == trimmed { return }
        config.updateSetting("caption_last_lm_model_key", value: trimmed)
    }

    private func isNoModelLoadedMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("no model")
            || lower.contains("no models")
            || lower.contains("not loaded")
            || lower.contains("model is not loaded")
            || lower.contains("model not found")
            || lower.contains("no llm")
    }

    // MARK: - Settings helpers

    struct CaptionSettings {
        var host: String
        var systemPrompt: String
        var userPrompt: String
        var maxWords: Int
        var temperature: Double
    }

    func captionSettings(config: AppConfig) -> CaptionSettings {
        CaptionSettings(
            host: config.string(forKey: "caption_lms_host", default: "localhost:1234"),
            systemPrompt: config.string(
                forKey: "caption_system_prompt",
                default: "Analyze the provided image thoroughly and write a highly detailed, visually rich, {CAPTION_WORD_COUNT}-word caption."
            ),
            userPrompt: config.string(
                forKey: "caption_user_prompt",
                default: "Carefully study the attached image and provide a comprehensive, vivid, and nuanced {CAPTION_WORD_COUNT}-word caption."
            ),
            maxWords: config.int(forKey: "caption_max_words", default: 200),
            temperature: config.double(forKey: "caption_temperature", default: 0.7)
        )
    }

    func captionHost(config: AppConfig) -> String {
        captionSettings(config: config).host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func saveCaptionSettings(_ settings: CaptionSettings, config: AppConfig) {
        config.updateSetting("caption_lms_host", value: settings.host)
        config.updateSetting("caption_system_prompt", value: settings.systemPrompt)
        config.updateSetting("caption_user_prompt", value: settings.userPrompt)
        config.updateSetting("caption_max_words", value: settings.maxWords)
        config.updateSetting("caption_temperature", value: settings.temperature)
    }

    private func savedModelKey(config: AppConfig) -> String {
        config.string(forKey: "caption_last_lm_model_key").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Text processing (Python `_strip_think_tags` / `normalize_lmstudio_output_text`)

    static func stripThinkTags(_ text: String) -> String {
        var result = text
        if let firstOpen = result.range(of: "<think") {
            if let lastClose = result.range(of: "</think", options: .backwards),
               lastClose.lowerBound >= firstOpen.lowerBound,
               let endClose = result[lastClose.lowerBound...].firstIndex(of: ">") {
                result.removeSubrange(firstOpen.lowerBound ... endClose)
            }
        }
        let marker = "<channel|>"
        if let channel = result.range(of: marker, options: .backwards) {
            result.removeSubrange(result.startIndex ..< channel.upperBound)
        }
        return normalizeLMStudioOutput(result)
    }

    private static func normalizeLMStudioOutput(_ text: String) -> String {
        guard !text.isEmpty, !text.allSatisfy(\.isASCII) else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2013, 0x2014: out.append("-")
            case 0x2018, 0x2019, 0x201A, 0x201B: out.append("'")
            case 0x201C, 0x201D, 0x201E, 0x201F: out.append("\"")
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - Utilities

    private func apiBaseURL(host: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme: String
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            withScheme = trimmed
        } else {
            withScheme = "http://\(trimmed)"
        }
        guard var components = URLComponents(string: withScheme) else { return nil }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/v1"
        } else if !components.path.hasSuffix("/v1") {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1"
        }
        return components.url
    }

    private func nativeAPIBaseURL(host: String) -> URL? {
        guard let openAI = apiBaseURL(host: host),
              var components = URLComponents(url: openAI, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/api/v1"
        return components.url
    }

    private func logHTTPResponseData(_ data: Data, status: Int, config: AppConfig) {
        if let json = try? JSONSerialization.jsonObject(with: data),
           let payload = json as? [String: Any] {
            SessionViewLog.logLMStudioCall(
                method: "response HTTP \(status)",
                payload: payload,
                config: config
            )
        } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            SessionViewLog.appendTimestampedBlock(
                header: "\(Self.logTag) response HTTP \(status)",
                body: text,
                config: config
            )
        }
    }

    private func parseModelIDs(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else {
            return []
        }
        return models.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
    }

    private func parseLoadedNativeModelIDs(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        if let catalog = json["models"] as? [[String: Any]] {
            var instanceIDs: [String] = []
            for model in catalog {
                guard let instances = model["loaded_instances"] as? [[String: Any]] else { continue }
                for instance in instances {
                    if let id = instance["id"] as? String, !id.isEmpty {
                        instanceIDs.append(id)
                    }
                }
            }
            if !instanceIDs.isEmpty {
                return instanceIDs
            }
        }
        if let models = json["data"] as? [[String: Any]] {
            let loaded = models.filter { entry in
                (entry["state"] as? String)?.lowercased() == "loaded"
            }
            let ids = loaded.compactMap { entry -> String? in
                if let id = entry["id"] as? String, !id.isEmpty { return id }
                if let id = entry["instance_id"] as? String, !id.isEmpty { return id }
                return nil
            }
            if !ids.isEmpty {
                return ids
            }
        }
        return parseModelIDs(from: data)
    }

    /// LM Studio is picky about `image_url.url` — try OpenAI JPEG data URIs, then PNG, then PNG-labeled JPEG (issue #1027).
    private func lmStudioImageURLCandidates(jpegBase64: String, pngBase64: String) -> [String] {
        [
            "data:image/jpeg;base64,\(jpegBase64)",
            "data:image/png;base64,\(pngBase64)",
            "data:image/png;base64,\(jpegBase64)",
        ]
    }

    private func isLMStudioImagePayloadError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("invalid url")
            || lower.contains("base64 encoded image")
            || lower.contains("'url' field")
    }

    /// Decode via ImageIO (respects orientation), re-encode as JPEG + PNG for LM Studio vision APIs.
    private func prepareVisionImagePayloads(imagePath: String) throws -> VisionImagePayloads {
        let fileURL = URL(fileURLWithPath: imagePath)
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw CaptionError.runtime("Could not load image for captioning.")
        }
        let loadOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, loadOptions as CFDictionary) else {
            throw CaptionError.runtime("Could not load image for captioning.")
        }
        let jpegBase64 = try rasterBase64(cgImage: cgImage, uti: UTType.jpeg, quality: 0.92)
        let pngBase64 = try rasterBase64(cgImage: cgImage, uti: UTType.png, quality: 1.0)
        return VisionImagePayloads(jpegBase64: jpegBase64, pngBase64: pngBase64)
    }

    private func rasterBase64(cgImage: CGImage, uti: UTType, quality: Double) throws -> String {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            uti.identifier as CFString,
            1,
            nil
        ) else {
            throw CaptionError.runtime("Could not encode image for captioning.")
        }
        var properties: [CFString: Any] = [:]
        if uti == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptionError.runtime("Could not encode image for captioning.")
        }
        return (data as Data).base64EncodedString()
    }

    private func impliesVisionRequired(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("vision")
            || lower.contains("image input")
            || lower.contains("multimodal")
            || message.contains(Self.visionRequiredMessage)
    }

    private func readErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 32_768 { break }
        }
        return String(data: data, encoding: .utf8) ?? "HTTP error"
    }

    enum CaptionError: Error, Equatable {
        case cancelled
        case runtime(String)
    }
}

extension LmStudioCaptionService.CaptionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled"
        case .runtime(let message): return message
        }
    }
}

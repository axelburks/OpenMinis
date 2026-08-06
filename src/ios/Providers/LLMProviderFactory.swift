import Foundation

/// Shared factory for creating LLMProvider instances from a ModelEntry.
/// Used by both the agent loop (AIChatViewModel) and minis-model-use offload bridge.
@MainActor
enum LLMProviderFactory {

    enum FactoryError: Error {
        case noInstance
        case noCredentials
        case voiceOnlyProvider
    }

    /// Create an LLMProvider for the given entry, looking up its ProviderInstance and credentials.
    static func makeProvider(for entry: ModelEntry) async throws -> any LLMProvider {
        let store = ProviderConfigStore.shared
        guard let instance = store.instance(for: entry.providerInstanceId) else {
            throw FactoryError.noInstance
        }
        switch instance.providerType {
        case .anthropic:
            return makeAnthropicProvider(instance: instance, model: entry.model, entry: entry)
        case .gemini:
            return await makeGeminiProvider(instance: instance, model: entry.model, entry: entry)
        case .openAI:
            return makeOpenAIProvider(instance: instance, entry: entry)
        case .antigravity:
            return await makeAntigravityProvider(instance: instance, model: entry.model, entry: entry)
        case .openRouter:
            return makeOpenRouterProvider(instance: instance, entry: entry)
        case .openAIResponses:
            return makeOpenAIResponsesProvider(instance: instance, entry: entry)
        case .xAI:
            return makeXAIProvider(instance: instance, entry: entry)
        case .kimiCode:
            return makeKimiProvider(instance: instance, entry: entry)
        case .unsupported:
            throw FactoryError.voiceOnlyProvider
        }
    }

    @discardableResult
    static func applyAzure(_ provider: OpenAIProvider, instance: ProviderInstance) -> OpenAIProvider {
        if instance.azureMode { provider.isAzure = true }
        return provider
    }

    @discardableResult
    static func applyRequestCustomization(_ provider: OpenAIProvider, instance: ProviderInstance, entry: ModelEntry?) -> OpenAIProvider {
        if provider.extraHeaders["User-Agent"] == nil {
            provider.extraHeaders["User-Agent"] = MinisUserAgent.default
        }
        provider.requestCustomization = RequestCustomization(provider: instance, modelEntry: entry)
        return provider
    }

    @discardableResult
    static func applyRequestCustomization(_ provider: AnthropicProvider, instance: ProviderInstance, entry: ModelEntry?) -> AnthropicProvider {
        provider.requestCustomization = RequestCustomization(
            provider: instance,
            modelEntry: entry
        )
        return provider
    }

    // MARK: - Per-Provider Builders

    static func makeAnthropicProvider(
        instance: ProviderInstance,
        model: LLMModel,
        entry: ModelEntry? = nil
    ) -> AnthropicProvider {
        let customBase = instance.effectiveCustomBaseURL
        let appendV1 = instance.appendV1Suffix
        let provider: AnthropicProvider
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            // No user custom UA → send the app default (Minis/<marketing>) so the
            // SDK (which sets no UA itself) doesn't fall back to URLSession's
            // build-number default. OAuth branches below keep nil so the
            // claude-cli UA set in OAuthURLProtocol is preserved.
            provider = AnthropicProvider(apiKey: key, model: model, basePath: customBase, appendV1Suffix: appendV1)
        case .oauth:
            if let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
                provider = AnthropicProvider(manualToken: manualToken, model: model, basePath: customBase, appendV1Suffix: appendV1)
            } else {
                let iid = instance.id
                provider = AnthropicProvider(
                    oauthTokenProvider: { try await ClaudeOAuthManager.shared.validAccessToken(instanceId: iid) },
                    model: model,
                    basePath: customBase,
                    appendV1Suffix: appendV1
                )
            }
        }
        return applyRequestCustomization(provider, instance: instance, entry: entry)
    }

    static func makeGeminiProvider(instance: ProviderInstance, model: LLMModel, entry: ModelEntry? = nil) async -> GeminiProvider {
        let customBase = instance.effectiveCustomBaseURL
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            let provider = GeminiProvider(apiKey: key, model: model, customBasePath: customBase)
            provider.requestCustomization = RequestCustomization(provider: instance, modelEntry: entry)
            return provider
        case .oauth:
            if let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
                let provider = GeminiProvider(apiKey: manualToken, model: model, customBasePath: customBase)
                provider.requestCustomization = RequestCustomization(provider: instance, modelEntry: entry)
                return provider
            }
            let iid = instance.id
            if GeminiOAuthManager.shared.gcpProjectID(instanceId: iid) == nil {
                await GeminiOAuthManager.shared.discoverProjectIfNeeded(instanceId: iid)
            }
            let provider = GeminiProvider(
                oauthTokenProvider: { try await GeminiOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model,
                customBasePath: customBase
            )
            provider.gcpProjectID = GeminiOAuthManager.shared.gcpProjectID(instanceId: iid)
            provider.requestCustomization = RequestCustomization(provider: instance, modelEntry: entry)
            return provider
        }
    }

    static func makeOpenAIProvider(instance: ProviderInstance, entry: ModelEntry) -> OpenAIProvider {
        let model = entry.model
        let customBase = instance.effectiveCustomBaseURL
        let appendV1 = instance.appendV1Suffix
        // Mistral's chat-completions endpoint rejects `max_completion_tokens`
        // (newer OpenAI parameter name) and `stream_options` with HTTP 422,
        // and ALSO rejects the `reasoning: {effort: …}` body. Reuse the
        // OpenRouter `max_tokens` body builder via `useOpenRouterCompat`
        // (it switches max_tokens + drops stream_options at once) but mark
        // `isMistral` so the agent loop skips the OpenRouter thinking-param
        // auto-inject.
        let isMistral = (customBase ?? "").lowercased().contains("mistral.ai")
        func configure(_ p: OpenAIProvider) -> OpenAIProvider {
            if isMistral {
                p.useOpenRouterCompat = true
                p.isMistral = true
            }
            return p
        }
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            return applyAzure(applyRequestCustomization(configure(OpenAIProvider(apiKey: key, model: model, customBaseURL: customBase, appendV1Suffix: appendV1)), instance: instance, entry: entry), instance: instance)
        case .oauth:
            if let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
                return applyRequestCustomization(configure(OpenAIProvider(apiKey: manualToken, model: model, customBaseURL: customBase, appendV1Suffix: appendV1)), instance: instance, entry: entry)
            }
            let iid = instance.id
            let provider = OpenAIProvider(
                oauthTokenProvider: { try await CodexOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model
            )
            provider.codexAccountId = CodexOAuthManager.shared.accountId(instanceId: iid)
            provider.requestCustomization = RequestCustomization(provider: instance, modelEntry: entry)
            return provider
        }
    }

    static func makeOpenRouterProvider(instance: ProviderInstance, entry: ModelEntry) -> OpenAIProvider {
        let model = entry.model
        let key: String
        if instance.credentialType == .oauth,
           let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
            key = manualToken
        } else {
            key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
        }
        let customBase = instance.effectiveCustomBaseURL
        let provider = OpenAIProvider(apiKey: key, model: model, customBaseURL: customBase ?? "https://openrouter.ai/api", appendV1Suffix: customBase == nil)
        provider.extraHeaders = [
            "HTTP-Referer": "https://github.com/OpenMinis/OpenMinis",
            "X-Title": "Minis App",
        ]
        provider.useOpenRouterCompat = true
        return applyRequestCustomization(provider, instance: instance, entry: entry)
    }

    static func makeOpenAIResponsesProvider(instance: ProviderInstance, entry: ModelEntry) -> OpenAIProvider {
        let model = entry.model
        let customBase = instance.effectiveCustomBaseURL
        let appendV1 = instance.appendV1Suffix
        // Both credential types are valid for Responses API instances
        // (e.g. an OpenAI2 instance configured with the user's Codex
        // OAuth login). Previously this branch only loaded an API key
        // and silently produced an empty-auth request when the user had
        // OAuth-only credentials — that's the model-use "Codex model
        // call fails" case (T-model-use-codex-responses-api-34889).
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            let provider = OpenAIProvider(apiKey: key, model: model, customBaseURL: customBase, appendV1Suffix: appendV1)
            provider.forceResponsesAPI = true
            return applyAzure(applyRequestCustomization(provider, instance: instance, entry: entry), instance: instance)
        case .oauth:
            if let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
                let provider = OpenAIProvider(apiKey: manualToken, model: model, customBaseURL: customBase, appendV1Suffix: appendV1)
                provider.forceResponsesAPI = true
                return applyRequestCustomization(provider, instance: instance, entry: entry)
            }
            let iid = instance.id
            let provider = OpenAIProvider(
                oauthTokenProvider: { try await CodexOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model
            )
            provider.customBaseURL = customBase
            provider.appendV1Suffix = appendV1
            provider.forceResponsesAPI = true
            provider.codexAccountId = CodexOAuthManager.shared.accountId(instanceId: iid)
            provider.requestCustomization = RequestCustomization(provider: instance, modelEntry: entry)
            return provider
        }
    }

    /// Kimi Code / Coding Plan — OpenAI-compatible coding upstream reached with
    /// the device-code OAuth bearer. Mirrors makeXAIProvider (custom base +
    /// OAuth bearer through OpenAIProvider). See the Kimi Code OAuth design notes.
    static func makeKimiProvider(instance: ProviderInstance, entry: ModelEntry) -> OpenAIProvider {
        let model = entry.model
        let customBase = instance.effectiveCustomBaseURL ?? "https://api.kimi.com/coding"
        // The default Kimi coding base is `…/coding` WITHOUT `/v1`; the real
        // endpoints are `/coding/v1/chat/completions` and `/coding/v1/models`
        // (verified: `/coding/chat/completions` 404s, `/coding/v1/…` needs auth).
        // So append `/v1` for the default base; a user-supplied custom base keeps
        // their own appendV1 preference.
        let appendV1 = instance.effectiveCustomBaseURL == nil ? true : instance.appendV1Suffix
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            return applyRequestCustomization(OpenAIProvider(apiKey: key, model: model, customBaseURL: customBase, appendV1Suffix: appendV1), instance: instance, entry: entry)
        case .oauth:
            let iid = instance.id
            let provider = OpenAIProvider(
                oauthTokenProvider: { try await KimiOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model
            )
            provider.customBaseURL = customBase
            provider.appendV1Suffix = appendV1
            provider.requestCustomization = RequestCustomization(provider: instance, modelEntry: entry)
            return provider
        }
    }

    static func makeXAIProvider(instance: ProviderInstance, entry: ModelEntry) -> OpenAIProvider {
        let model = entry.model
        let customBase = instance.effectiveCustomBaseURL ?? "https://api.x.ai/v1"
        // Custom base ships with /v1 — never re-append.
        let appendV1 = instance.effectiveCustomBaseURL == nil ? false : instance.appendV1Suffix
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            return applyRequestCustomization(OpenAIProvider(apiKey: key, model: model, customBaseURL: customBase, appendV1Suffix: appendV1), instance: instance, entry: entry)
        case .oauth:
            if let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
                return applyRequestCustomization(OpenAIProvider(apiKey: manualToken, model: model, customBaseURL: customBase, appendV1Suffix: appendV1), instance: instance, entry: entry)
            }
            let iid = instance.id
            let provider = OpenAIProvider(
                oauthTokenProvider: { try await XAIOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model
            )
            provider.customBaseURL = customBase
            provider.appendV1Suffix = appendV1
            provider.requestCustomization = RequestCustomization(provider: instance, modelEntry: entry)
            return provider
        }
    }

    static func makeAntigravityProvider(instance: ProviderInstance, model: LLMModel, entry: ModelEntry? = nil) async -> AntigravityProvider {
        let iid = instance.id
        if AntigravityOAuthManager.shared.projectID(instanceId: iid) == nil {
            await AntigravityOAuthManager.shared.discoverProjectIfNeeded(instanceId: iid)
        }
        let provider = AntigravityProvider(
            oauthTokenProvider: { try await AntigravityOAuthManager.shared.validAccessToken(instanceId: iid) },
            model: model
        )
        provider.projectID = AntigravityOAuthManager.shared.projectID(instanceId: iid)
        if let baseURL = AntigravityOAuthManager.shared.resolvedBaseURL(instanceId: iid) {
            provider.activeBaseURL = baseURL
        }
        provider.requestCustomization = RequestCustomization(provider: instance, modelEntry: entry)
        return provider
    }
}

import Combine
import Foundation

// [Minix] Chat request-control and semantic thinking-level state.

extension AIChatViewModel {
    /// Set thinking level - persists if session exists, otherwise holds in memory.
    func setThinkingLevel(_ level: ThinkingLevel) {
        let definitionId =
            ThinkingLevelRegistry.definition(
                forLevelId: level.rawValue
            )?.definitionId
            ?? ThinkingLevelRegistry.offDefinitionId
        setThinkingDefinitionId(definitionId)
    }

    /// Set the immutable App-level thinking definition reference.
    func setThinkingDefinitionId(
        _ definitionId: String
    ) {
        let clamped =
            clampedThinkingDefinitionId(definitionId)
        if let sid = sessionId {
            var cfg =
                ProviderConfigStore.shared
                    .inferenceConfig(for: sid)
                ?? SessionInferenceConfig()
            cfg.thinkingDefinitionId = clamped
            ProviderConfigStore.shared.setInferenceConfig(
                cfg,
                for: sid
            )
        } else {
            pendingThinkingDefinitionId = clamped
        }
        if !transitionSuspended {
            objectWillChange.send()
        }
    }

    /// Semantic thinking ID inherited from the active default primary group.
    private var defaultGroupThinkingDefinitionId:
        String {
        let store = ProviderConfigStore.shared
        guard let groupId = store.defaultPrimaryGroupId,
              let group = store.group(for: groupId) else {
            return ThinkingLevelRegistry.offDefinitionId
        }
        return group.defaultThinkingDefinitionId
            ?? ThinkingLevelRegistry.offDefinitionId
    }

    /// Current thinking level for this session, clamped to the active
    /// provider/model's available option list.
    var currentThinkingLevel: ThinkingLevel {
        ThinkingLevelRegistry.nativeLevel(
            forDefinitionId:
                currentThinkingDefinitionId
        )
    }

    var currentThinkingDefinitionId: String {
        let storedId: String = {
            if let sid = sessionId,
               let cfg =
                    ProviderConfigStore.shared
                        .inferenceConfig(for: sid) {
                return cfg.thinkingDefinitionId
            }
            return pendingThinkingDefinitionId
                ?? defaultGroupThinkingDefinitionId
        }()
        return clampedThinkingDefinitionId(
            storedId
        )
    }

    var currentThinkingLevelTitle: String {
        ThinkingLevelRegistry.title(
            forDefinitionId:
                currentThinkingDefinitionId
        )
            ?? currentThinkingLevel.displayName
    }

    var availableThinkingDefinitionIds: [String] {
        availableThinkingDefinitionIds(
            for: resolveCurrentEntry()
        )
    }

    func availableThinkingDefinitionIds(
        for entry: ModelEntry?
    ) -> [String] {
        guard let entry else {
            let fallback: [ThinkingLevel] = [
                .off, .low, .medium, .high, .xhigh,
            ]
            return fallback.compactMap {
                ThinkingLevelRegistry.definition(
                    forLevelId: $0.rawValue
                )?.definitionId
            }
        }
        return Self.availableThinkingDefinitionIds(
            forModelEntry: entry
        )
    }

    static func availableThinkingDefinitionIds(
        forModelEntry entry: ModelEntry
    ) -> [String] {
        let builtInLevels = ThinkingLevel.availableLevels(
            model: entry.model
        )
        return ThinkingLevelRegistry.availableDefinitionIds(
            controls:
                entry.overrides.requestBodyControls
                ?? [],
            builtInLevels: builtInLevels
        )
    }

    static func resolvedThinkingDefinitionId(
        _ definitionId: String,
        forModelEntry entry: ModelEntry
    ) -> String {
        ThinkingLevelRegistry.resolvedDefinitionId(
            definitionId,
            availableDefinitionIds:
                availableThinkingDefinitionIds(
                    forModelEntry: entry
                )
        ) ?? ThinkingLevelRegistry.offDefinitionId
    }

    func clampedThinkingDefinitionId(
        _ definitionId: String,
        for entry: ModelEntry? = nil
    ) -> String {
        ThinkingLevelRegistry.resolvedDefinitionId(
            definitionId,
            availableDefinitionIds:
                availableThinkingDefinitionIds(
                    for: entry ?? resolveCurrentEntry()
                )
        ) ?? ThinkingLevelRegistry.offDefinitionId
    }

    func clampedThinkingLevel(
        _ level: ThinkingLevel
    ) -> ThinkingLevel {
        ThinkingLevelRegistry.nativeLevel(
            forDefinitionId:
                clampedThinkingDefinitionId(
                    ThinkingLevelRegistry.definition(
                        forLevelId: level.rawValue
                    )?.definitionId
                    ?? ThinkingLevelRegistry
                        .offDefinitionId
                )
        )
    }

    var currentRequestBodyControls:
        [RequestBodyControl] {
        resolveCurrentEntry()?
            .overrides.requestBodyControls
            ?? []
    }

    var currentRequestCustomizationEntry:
        ModelEntry? {
        resolveCurrentEntry()
    }

    var currentRequestBodyControlSessionKey:
        String? {
        sessionId ?? draftId
    }

    var currentRequestBodyControlModelKey:
        String {
        resolveCurrentEntry()?.id
            ?? selectedModel.id
    }

    func activateRuntime(
        for entry: ModelEntry,
        preferredThinkingDefinitionId: String? = nil,
        sessionKey: String? = nil
    ) {
        RequestBodyControlRuntimeStore.activateModel(
            forSessionKey:
                sessionKey
                    ?? currentRequestBodyControlSessionKey,
            modelKey: entry.id
        )

        let storedDefinitionId: String = {
            if let preferredThinkingDefinitionId {
                return preferredThinkingDefinitionId
            }
            if let sid = sessionId,
               let config =
                ProviderConfigStore.shared
                    .inferenceConfig(for: sid) {
                return config.thinkingDefinitionId
            }
            return pendingThinkingDefinitionId
                ?? defaultGroupThinkingDefinitionId
        }()
        let resolvedDefinitionId =
            Self.resolvedThinkingDefinitionId(
                storedDefinitionId,
                forModelEntry: entry
            )
        if let sid = sessionId {
            var config =
                ProviderConfigStore.shared
                    .inferenceConfig(for: sid)
                ?? SessionInferenceConfig()
            guard config.thinkingDefinitionId
                    != resolvedDefinitionId else {
                return
            }
            config.thinkingDefinitionId =
                resolvedDefinitionId
            ProviderConfigStore.shared.setInferenceConfig(
                config,
                for: sid
            )
        } else {
            guard pendingThinkingDefinitionId
                    != resolvedDefinitionId else {
                return
            }
            pendingThinkingDefinitionId =
                resolvedDefinitionId
        }
        if !transitionSuspended {
            objectWillChange.send()
        }
    }

    /// Flush pending thinking level to the store once sessionId is available.
    /// Returns `true` if a user-chosen level was written, so the caller can
    /// keep the group-default seeding from clobbering it.
    @discardableResult
    func flushPendingThinkingLevel() -> Bool {
        guard let pending =
                pendingThinkingDefinitionId,
              let sid = sessionId else {
            return false
        }
        var cfg =
            ProviderConfigStore.shared
                .inferenceConfig(for: sid)
            ?? SessionInferenceConfig()
        cfg.thinkingDefinitionId = pending
        ProviderConfigStore.shared.setInferenceConfig(
            cfg,
            for: sid
        )
        pendingThinkingDefinitionId = nil
        return true
    }
}

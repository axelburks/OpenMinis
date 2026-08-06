import XCTest

@testable import Minis

final class ThinkingLevelTests: XCTestCase {

    func testComparable() {
        XCTAssertTrue(ThinkingLevel.off < .minimal)
        XCTAssertTrue(ThinkingLevel.minimal < .low)
        XCTAssertTrue(ThinkingLevel.low < .medium)
        XCTAssertTrue(ThinkingLevel.medium < .high)
        XCTAssertTrue(ThinkingLevel.high < .xhigh)
        XCTAssertTrue(ThinkingLevel.xhigh < .max)
        XCTAssertTrue(ThinkingLevel.max < .ultra)
        XCTAssertFalse(ThinkingLevel.ultra < .off)
    }

    func testModelGroupDecodeWithUltraThinkingLevel() throws {
        let json = """
        {
            "id": "test-group",
            "name": "Test",
            "memberEntryIds": [],
            "strategy": "fallback",
            "defaultThinkingDefinitionId": "ultra"
        }
        """.data(using: .utf8)!
        let group = try JSONDecoder().decode(ModelGroup.self, from: json)
        XCTAssertEqual(group.defaultThinkingLevel, .ultra)
    }

    func testModelGroupDecodeWithUnknownThinkingLevel() throws {
        let json = """
        {
            "id": "test-group",
            "name": "Test",
            "memberEntryIds": [],
            "strategy": "fallback",
            "defaultThinkingDefinitionId": "some-future-definition"
        }
        """.data(using: .utf8)!
        let group = try JSONDecoder().decode(ModelGroup.self, from: json)
        XCTAssertEqual(
            group.defaultThinkingDefinitionId,
            "some-future-definition"
        )
        XCTAssertEqual(group.defaultThinkingLevel, .off)
    }

    func testSessionInferenceConfig_preservesDefinitionIdRoundTrip_BitsUT() throws {
        let json = """
        { "thinkingDefinitionId": "hyper-future-uuid" }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(SessionInferenceConfig.self, from: json)
        let encoded = try JSONEncoder().encode(cfg)
        let roundTripped = try JSONDecoder().decode(
            SessionInferenceConfig.self,
            from: encoded
        )

        XCTAssertEqual(
            cfg.thinkingDefinitionId,
            "hyper-future-uuid"
        )
        XCTAssertEqual(cfg.thinkingLevel, .off)
        XCTAssertEqual(
            roundTripped.thinkingDefinitionId,
            "hyper-future-uuid"
        )
    }

    func testSessionInferenceConfig_definitionIdAndNativeLevelStayConsistent_BitsUT() {
        var config = SessionInferenceConfig(
            thinkingDefinitionId:
                "missing-custom-uuid"
        )

        XCTAssertEqual(
            config.thinkingDefinitionId,
            "missing-custom-uuid"
        )
        XCTAssertFalse(config.thinkingEnabled)
        XCTAssertEqual(config.thinkingLevel, .off)

        config.thinkingLevel = .high

        XCTAssertEqual(
            config.thinkingDefinitionId,
            "high"
        )
        XCTAssertEqual(config.thinkingLevel, .high)
        XCTAssertTrue(config.thinkingEnabled)
    }

    func testOffDisablesThinkingAndIsFirstInDefaultUIOrder_BitsUT() {
        XCTAssertEqual(
            ThinkingLevelRegistry.builtInDefinitions
                .first?.definitionId,
            "off"
        )
        XCTAssertFalse(
            SessionInferenceConfig(
                thinkingDefinitionId:
                    ThinkingLevelRegistry.offDefinitionId
            ).thinkingEnabled
        )
    }

    func testModelReasoningOverrideCanForceBothDirections_BitsUT() {
        let baseOff = LLMModel(
            id: "base-off",
            displayName: "Base Off",
            provider: "Test",
            supportsReasoning: false
        )
        let baseOn = LLMModel(
            id: "base-on",
            displayName: "Base On",
            provider: "Test",
            supportsReasoning: true
        )

        XCTAssertEqual(
            ModelEntry(
                providerInstanceId: "provider",
                model: baseOff,
                overrides: ModelOverrides(
                    supportsReasoning: true
                )
            ).model.supportsReasoning,
            true
        )
        XCTAssertEqual(
            ModelEntry(
                providerInstanceId: "provider",
                model: baseOn,
                overrides: ModelOverrides(
                    supportsReasoning: false
                )
            ).model.supportsReasoning,
            false
        )
    }

    func testDefinitionAliasRenameDoesNotMutateReferences_BitsUT() throws {
        let definitionId = "custom-definition-uuid"
        let optionID = "stable-option-id"
        let control = RequestBodyControl(
            id: "thinking-control",
            title: "Thinking",
            kind: .optionGroup,
            semanticKind: .thinkingBudget,
            options: [
                RequestBodyControlOption(
                    id: optionID,
                    thinkingDefinitionId:
                        definitionId,
                    title: "Custom",
                    payloadExpressions: [
                        #"body.effort = "custom""#,
                    ]
                ),
                RequestBodyControlOption(
                    id: "high-option",
                    thinkingDefinitionId: "high",
                    title: "High"
                ),
            ]
        )
        let entry = ModelEntry(
            providerInstanceId: "provider",
            model: LLMModel(
                id: "model",
                displayName: "Model",
                provider: "Test",
                supportsReasoning: true
            ),
            overrides: ModelOverrides(
                requestBodyControls: [control]
            )
        )
        let config = ProviderConfig(
            instances: [],
            modelEntries: [entry],
            modelGroups: [
                ModelGroup(
                    name: "Group",
                    memberEntryIds: [],
                    defaultThinkingDefinitionId:
                        definitionId
                ),
            ],
            defaultPrimaryGroupId: nil,
            defaultSubGroupId: nil,
            sessionBindings: [:],
            sessionInferenceConfigs: [
                "session": SessionInferenceConfig(
                    thinkingDefinitionId:
                        definitionId
                ),
            ]
        )

        let definition = ThinkingLevelDefinition(
            definitionId: definitionId,
            levelId: "custom_old",
            title: "Custom",
            rank: 4
        )
        let renamed = ThinkingLevelDefinition(
            definitionId:
                definition.definitionId,
            levelId: "custom_new",
            title: definition.title,
            rank: definition.rank
        )
        XCTAssertEqual(
            renamed.definitionId,
            definitionId
        )
        let options = try XCTUnwrap(
            config.modelEntries.first?
                .overrides.requestBodyControls?
                .first?.options
        )
        XCTAssertEqual(options[0].id, optionID)
        XCTAssertEqual(
            options[0].thinkingDefinitionId,
            definitionId
        )
        XCTAssertEqual(
            options[1].thinkingDefinitionId,
            "high"
        )
        XCTAssertEqual(
            config.modelGroups.first?
                .defaultThinkingDefinitionId,
            definitionId
        )
        XCTAssertEqual(
            config.sessionInferenceConfigs[
                "session"
            ]?.thinkingDefinitionId,
            definitionId
        )
        XCTAssertEqual(
            config.thinkingDefinitionReferenceCount(
                definitionId
            ),
            3
        )
    }

    func testAvailableLevels_explicitCatalogCeilingAndReasoningGate_BitsUT() {
        let model = LLMModel(
            id: "gpt-5.6-sol-example",
            displayName: "GPT 5.6",
            provider: "OpenAI",
            supportsReasoning: true
        )

        XCTAssertEqual(
            ThinkingLevel.availableLevels(model: model),
            [.off, .minimal, .low, .medium, .high, .xhigh, .max]
        )
        let unsupportedModel = LLMModel(
            id: "plain-model",
            displayName: "Plain Model",
            provider: "Test",
            supportsReasoning: false
        )
        XCTAssertTrue(
            ThinkingLevel.availableLevels(
                model: unsupportedModel
            ).isEmpty
        )
    }

    func testSaveDefinitions_customDefinitionKeepsIdentityAndRank_BitsUT() {
        let original = ThinkingLevelRegistry.definitions
        defer { ThinkingLevelRegistry.saveDefinitions(original) }
        let definitionId = "custom-mid-uuid"
        var definitions = ThinkingLevelRegistry.builtInDefinitions
        definitions.insert(
            ThinkingLevelDefinition(
                definitionId: definitionId,
                levelId: "custom_mid",
                title: "Custom Mid",
                rank: 4
            ),
            at: 4
        )

        ThinkingLevelRegistry.saveDefinitions(definitions)

        XCTAssertEqual(
            ThinkingLevelRegistry.definition(
                forDefinitionId: definitionId
            )?.levelId,
            "custom_mid"
        )
        XCTAssertEqual(
            ThinkingLevelRegistry.rank(
                forDefinitionId: definitionId
            ),
            4
        )
    }

    func testMergedDefinitions_mapsSemanticAliasConflictToLocalDefinition_BitsUT() {
        let localDefinition = ThinkingLevelDefinition(
            definitionId: "local-uuid",
            levelId: "shared_alias",
            title: "Local",
            rank: 4
        )
        let incomingDefinition = ThinkingLevelDefinition(
            definitionId: "incoming-uuid",
            levelId: "shared_alias",
            title: "Incoming",
            rank: 2
        )
        let result = ThinkingLevelRegistry.mergeResult(
            local: ThinkingLevelRegistry.builtInDefinitions
                + [localDefinition],
            importing: ThinkingLevelRegistry.builtInDefinitions
                + [incomingDefinition]
        )

        XCTAssertEqual(
            result.definitionIdRemap["incoming-uuid"],
            "local-uuid"
        )
        XCTAssertFalse(
            result.definitions.contains {
                $0.definitionId == "incoming-uuid"
            }
        )
    }

    func testSortedAndResolvedDefinitions_useRankAndDanglingFallback_BitsUT() {
        let original = ThinkingLevelRegistry.definitions
        defer { ThinkingLevelRegistry.saveDefinitions(original) }
        let customId = "between-uuid"
        var definitions = ThinkingLevelRegistry.builtInDefinitions
        definitions.insert(
            ThinkingLevelDefinition(
                definitionId: customId,
                levelId: "between_low_medium",
                title: "Between",
                rank: 3
            ),
            at: 3
        )
        ThinkingLevelRegistry.saveDefinitions(definitions)
        let options = [
            RequestBodyControlOption(
                id: "medium-option",
                thinkingDefinitionId: "medium",
                title: "Medium"
            ),
            RequestBodyControlOption(
                id: "low-option",
                thinkingDefinitionId: "low",
                title: "Low"
            ),
            RequestBodyControlOption(
                id: "custom-option",
                thinkingDefinitionId: customId,
                title: "Between"
            ),
        ]

        XCTAssertEqual(
            ThinkingLevelRegistry
                .sortedThinkingOptions(options)
                .map(\.id),
            ["low-option", "custom-option", "medium-option"]
        )
        XCTAssertEqual(
            ThinkingLevelRegistry.resolvedDefinitionId(
                customId,
                availableDefinitionIds: [
                    "off", "low", "medium",
                ]
            ),
            "low"
        )
        XCTAssertEqual(
            ThinkingLevelRegistry.resolvedDefinitionId(
                "deleted-custom-uuid",
                availableDefinitionIds: [
                    "off", "low", "high",
                ]
            ),
            "off"
        )
        XCTAssertEqual(
            ThinkingLevelRegistry.nativeLevel(
                forDefinitionId: customId
            ),
            .low
        )
    }

    func testAvailableDefinitionIds_filtersDanglingAndDuplicateReferences_BitsUT() {
        let thinking = RequestBodyControl(
            title: "Thinking",
            kind: .optionGroup,
            semanticKind: .thinkingBudget,
            options: [
                RequestBodyControlOption(
                    thinkingDefinitionId: "high",
                    title: "High"
                ),
                RequestBodyControlOption(
                    thinkingDefinitionId: "low",
                    title: "Low"
                ),
                RequestBodyControlOption(
                    thinkingDefinitionId: "high",
                    title: "Duplicate"
                ),
                RequestBodyControlOption(
                    thinkingDefinitionId: "deleted-uuid",
                    title: "Deleted"
                ),
            ]
        )

        XCTAssertEqual(
            ThinkingLevelRegistry.availableDefinitionIds(
                controls: [thinking],
                builtInLevels: [.off, .medium]
            ),
            ["low", "high"]
        )
    }

    func testAgentProvider_preservesExplicitCustomLevel_BitsUT()
        async throws {
        let provider = CapturingAgentProvider()

        _ = try await provider.streamAgentMessage(
            messages: [],
            systemPrompt: nil,
            tools: [],
            maxTokens: 1_024,
            thinkingLevel: .max
        )

        XCTAssertEqual(provider.receivedLevel, .max)
    }
}

private final class CapturingAgentProvider: AgentProvider {
    let name = "Capture"
    let model = LLMModel(
        id: "gpt-5.5-example",
        displayName: "GPT 5.5",
        provider: "OpenAI",
        supportsReasoning: true
    )
    let defaultMaxTokens = 1_024
    var receivedLevel: ThinkingLevel?

    func streamAgentMessageClamped(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws
        -> AsyncThrowingStream<AgentStreamEvent, Error> {
        receivedLevel = thinkingLevel
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

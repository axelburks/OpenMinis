import Foundation
import SQLite3
import XCTest

@testable import Minis

final class ModelRequestCustomizationPersistenceTests: XCTestCase {

    func testProviderInstance_requestCustomizationRoundTripAndEffectiveValues_BitsUT() throws {
        let provider = ProviderInstance(
            id: "provider-codable",
            label: "Custom Provider",
            providerType: .openAI,
            credentialType: .apiKey,
            customRequestHeaders: [
                "  X-Test = value  ",
                "   ",
            ],
            customRequestBody: [
                "  metadata.source = \"test\"  ",
                "",
            ]
        )

        let data = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(ProviderInstance.self, from: data)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(decoded, provider)
        XCTAssertEqual(decoded.effectiveCustomRequestHeaders, ["X-Test = value"])
        XCTAssertEqual(decoded.effectiveCustomRequestBody, ["metadata.source = \"test\""])
        XCTAssertNotNil(json["customRequestHeaders"])
        XCTAssertNotNil(json["customRequestBody"])
        XCTAssertNil(json["customUserAgent"])
        XCTAssertNil(json["custom_request_headers_json"])
    }

    func testModelOverrides_requestControlsRoundTripKeepsDeletedOption_BitsUT() throws {
        let overrides = makeOverridesWithSixThinkingOptions()

        let data = try JSONEncoder().encode(overrides)
        let decoded = try JSONDecoder().decode(ModelOverrides.self, from: data)
        let control = try XCTUnwrap(decoded.requestBodyControls?.first)

        XCTAssertEqual(decoded, overrides)
        XCTAssertEqual(decoded.requestBodyControls?.count, 1)
        XCTAssertEqual(control.iconName, "brain.head.profile")
        XCTAssertEqual(control.sliderStartColorHex, "#007AFF")
        XCTAssertEqual(control.sliderEndColorHex, "#FF9500")
        XCTAssertEqual(control.options.count, 6)
        XCTAssertEqual(decoded.customRequestHeaders, ["X-Test = \"value\""])
        XCTAssertEqual(decoded.customRequestBody, ["metadata.source = \"test\""])
        XCTAssertFalse(
            control.options.contains(where: {
                $0.thinkingDefinitionId == "xhigh"
            })
        )
    }

    func testRequestControlSymbolCatalog_isPackagedAndUnknownNameFallsBack_BitsUT() {
        XCTAssertGreaterThan(RequestControlSymbols.catalog.count, 9_000)
        XCTAssertTrue(RequestControlSymbols.catalog.contains("lightbulb"))
        XCTAssertTrue(RequestControlSymbols.catalog.contains("globe"))
        XCTAssertGreaterThan(RequestControlSymbols.availableCatalog.count, 5_000)

        let control = RequestBodyControl(
            title: "Thinking",
            iconName: "not.a.real.symbol",
            kind: .optionGroup,
            semanticKind: .thinkingBudget
        )
        XCTAssertEqual(
            RequestControlSymbols.resolvedName(for: control),
            RequestControlSymbols.thinking
        )
    }

    func testProviderConfigDB_providerRequestCustomizationRoundTripUsesSingleEnvelope_BitsUT() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("provider-config.db")
        let db = try ProviderConfigDB(url: databaseURL)
        let provider = ProviderInstance(
            id: "provider-request-customization",
            label: "Custom Provider",
            providerType: .openAI,
            credentialType: .apiKey,
            customRequestHeaders: [
                "X-Test = value",
                "Authorization = {{ provider.apiKey }}",
            ],
            customRequestBody: [
                #"metadata.source = "provider""#,
                "stream = false",
            ]
        )
        let config = ProviderConfig(
            instances: [provider],
            modelEntries: [],
            modelGroups: [],
            defaultPrimaryGroupId: nil,
            defaultSubGroupId: nil,
            sessionBindings: [:]
        )

        await db.bulkReplace(from: config)
        let loaded = await db.dumpProviderConfig()
        let envelopeString = try requestCustomizationJSON(
            at: databaseURL,
            providerID: provider.id
        )
        let envelopeData = try XCTUnwrap(envelopeString.data(using: .utf8))
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: envelopeData) as? [String: Any]
        )

        let loadedProvider = try XCTUnwrap(loaded.instances.first)
        XCTAssertEqual(loaded.instances.count, 1)
        XCTAssertEqual(loadedProvider.id, provider.id)
        XCTAssertEqual(loadedProvider.label, provider.label)
        XCTAssertEqual(loadedProvider.providerType, provider.providerType)
        XCTAssertEqual(loadedProvider.credentialType, provider.credentialType)
        XCTAssertEqual(
            loadedProvider.customRequestHeaders,
            provider.customRequestHeaders
        )
        XCTAssertEqual(
            loadedProvider.customRequestBody,
            provider.customRequestBody
        )
        XCTAssertEqual(envelope["headers"] as? [String], provider.customRequestHeaders)
        XCTAssertEqual(envelope["body"] as? [String], provider.customRequestBody)
        XCTAssertEqual(Set(envelope.keys), Set(["headers", "body"]))
    }

    func testProviderConfigDB_requestControlsRoundTripKeepsDeletedOption_BitsUT() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let db = try ProviderConfigDB(url: directory.appendingPathComponent("provider-config.db"))
        let provider = ProviderInstance(
            id: "provider-test",
            label: "OpenAI",
            providerType: .openAI,
            credentialType: .apiKey
        )
        let entry = ModelEntry(
            uuid: "entry-test",
            providerInstanceId: provider.id,
            model: LLMModel(
                id: "future-openai-model",
                displayName: "Future OpenAI Model",
                provider: "OpenAI",
                supportsReasoning: true
            ),
            overrides: makeOverridesWithSixThinkingOptions()
        )
        let config = ProviderConfig(
            instances: [provider],
            modelEntries: [entry],
            modelGroups: [],
            defaultPrimaryGroupId: nil,
            defaultSubGroupId: nil,
            sessionBindings: [:]
        )

        await db.bulkReplace(from: config)
        let loaded = await db.dumpProviderConfig()

        XCTAssertEqual(loaded.modelEntries.count, 1)
        XCTAssertEqual(loaded.modelEntries.first?.overrides, entry.overrides)
        XCTAssertEqual(loaded.modelEntries.first?.overrides.requestBodyControls?.first?.options.count, 6)
        XCTAssertFalse(
            loaded.modelEntries.first?.overrides.requestBodyControls?.first?.options.contains(where: {
                $0.thinkingDefinitionId == "xhigh"
            }) ?? true
        )
    }

    @MainActor
    func testProviderConfigStore_updateModelRequestCustomizationPersistsAndPreservesOtherOverrides_BitsUT() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("provider-config.json")
        let provider = ProviderInstance(
            id: "provider-quick-request-settings",
            label: "OpenAI",
            providerType: .openAI,
            credentialType: .apiKey
        )
        let entry = ModelEntry(
            uuid: "entry-quick-request-settings",
            providerInstanceId: provider.id,
            model: LLMModel(
                id: "quick-request-model",
                displayName: "Quick Request Model",
                provider: "OpenAI"
            ),
            overrides: ModelOverrides(
                displayName: "Preserved Name",
                maxOutputTokens: 4096
            )
        )
        let config = ProviderConfig(
            instances: [provider],
            modelEntries: [entry],
            modelGroups: [],
            defaultPrimaryGroupId: nil,
            defaultSubGroupId: nil,
            sessionBindings: [:]
        )
        try JSONEncoder().encode(config).write(to: fileURL)

        let control = RequestBodyControl(
            id: "web-search",
            title: "Web Search",
            kind: .toggle,
            payloadExpressions: [
                #"tools = append(body.tools, {type: "web_search"})"#,
            ]
        )
        let store = ProviderConfigStore(fileURL: fileURL)
        XCTAssertTrue(
            store.updateModelRequestCustomization(
                entryId: entry.id,
                headers: [#"X-Test = "saved""#],
                body: ["temperature = 0.4"],
                controls: [control]
            )
        )

        let reloaded = ProviderConfigStore(fileURL: fileURL)
        let saved = try XCTUnwrap(reloaded.entry(for: entry.id))
        XCTAssertEqual(saved.overrides.displayName, "Preserved Name")
        XCTAssertEqual(saved.overrides.maxOutputTokens, 4096)
        XCTAssertEqual(saved.overrides.customRequestHeaders, [#"X-Test = "saved""#])
        XCTAssertEqual(saved.overrides.customRequestBody, ["temperature = 0.4"])
        XCTAssertEqual(saved.overrides.requestBodyControls, [control])
    }

    func testProviderConfigDB_modelGroupSemanticLevelIdRoundTrip_BitsUT() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let db = try ProviderConfigDB(
            url: directory.appendingPathComponent("provider-config.db")
        )
        let group = ModelGroup(
            id: "group-custom-level",
            name: "Custom Level Group",
            memberEntryIds: [],
            defaultThinkingDefinitionId:
                "custom-definition-uuid"
        )
        let config = ProviderConfig(
            instances: [],
            modelEntries: [],
            modelGroups: [group],
            defaultPrimaryGroupId: group.id,
            defaultSubGroupId: nil,
            sessionBindings: [:]
        )

        await db.bulkReplace(from: config)
        let loaded = await db.dumpProviderConfig()

        XCTAssertEqual(loaded.modelGroups.count, 1)
        XCTAssertEqual(
            loaded.modelGroups.first?
                .defaultThinkingDefinitionId,
            "custom-definition-uuid"
        )
    }

    @MainActor
    func testProviderShare_roundTripPreservesAllRequestCustomization_BitsUT() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalDefinitions = ThinkingLevelRegistry.definitions
        defer {
            ThinkingLevelRegistry.saveDefinitions(
                originalDefinitions,
                markSyncDirty: false
            )
        }
        let customLevelID = "shared_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "_"))"
        let customDefinitionID =
            UUID().uuidString
        var sharedDefinitions = originalDefinitions
        let mediumIndex = sharedDefinitions.firstIndex {
            $0.id == ThinkingLevel.medium.rawValue
        } ?? sharedDefinitions.endIndex
        sharedDefinitions.insert(
            ThinkingLevelDefinition(
                definitionId: customDefinitionID,
                levelId: customLevelID,
                title: "Shared Custom",
                rank: mediumIndex
            ),
            at: mediumIndex
        )
        ThinkingLevelRegistry.saveDefinitions(
            sharedDefinitions,
            markSyncDirty: false
        )

        let provider = ProviderInstance(
            id: "provider-share-source",
            label: "Shared Provider",
            providerType: .openAI,
            credentialType: .apiKey,
            customRequestHeaders: ["X-Provider = \"shared\""],
            customRequestBody: ["metadata.provider = true"]
        )
        var overrides = makeOverridesWithSixThinkingOptions()
        var control = try XCTUnwrap(overrides.requestBodyControls?.first)
        control.options.insert(
            RequestBodyControlOption(
                id: "shared-custom-option",
                thinkingDefinitionId:
                    customDefinitionID,
                title: "Shared Custom",
                payloadExpressions: [
                    #"body.reasoning_effort = "shared-custom""#,
                ]
            ),
            at: 4
        )
        overrides.requestBodyControls = [control]
        let entry = ModelEntry(
            uuid: "entry-share-source",
            providerInstanceId: provider.id,
            model: LLMModel(
                id: "shared-model",
                displayName: "Shared Model",
                provider: "OpenAI",
                modalityOverride: .textOnly,
                supportsReasoning: true
            ),
            overrides: overrides
        )
        let sourceConfig = ProviderConfig(
            instances: [provider],
            modelEntries: [entry],
            modelGroups: [],
            defaultPrimaryGroupId: nil,
            defaultSubGroupId: nil,
            sessionBindings: [:]
        )
        let sourceURL = directory.appendingPathComponent("source.json")
        try JSONEncoder().encode(sourceConfig).write(to: sourceURL)
        let sourceStore = ProviderConfigStore(fileURL: sourceURL)
        let exported = try XCTUnwrap(
            sourceStore.exportInstanceJSON(provider.id)
        )

        ThinkingLevelRegistry.saveDefinitions(
            originalDefinitions,
            markSyncDirty: false
        )
        let targetURL = directory.appendingPathComponent("target.json")
        let targetStore = ProviderConfigStore(fileURL: targetURL)
        let importedLabel = try XCTUnwrap(
            targetStore.importInstanceJSON(exported)
        )
        let importedProvider = try XCTUnwrap(
            targetStore.instances.first { $0.label == importedLabel }
        )
        let importedEntry = try XCTUnwrap(
            targetStore.entries(for: importedProvider.id).first {
                $0.baseModel.id == entry.baseModel.id
            }
        )

        XCTAssertEqual(
            importedProvider.customRequestHeaders,
            provider.customRequestHeaders
        )
        XCTAssertEqual(
            importedProvider.customRequestBody,
            provider.customRequestBody
        )
        XCTAssertEqual(importedEntry.overrides, overrides)
        XCTAssertEqual(
            ThinkingLevelRegistry.definition(
                forDefinitionId: customDefinitionID
            )?.title,
            "Shared Custom"
        )
    }

    func testSyncedThinkingLevelDefinitions_metadataIsRegistered_BitsUT() throws {
        SyncedTypesBootstrap.registerAll()

        let metadata = try XCTUnwrap(
            SyncableTypeRegistry.shared.metadata(
                for: "ThinkingLevelDefinitionsV3"
            )
        )
        let updatedAt = Date(timeIntervalSince1970: 123)
        let synced = SyncedThinkingLevelDefinitionsV3(
            definitionsJson: "[]",
            updatedAt: updatedAt
        )
        let portable = try XCTUnwrap(metadata.buildPortable(synced))

        XCTAssertEqual(
            portable.id,
            SyncRecordID(
                type: "ThinkingLevelDefinitionsV3",
                id: "thinking-level-definitions"
            )
        )
        XCTAssertEqual(portable.updatedAt, updatedAt)
        XCTAssertEqual(
            metadata.knownCloudKeys,
            Set(["definitionsJson", "updatedAt"])
        )
    }

    private func makeOverridesWithSixThinkingOptions() -> ModelOverrides {
        let levels: [ThinkingLevel] = [.off, .minimal, .low, .medium, .high, .max]
        let control = RequestBodyControl(
            id: "thinking-control",
            title: "Thinking Intensity",
            iconName: "brain.head.profile",
            kind: .optionGroup,
            semanticKind: .thinkingBudget,
            isSliderEnabled: true,
            sliderStartColorHex: "#007AFF",
            sliderEndColorHex: "#FF9500",
            options: levels.map { level in
                RequestBodyControlOption(
                    id: level.rawValue,
                    thinkingDefinitionId:
                        level.rawValue,
                    title: level.rawValue,
                    payloadExpressions: ["body.reasoning_effort = \"\(level.rawValue)\""]
                )
            }
        )
        return ModelOverrides(
            customRequestHeaders: ["X-Test = \"value\""],
            customRequestBody: ["metadata.source = \"test\""],
            requestBodyControls: [control]
        )
    }

    private func requestCustomizationJSON(at url: URL, providerID: String) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "ModelRequestCustomizationPersistenceTests", code: 1)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            database,
            "SELECT request_customization_json FROM provider_instances WHERE id = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "ModelRequestCustomizationPersistenceTests", code: 2)
        }
        sqlite3_bind_text(statement, 1, providerID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else {
            throw NSError(domain: "ModelRequestCustomizationPersistenceTests", code: 3)
        }
        return String(cString: raw)
    }
}

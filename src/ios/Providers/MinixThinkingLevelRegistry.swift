import Foundation

// [Minix] App-level semantic thinking definitions and immutable references.

struct ThinkingLevelDefinition: Codable, Hashable, Identifiable, Sendable {
    let definitionId: String
    var levelId: String
    var title: String
    var rank: Int
    var isBuiltIn: Bool = false

    var id: String { definitionId }

    init(
        definitionId: String = UUID().uuidString,
        levelId: String,
        title: String,
        rank: Int,
        isBuiltIn: Bool = false
    ) {
        self.definitionId = definitionId
        self.levelId = levelId
        self.title = title
        self.rank = rank
        self.isBuiltIn = isBuiltIn
    }
}

enum ThinkingLevelRegistry {
    private static let definitionsKey = "requestControls.thinkingLevelDefinitions.all"
    private static let definitionsUpdatedAtKey =
        "requestControls.thinkingLevelDefinitions.updatedAt"

    struct MergeResult {
        let definitions: [ThinkingLevelDefinition]
        let definitionIdRemap: [String: String]
    }

    static let offDefinitionId =
        ThinkingLevel.off.rawValue

    private static let builtInLevelOrder: [ThinkingLevel] = [
        .off, .minimal, .low, .medium,
        .high, .xhigh, .max, .ultra,
    ]

    static let builtInDefinitions:
        [ThinkingLevelDefinition] =
        builtInLevelOrder.enumerated().map {
            index,
            level in
            ThinkingLevelDefinition(
                definitionId: level.rawValue,
                levelId: level.rawValue,
                title: level.displayName,
                rank: index,
                isBuiltIn: true
            )
        }

    static var definitions: [ThinkingLevelDefinition] {
        let stored = storedDefinitions
        let merged: [ThinkingLevelDefinition]
        if stored.isEmpty {
            merged = builtInDefinitions
        } else {
            let storedByID = Dictionary(
                uniqueKeysWithValues:
                    stored.map {
                        ($0.definitionId, $0)
                    }
            )
            let missingBuiltIns =
                builtInDefinitions.filter {
                    storedByID[$0.definitionId] == nil
                }
            merged = stored + missingBuiltIns.map { def in
                ThinkingLevelDefinition(
                    definitionId: def.definitionId,
                    levelId: def.levelId,
                    title: def.title,
                    rank: (stored.map(\.rank).max() ?? -1) + 1,
                    isBuiltIn: true
                )
            }
        }
        return merged.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.definitionId < $1.definitionId
        }
    }

    static var customDefinitions: [ThinkingLevelDefinition] {
        get { definitions.filter { !$0.isBuiltIn } }
        set {
            saveDefinitions(builtInDefinitions + newValue)
        }
    }

    private static var storedDefinitions: [ThinkingLevelDefinition] {
        guard let data = UserDefaults.standard.data(forKey: definitionsKey),
              let decoded = try? JSONDecoder().decode([ThinkingLevelDefinition].self, from: data) else {
            return []
        }
        return cleanedDefinitions(decoded)
    }

    static var updatedAt: Date {
        Date(
            timeIntervalSince1970:
                UserDefaults.standard.double(
                    forKey: definitionsUpdatedAtKey
                )
        )
    }

    static func saveDefinitions(
        _ definitions: [ThinkingLevelDefinition],
        updatedAt: Date = Date(),
        markSyncDirty: Bool = true
    ) {
        let cleaned = cleanedDefinitions(definitions).enumerated().map { index, def in
            ThinkingLevelDefinition(
                definitionId: def.definitionId,
                levelId: def.levelId,
                title: def.title,
                rank: index,
                isBuiltIn:
                    builtInDefinitions.contains(
                        where: {
                            $0.definitionId
                                == def.definitionId
                        }
                    )
            )
        }
        if let data = try? JSONEncoder().encode(cleaned) {
            UserDefaults.standard.set(data, forKey: definitionsKey)
            UserDefaults.standard.set(
                updatedAt.timeIntervalSince1970,
                forKey: definitionsUpdatedAtKey
            )
            if markSyncDirty {
                Task {
                    await ChatStore.shared.markDirty(
                        recordType: "ThinkingLevelDefinitionsV3",
                        recordId: "thinking-level-definitions"
                    )
                }
            }
        }
    }

    static func mergedDefinitions(
        local: [ThinkingLevelDefinition],
        importing incoming: [ThinkingLevelDefinition]
    ) -> [ThinkingLevelDefinition] {
        mergeResult(
            local: local,
            importing: incoming
        ).definitions
    }

    static func mergeResult(
        local: [ThinkingLevelDefinition],
        importing incoming: [ThinkingLevelDefinition]
    ) -> MergeResult {
        var merged = cleanedDefinitions(local)
        let incoming = cleanedDefinitions(incoming).sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.definitionId < $1.definitionId
        }
        var mergedIds = Set(merged.map(\.definitionId))
        var remap: [String: String] = [:]
        for (index, definition) in incoming.enumerated() {
            if mergedIds.contains(definition.definitionId) {
                remap[definition.definitionId] =
                    definition.definitionId
                continue
            }
            if let semanticMatch = merged.first(
                where: {
                    $0.levelId == definition.levelId
                }
            ) {
                remap[definition.definitionId] =
                    semanticMatch.definitionId
                continue
            }
            let followingId = incoming
                .dropFirst(index + 1)
                .compactMap { candidate in
                    remap[candidate.definitionId]
                        ?? (mergedIds.contains(
                            candidate.definitionId
                        )
                            ? candidate.definitionId
                            : nil)
                }
                .first
            let precedingId = incoming[..<index]
                .reversed()
                .compactMap { candidate in
                    remap[candidate.definitionId]
                        ?? (mergedIds.contains(
                            candidate.definitionId
                        )
                            ? candidate.definitionId
                            : nil)
                }
                .first
            if let followingId,
               let insertionIndex = merged.firstIndex(
                   where: {
                       $0.definitionId
                           == followingId
                   }
               ) {
                merged.insert(definition, at: insertionIndex)
            } else if let precedingId,
                let precedingIndex = merged.firstIndex(
                    where: {
                        $0.definitionId
                            == precedingId
                    }
                ) {
                merged.insert(
                    definition,
                    at: precedingIndex + 1
                )
            } else {
                merged.append(definition)
            }
            mergedIds.insert(definition.definitionId)
            remap[definition.definitionId] =
                definition.definitionId
        }
        return MergeResult(
            definitions:
                merged.enumerated().map {
                    index,
                    definition in
                    ThinkingLevelDefinition(
                        definitionId:
                            definition.definitionId,
                        levelId:
                            definition.levelId,
                        title: definition.title,
                        rank: index,
                        isBuiltIn:
                            definition.isBuiltIn
                    )
                },
            definitionIdRemap: remap
        )
    }

    private static func cleanedDefinitions(_ raw: [ThinkingLevelDefinition]) -> [ThinkingLevelDefinition] {
        var seenDefinitionIds = Set<String>()
        var seenLevelIds = Set<String>()
        return raw.compactMap { def in
            let definitionId = def.definitionId
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            let levelId = normalizedLevelId(
                def.levelId
            )
            guard !definitionId.isEmpty,
                  !levelId.isEmpty,
                  seenDefinitionIds.insert(
                    definitionId
                  ).inserted,
                  seenLevelIds.insert(levelId)
                    .inserted
            else {
                return nil
            }
            let builtIn =
                builtInDefinitions.first {
                    $0.definitionId == definitionId
                }
            let fallback = builtIn?.title ?? levelId
            return ThinkingLevelDefinition(
                definitionId: definitionId,
                levelId:
                    builtIn?.levelId ?? levelId,
                title: builtIn?.title ?? (def.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : def.title),
                rank: def.rank,
                isBuiltIn: builtIn != nil
            )
        }
    }

    static func normalizedLevelId(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9_]"#, with: "_", options: .regularExpression)
    }

    static func definition(
        forDefinitionId definitionId: String?
    ) -> ThinkingLevelDefinition? {
        guard let definitionId else { return nil }
        return definitions.first {
            $0.definitionId == definitionId
        }
    }

    static func definition(
        forLevelId rawLevelId: String?
    ) -> ThinkingLevelDefinition? {
        guard let rawLevelId else { return nil }
        let levelId = normalizedLevelId(rawLevelId)
        return definitions.first {
            $0.levelId == levelId
        }
    }

    static func rank(
        forDefinitionId definitionId: String?
    ) -> Int {
        definition(
            forDefinitionId: definitionId
        )?.rank ?? Int.max
    }

    static func title(
        forDefinitionId definitionId: String?
    ) -> String? {
        definition(
            forDefinitionId: definitionId
        )?.title
    }

    static func sortedThinkingOptions(_ options: [RequestBodyControlOption]) -> [RequestBodyControlOption] {
        options.sorted {
            let lhsRank = rank(
                forDefinitionId:
                    $0.thinkingDefinitionId
            )
            let rhsRank = rank(
                forDefinitionId:
                    $1.thinkingDefinitionId
            )
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    static func resolvedDefinitionId(
        _ requestedDefinitionId: String,
        availableDefinitionIds: [String]
    ) -> String? {
        let available = availableDefinitionIds
        guard !available.isEmpty else { return nil }

        if available.contains(requestedDefinitionId) {
            return requestedDefinitionId
        }
        guard let requestedDefinition = definition(
            forDefinitionId: requestedDefinitionId
        ) else {
            return available.contains(offDefinitionId)
                ? offDefinitionId
                : available.first
        }

        let lowerOrEqual =
            available.compactMap {
                definitionId
                    -> ThinkingLevelDefinition? in
            guard let definition = definition(
                forDefinitionId: definitionId
            ),
                  definition.rank <= requestedDefinition.rank else {
                return nil
            }
            return definition
        }.max {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.definitionId < $1.definitionId
        }
        if let lowerOrEqual {
            return lowerOrEqual.definitionId
        }
        return available.contains(offDefinitionId)
            ? offDefinitionId
            : available.first
    }

    static func nativeLevel(
        forDefinitionId definitionId: String
    ) -> ThinkingLevel {
        guard let definition = definition(
            forDefinitionId: definitionId
        ) else {
            return .off
        }
        if definition.isBuiltIn,
           let builtIn = ThinkingLevel.builtInLevel(
               id: definition.levelId
           ) {
            return builtIn
        }
        let builtIns = definitions.filter {
            $0.isBuiltIn && $0.rank <= definition.rank
        }
        guard let nearest = builtIns.max(by: { $0.rank < $1.rank }) else {
            return .off
        }
        return ThinkingLevel.builtInLevel(
            id: nearest.levelId
        ) ?? .off
    }

    static func availableDefinitionIds(
        controls: [RequestBodyControl],
        builtInLevels: [ThinkingLevel]
    ) -> [String] {
        guard let thinkingControl = controls.first(where: {
            $0.isEnabled && $0.semanticKind == .thinkingBudget
        }) else {
            return builtInLevels.compactMap {
                definition(
                    forLevelId: $0.rawValue
                )?.definitionId
            }
        }
        var seen = Set<String>()
        return sortedThinkingOptions(thinkingControl.options).compactMap { option in
            guard let definitionId =
                    option.thinkingDefinitionId,
                  definition(
                    forDefinitionId: definitionId
                  ) != nil,
                  seen.insert(definitionId).inserted else {
                return nil
            }
            return definitionId
        }
    }

    static func option(
        forDefinitionId requestedDefinitionId: String,
        in control: RequestBodyControl
    ) -> RequestBodyControlOption? {
        let options = sortedThinkingOptions(control.options)
        let availableDefinitionIds: [String] =
            options.compactMap { option in
                guard let definitionId =
                        option.thinkingDefinitionId,
                      definition(
                        forDefinitionId:
                            definitionId
                      ) != nil else {
                    return nil
                }
                return definitionId
            }
        guard let resolvedId = resolvedDefinitionId(
            requestedDefinitionId,
            availableDefinitionIds:
                availableDefinitionIds
        ) else {
            return nil
        }
        return options.first {
            $0.thinkingDefinitionId == resolvedId
        }
    }
}

extension ProviderConfig {
    func thinkingDefinitionReferenceCount(
        _ definitionId: String
    ) -> Int {
        let modelReferences = modelEntries.reduce(0) {
            count,
            entry in
            count
                + (entry.overrides
                    .requestBodyControls ?? [])
                    .reduce(0) { controlCount, control in
                        controlCount
                            + control.options.filter {
                                $0.thinkingDefinitionId
                                    == definitionId
                            }.count
                    }
        }
        let groupReferences = modelGroups.filter {
            $0.defaultThinkingDefinitionId
                == definitionId
        }.count
        let sessionReferences =
            sessionInferenceConfigs.values.filter {
                $0.thinkingDefinitionId
                    == definitionId
            }.count
        return modelReferences + groupReferences
            + sessionReferences
    }
}

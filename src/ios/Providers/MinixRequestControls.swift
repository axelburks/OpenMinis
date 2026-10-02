import Foundation
import UIKit

// [Minix] Request-control models, defaults, runtime state, and request orchestration.

// MARK: - Request Customization

struct RequestBodyControlOption: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var thinkingDefinitionId: String?
    var title: String
    var payloadExpressions: [String]

    init(
        id: String = UUID().uuidString,
        thinkingDefinitionId: String? = nil,
        title: String,
        payloadExpressions: [String] = []
    ) {
        self.id = id
        self.thinkingDefinitionId =
            thinkingDefinitionId
        self.title = title
        self.payloadExpressions = payloadExpressions
    }
}

struct RequestBodyControl: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case toggle
        case optionGroup
    }

    enum SemanticKind: String, Codable, Sendable {
        case thinkingBudget
    }

    var id: String
    var title: String
    var iconName: String?
    var kind: Kind
    var semanticKind: SemanticKind?
    var isEnabled: Bool
    var defaultIsActive: Bool
    var defaultOptionID: String?
    var isSliderEnabled: Bool
    var sliderStartColorHex: String?
    var sliderEndColorHex: String?
    var payloadExpressions: [String]
    var options: [RequestBodyControlOption]

    init(
        id: String = UUID().uuidString,
        title: String,
        iconName: String? = nil,
        kind: Kind,
        semanticKind: SemanticKind? = nil,
        isEnabled: Bool = true,
        defaultIsActive: Bool = false,
        defaultOptionID: String? = nil,
        isSliderEnabled: Bool = false,
        sliderStartColorHex: String? = nil,
        sliderEndColorHex: String? = nil,
        payloadExpressions: [String] = [],
        options: [RequestBodyControlOption] = []
    ) {
        self.id = id
        self.title = title
        self.iconName = iconName
        self.kind = kind
        self.semanticKind = semanticKind
        self.isEnabled = isEnabled
        self.defaultIsActive = defaultIsActive
        self.defaultOptionID = defaultOptionID
        self.isSliderEnabled = isSliderEnabled
        self.sliderStartColorHex = sliderStartColorHex
        self.sliderEndColorHex = sliderEndColorHex
        self.payloadExpressions = payloadExpressions
        self.options = options
    }
}

enum RequestControlSymbols {
    // These defaults all exist on the app's minimum supported iOS version.
    static let thinking = "lightbulb"
    static let toggle = "switch.2"
    static let optionGroup = "list.bullet"
    static let slider = "slider.horizontal.3"

    // SF Symbols has no public API for enumerating names. The checked-in
    // catalog is generated from Apple's SF Symbols metadata, then filtered
    // through UIImage at runtime for the current OS.
    private static let fallbackCatalog = [
        "lightbulb", "lightbulb.fill", "brain", "brain.head.profile",
        "sparkles", "wand.and.stars", "bolt", "bolt.fill", "flame",
        "switch.2", "power", "button.programmable", "togglepower",
        "list.bullet", "list.number", "list.star", "line.3.horizontal",
        "slider.horizontal.3", "dial.medium", "gauge.medium", "thermometer.medium",
        "circle", "circle.fill", "square", "square.fill", "diamond", "diamond.fill",
        "star", "star.fill", "heart", "heart.fill", "bookmark", "bookmark.fill",
        "flag", "flag.fill", "tag", "tag.fill", "pin", "pin.fill",
        "checkmark", "checkmark.circle", "checkmark.circle.fill",
        "xmark", "xmark.circle", "plus", "plus.circle", "minus", "minus.circle",
        "exclamationmark.triangle", "questionmark.circle", "info.circle",
        "gearshape", "gearshape.fill", "wrench.and.screwdriver", "hammer",
        "screwdriver", "ellipsis", "ellipsis.circle", "ellipsis.rectangle",
        "magnifyingglass", "doc", "doc.text", "doc.on.doc", "folder",
        "tray", "archivebox", "shippingbox", "externaldrive", "internaldrive",
        "arrow.up", "arrow.down", "arrow.left", "arrow.right",
        "arrow.clockwise", "arrow.counterclockwise", "arrow.triangle.2.circlepath",
        "chevron.up", "chevron.down", "chevron.left", "chevron.right",
        "play", "pause", "stop", "record.circle", "forward", "backward",
        "speaker.wave.2", "mic", "headphones", "music.note", "waveform",
        "camera", "photo", "film", "video", "viewfinder",
        "person", "person.2", "person.3", "person.crop.circle", "figure.walk",
        "hand.raised", "hand.thumbsup", "eye", "eye.slash", "face.smiling",
        "bubble.left", "bubble.right", "message", "quote.bubble",
        "envelope", "phone", "bell", "bell.fill", "paperplane",
        "calendar", "clock", "timer", "alarm", "hourglass",
        "location", "location.fill", "map", "mappin", "safari",
        "globe", "network", "wifi", "antenna.radiowaves.left.and.right",
        "link", "paperclip", "qrcode", "barcode",
        "lock", "lock.open", "key", "key.fill", "shield", "shield.fill",
        "creditcard", "cart", "bag", "gift", "banknote",
        "house", "building.2", "car", "airplane", "bicycle", "tram",
        "cloud", "cloud.fill", "sun.max", "moon", "snowflake", "drop",
        "leaf", "tree", "mountain.2", "pawprint",
        "book", "books.vertical", "graduationcap", "pencil", "paintbrush",
        "scissors", "ruler", "paperclip", "character.cursor.ibeam",
        "terminal", "chevron.left.forwardslash.chevron.right", "curlybraces",
        "cpu", "memorychip", "server.rack", "desktopcomputer", "laptopcomputer",
        "iphone", "ipad", "applewatch", "keyboard", "display",
        "app", "square.grid.2x2", "square.grid.3x3", "rectangle.grid.1x2",
        "chart.bar", "chart.line.uptrend.xyaxis", "chart.pie", "waveform.path.ecg",
        "function", "sum", "percent", "number", "textformat",
        "scope", "target", "dot.scope", "command", "option", "control",
    ]

    static let catalog: [String] = {
        guard let url = Bundle.main.url(
            forResource: "MinixRequestControlSFSymbolCatalog",
            withExtension: "txt"
        ),
        let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return fallbackCatalog
        }
        return contents.split(whereSeparator: \.isNewline).map(String.init)
    }()

    static let availableCatalog: [String] = Array(Set(catalog))
        .filter(isAvailable)
        .sorted()

    static func resolvedName(for control: RequestBodyControl) -> String {
        if control.semanticKind == .thinkingBudget {
            return resolved(preferred: control.iconName, fallbacks: [thinking, "brain"])
        }
        switch control.kind {
        case .toggle:
            return resolved(preferred: control.iconName, fallbacks: [toggle, "power"])
        case .optionGroup:
            return resolved(
                preferred: control.iconName,
                fallbacks: control.isSliderEnabled
                    ? [slider, optionGroup]
                    : [optionGroup, slider]
            )
        }
    }

    static func resolved(
        preferred: String?,
        fallbacks: [String]
    ) -> String {
        let candidates = [preferred].compactMap { $0 } + fallbacks + ["circle"]
        return candidates.first { UIImage(systemName: $0) != nil } ?? "circle"
    }

    static func isAvailable(_ name: String) -> Bool {
        UIImage(systemName: name) != nil
    }
}

struct RequestBodyControlState: Codable, Hashable, Sendable {
    var toggleValuesByControlID: [String: Bool] = [:]
    var selectedOptionIDsByControlID: [String: String] = [:]
}

struct RequestBodyControlRuntimeSnapshot:
    Codable,
    Hashable,
    Sendable {
    var activeModelKey: String
    var state: RequestBodyControlState
}

enum RequestBodyControlDefaults {
    static func thinkingOptionGroup(for instance: ProviderInstance?) -> RequestBodyControl {
        let levels = latestTemplateLevels(
            providerType: instance?.providerType
        )
        return RequestBodyControl(
            title: String(localized: "Thinking Intensity"),
            iconName: RequestControlSymbols.thinking,
            kind: .optionGroup,
            semanticKind: .thinkingBudget,
            defaultOptionID: nil,
            isSliderEnabled: true,
            options: levels.map { level in
                let definition =
                    ThinkingLevelRegistry.definition(
                        forLevelId: level.rawValue
                    )
                return RequestBodyControlOption(
                    id: definition?.definitionId
                        ?? level.rawValue,
                    thinkingDefinitionId:
                        definition?.definitionId,
                    title: level.displayName,
                    payloadExpressions: thinkingExpressions(
                        for: instance,
                        level: level
                    )
                )
            }
        )
    }

    private static func latestTemplateLevels(
        providerType: ProviderType?
    ) -> [ThinkingLevel] {
        switch providerType {
        case .openAI, .openAIResponses, .kimiCode, .openRouter, .githubCopilot:
            return [.off, .minimal, .low, .medium, .high, .xhigh, .max]
        case .xAI:
            return [.off, .low, .medium, .high]
        case .anthropic:
            return [.off, .low, .medium, .high, .xhigh, .max]
        case .gemini, .antigravity:
            return [.minimal, .low, .medium, .high]
        case .unsupported, .none:
            return [.off, .low, .medium, .high, .xhigh]
        }
    }

    static func thinkingExpressions(
        for instance: ProviderInstance?,
        level: ThinkingLevel
    ) -> [String] {
        // [Minix] Match LLMProviderFactory routing: first-party OpenAI OAuth
        // uses Responses even though its persisted provider type is openAI.
        let usesResponsesAPI =
            instance?.providerType == .openAIResponses
            || (
                instance?.providerType == .openAI
                    && instance?.credentialType == .oauth
                    && instance?.effectiveCustomBaseURL == nil
            )
        return thinkingExpressions(
            providerType: instance?.providerType,
            usesResponsesAPI: usesResponsesAPI,
            level: level
        )
    }

    static func thinkingExpressions(
        for definition: ThinkingLevelDefinition,
        provider instance: ProviderInstance?
    ) -> [String] {
        guard let level = ThinkingLevel.builtInLevel(
            id: definition.levelId
        ) else {
            return []
        }
        return thinkingExpressions(for: instance, level: level)
    }

    static func thinkingExpressions(
        providerType: ProviderType?,
        usesResponsesAPI: Bool = false,
        level: ThinkingLevel
    ) -> [String] {
        if usesResponsesAPI {
            return [#"body.reasoning = {effort: "\#(reasoningEffort(for: level))", summary: "auto"}"#]
        }
        switch providerType {
        case .openAIResponses:
            return [#"body.reasoning = {effort: "\#(reasoningEffort(for: level))", summary: "auto"}"#]
        case .openRouter:
            return [#"body.reasoning.effort = "\#(reasoningEffort(for: level))""#]
        case .anthropic:
            if level == .off {
                return [#"body.thinking = {type: "disabled"}"#]
            }
            return [
                #"body.thinking = {type: "adaptive", display: "summarized"}"#,
                #"body.output_config.effort = "\#(anthropicEffort(for: level))""#,
            ]
        case .gemini, .antigravity:
            return [#"body.generationConfig.thinkingConfig = {thinkingLevel: "\#(geminiEffort(for: level))", includeThoughts: true}"#]
        default:
            return [#"body.reasoning_effort = "\#(reasoningEffort(for: level))""#]
        }
    }

    private static func reasoningEffort(for level: ThinkingLevel) -> String {
        level == .off ? "none" : level.rawValue
    }

    private static func anthropicEffort(for level: ThinkingLevel) -> String {
        switch level {
        case .off, .minimal, .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh, .max, .ultra: return "max"
        }
    }

    private static func geminiEffort(for level: ThinkingLevel) -> String {
        switch level {
        case .off, .minimal: return "minimal"
        case .low: return "low"
        case .medium: return "medium"
        case .high, .xhigh, .max, .ultra: return "high"
        }
    }

    static func containsThinkingControl(_ controls: [RequestBodyControl]) -> Bool {
        controls.contains {
            $0.isEnabled && $0.semanticKind == .thinkingBudget
        }
    }
}

enum RequestCustomizationRuntime {
    @TaskLocal static var sessionId: String?
    @TaskLocal static var thinkingDefinitionId:
        String?
    @TaskLocal static var usesConversationRequestControlState =
        false
}

enum RequestCustomizationExpression {
    enum Target {
        case header
        case body
        case control
    }

    struct ValidationIssue: Equatable {
        let line: Int
        let message: String
    }

    struct Context {
        let provider: ProviderInstance
        let model: LLMModel
        let apiKey: String?
        let sessionId: String?
        let headers: [String: String]
        let body: [String: Any]
    }

    static func validationIssues(
        _ expressions: [String],
        target: Target
    ) -> [ValidationIssue] {
        let minixTarget: MinixRequestExpression.Target
        switch target {
        case .header: minixTarget = .header
        case .body: minixTarget = .body
        case .control: minixTarget = .control
        }
        return MinixRequestExpression.validationIssues(
            expressions,
            target: minixTarget
        ).map {
            ValidationIssue(line: $0.line, message: $0.message)
        }
    }

    static func applyHeaderExpressions(
        _ expressions: [String],
        to headers: inout [String: String],
        context: Context
    ) throws {
        try MinixRequestExpression.applyHeaderExpressions(
            expressions,
            to: &headers,
            context: context
        )
    }

    static func parseBodyExpressions(
        _ expressions: [String],
        context: Context
    ) throws -> [String: Any] {
        try MinixRequestExpression.parseBodyExpressions(
            expressions,
            context: context
        )
    }

    static func applyControlExpressions(
        _ expressions: [String],
        to body: inout [String: Any],
        headers: inout [String: String],
        context: Context
    ) throws {
        try MinixRequestExpression.applyControlExpressions(
            expressions,
            to: &body,
            headers: &headers,
            context: context
        )
    }

    static func merge(
        _ base: [String: Any],
        with overlay: [String: Any]
    ) -> [String: Any] {
        MinixRequestExpression.merge(base, with: overlay)
    }

    static func evaluateTemplate(
        _ raw: String,
        context: Context
    ) throws -> Any {
        try MinixRequestExpression.evaluateTemplate(
            raw,
            context: context
        )
    }
}

struct RequestCustomization {
    let provider: ProviderInstance
    let modelEntry: ModelEntry?

    var modelControls: [RequestBodyControl] {
        modelEntry?.overrides.requestBodyControls ?? []
    }

    var disablesBuiltInThinkingInjection: Bool {
        RequestBodyControlDefaults.containsThinkingControl(modelControls)
    }

    var referencesProviderAPIKey: Bool {
        let controlExpressions =
            modelControls.flatMap { control in
                control.payloadExpressions
                    + control.options.flatMap(
                        \.payloadExpressions
                    )
            }
        let expressions =
            provider.effectiveCustomRequestHeaders
            + provider.effectiveCustomRequestBody
            + (modelEntry?.overrides
                .customRequestHeaders ?? [])
            + (modelEntry?.overrides
                .customRequestBody ?? [])
            + controlExpressions
        return expressions.contains { expression in
            expression.range(
                of:
                    #"provider\s*(?:\.\s*apiKey|\[\s*["']apiKey["']\s*\])"#,
                options: .regularExpression
            ) != nil
        }
    }

    static func providerHeadersForModelList(provider: ProviderInstance, apiKey: String?, initialHeaders: [String: String]) -> [String: String] {
        var headers = initialHeaders
        let context = RequestCustomizationExpression.Context(
            provider: provider,
            model: LLMModel(id: "", displayName: "", provider: provider.providerType.displayName),
            apiKey: apiKey,
            sessionId: nil,
            headers: headers,
            body: [:]
        )
        try? RequestCustomizationExpression.applyHeaderExpressions(
            provider.effectiveCustomRequestHeaders,
            to: &headers,
            context: context
        )
        return headers
    }

    func apply(
        to body: inout [String: Any],
        headers: inout [String: String],
        apiKey: String?,
        includeControls: Bool = true
    ) {
        let model = modelEntry?.model ?? LLMModel(id: "", displayName: "", provider: "")
        var context = RequestCustomizationExpression.Context(
            provider: provider,
            model: model,
            apiKey: apiKey,
            sessionId: RequestCustomizationRuntime.sessionId,
            headers: headers,
            body: body
        )
        let providerHeaderLines = provider.effectiveCustomRequestHeaders
        try? RequestCustomizationExpression.applyHeaderExpressions(
            providerHeaderLines,
            to: &headers,
            context: context
        )
        context = RequestCustomizationExpression.Context(provider: provider, model: model, apiKey: apiKey, sessionId: RequestCustomizationRuntime.sessionId, headers: headers, body: body)
        let providerBodyLines = provider.effectiveCustomRequestBody
        if let overlay = try? RequestCustomizationExpression.parseBodyExpressions(providerBodyLines, context: context) {
            body = RequestCustomizationExpression.merge(body, with: overlay)
        }
        context = RequestCustomizationExpression.Context(provider: provider, model: model, apiKey: apiKey, sessionId: RequestCustomizationRuntime.sessionId, headers: headers, body: body)
        if let modelHeaders = modelEntry?.overrides.customRequestHeaders {
            try? RequestCustomizationExpression.applyHeaderExpressions(
                modelHeaders,
                to: &headers,
                context: context
            )
        }
        context = RequestCustomizationExpression.Context(provider: provider, model: model, apiKey: apiKey, sessionId: RequestCustomizationRuntime.sessionId, headers: headers, body: body)
        if let modelBody = modelEntry?.overrides.customRequestBody,
           let overlay = try? RequestCustomizationExpression.parseBodyExpressions(modelBody, context: context) {
            body = RequestCustomizationExpression.merge(body, with: overlay)
        }
        guard includeControls else { return }
        applyControls(
            modelControls,
            to: &body,
            headers: &headers,
            apiKey: apiKey,
            model: model
        )
    }

    private func applyControls(
        _ controls: [RequestBodyControl],
        to body: inout [String: Any],
        headers: inout [String: String],
        apiKey: String?,
        model: LLMModel
    ) {
        let state = RequestBodyControlRuntimeStore.state(
            forSessionKey:
                RequestCustomizationRuntime.sessionId,
            modelKey: modelEntry?.id ?? model.id,
            controls: controls,
            useConversationState:
                RequestCustomizationRuntime
                    .usesConversationRequestControlState
        )
        for control in controls where control.isEnabled {
            let lines: [String]
            switch control.kind {
            case .toggle:
                let enabled = state.toggleValuesByControlID[control.id] ?? control.defaultIsActive
                guard enabled else { continue }
                lines = control.payloadExpressions
            case .optionGroup:
                let optionID: String?
                let options = control.semanticKind == .thinkingBudget
                    ? ThinkingLevelRegistry.sortedThinkingOptions(control.options)
                    : control.options
                if control.semanticKind == .thinkingBudget,
                   let thinkingDefinitionId =
                    RequestCustomizationRuntime
                        .thinkingDefinitionId {
                    optionID = ThinkingLevelRegistry.option(
                        forDefinitionId:
                            thinkingDefinitionId,
                        in: control
                    )?.id
                } else {
                    optionID = state.selectedOptionIDsByControlID[control.id]
                        ?? control.defaultOptionID
                        ?? options.first?.id
                }
                guard let optionID,
                      let option = options.first(where: { $0.id == optionID }) else { continue }
                lines = option.payloadExpressions
            }
            let context = RequestCustomizationExpression.Context(provider: provider, model: model, apiKey: apiKey, sessionId: RequestCustomizationRuntime.sessionId, headers: headers, body: body)
            try? RequestCustomizationExpression
                .applyControlExpressions(
                    lines,
                    to: &body,
                    headers: &headers,
                    context: context
                )
        }
    }
}

enum RequestBodyControlRuntimeStore {
    private static let prefix =
        "requestBodyControls.state.session."

    static func state(
        forSessionKey sessionKey: String?,
        modelKey: String,
        controls: [RequestBodyControl],
        useConversationState: Bool = true
    ) -> RequestBodyControlState {
        guard useConversationState,
              let sessionKey,
              !sessionKey.isEmpty,
              let data = UserDefaults.standard.data(
                forKey: storageKey(
                    forSessionKey: sessionKey
                )
              ),
              let snapshot = try? JSONDecoder().decode(
                RequestBodyControlRuntimeSnapshot.self,
                from: data
              ),
              snapshot.activeModelKey == modelKey else {
            return RequestBodyControlState()
        }
        return normalized(snapshot.state, controls: controls)
    }

    static func save(
        _ state: RequestBodyControlState,
        forSessionKey sessionKey: String?,
        modelKey: String,
        controls: [RequestBodyControl]
    ) {
        guard let sessionKey, !sessionKey.isEmpty else {
            return
        }
        let snapshot = RequestBodyControlRuntimeSnapshot(
            activeModelKey: modelKey,
            state: normalized(state, controls: controls)
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(
                data,
                forKey: storageKey(
                    forSessionKey: sessionKey
                )
            )
        }
    }

    static func activateModel(
        forSessionKey sessionKey: String?,
        modelKey: String
    ) {
        guard let sessionKey, !sessionKey.isEmpty else {
            return
        }
        let key = storageKey(forSessionKey: sessionKey)
        if let data = UserDefaults.standard.data(forKey: key),
           let snapshot = try? JSONDecoder().decode(
               RequestBodyControlRuntimeSnapshot.self,
               from: data
           ),
           snapshot.activeModelKey == modelKey {
            return
        }
        let snapshot = RequestBodyControlRuntimeSnapshot(
            activeModelKey: modelKey,
            state: RequestBodyControlState()
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func migrate(
        fromSessionKey sourceSessionKey: String,
        toSessionKey destinationSessionKey: String
    ) {
        guard !sourceSessionKey.isEmpty,
              !destinationSessionKey.isEmpty,
              sourceSessionKey != destinationSessionKey else {
            return
        }
        let defaults = UserDefaults.standard
        let sourceKey = storageKey(
            forSessionKey: sourceSessionKey
        )
        let destinationKey = storageKey(
            forSessionKey: destinationSessionKey
        )
        if defaults.object(forKey: destinationKey) == nil,
           let value = defaults.object(forKey: sourceKey) {
            defaults.set(value, forKey: destinationKey)
        }
        defaults.removeObject(forKey: sourceKey)
    }

    static func storageKey(
        forSessionKey sessionKey: String
    ) -> String {
        prefix + sessionKey
    }

    private static func normalized(_ state: RequestBodyControlState, controls: [RequestBodyControl]) -> RequestBodyControlState {
        let toggleIDs = Set(controls.filter { $0.kind == .toggle }.map(\.id))
        let optionIDs = Dictionary(uniqueKeysWithValues: controls.filter { $0.kind == .optionGroup }.map { ($0.id, Set($0.options.map(\.id))) })
        return RequestBodyControlState(
            toggleValuesByControlID: state.toggleValuesByControlID.filter { toggleIDs.contains($0.key) },
            selectedOptionIDsByControlID: state.selectedOptionIDsByControlID.filter { optionIDs[$0.key]?.contains($0.value) == true }
        )
    }
}

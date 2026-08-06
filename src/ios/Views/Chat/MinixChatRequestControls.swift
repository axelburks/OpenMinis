import SwiftUI
import UIKit

struct MinixChatRequestControlsPanel: View {
    let providerName: String
    let modelName: String
    let currentThinkingDefinitionId: String
    let currentThinkingLevelTitle: String
    let availableThinkingLevels: [ThinkingLevel]
    let controls: [RequestBodyControl]
    let sessionKey: String?
    let modelKey: String
    let onSelectThinkingDefinitionId: (String) -> Void
    let onOpenModelPicker: () -> Void
    let onOpenRequestCustomization: () -> Void

    @State private var state: RequestBodyControlState
    @State private var builtInThinkingPosition: Double?
    @State private var activeSliderPositions:
        [String: Double] = [:]
    @State private var lastAnchorIndices: [String: Int] = [:]
    @State private var measuredContentHeight: CGFloat = 1

    init(
        providerName: String,
        modelName: String,
        currentThinkingDefinitionId: String,
        currentThinkingLevelTitle: String,
        availableThinkingLevels: [ThinkingLevel],
        controls: [RequestBodyControl],
        sessionKey: String?,
        modelKey: String,
        onSelectThinkingDefinitionId: @escaping (String) -> Void,
        onOpenModelPicker: @escaping () -> Void,
        onOpenRequestCustomization: @escaping () -> Void
    ) {
        self.providerName = providerName
        self.modelName = modelName
        self.currentThinkingDefinitionId =
            currentThinkingDefinitionId
        self.currentThinkingLevelTitle = currentThinkingLevelTitle
        self.availableThinkingLevels = availableThinkingLevels
        self.controls = controls
        self.sessionKey = sessionKey
        self.modelKey = modelKey
        self.onSelectThinkingDefinitionId =
            onSelectThinkingDefinitionId
        self.onOpenModelPicker = onOpenModelPicker
        self.onOpenRequestCustomization =
            onOpenRequestCustomization
        _state = State(
            initialValue: RequestBodyControlRuntimeStore.state(
                forSessionKey: sessionKey,
                modelKey: modelKey,
                controls: controls
            )
        )
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(action: onOpenModelPicker) {
                        HStack(spacing: 5) {
                            Text(providerName)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(modelName)
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.right")
                                .font(
                                    .system(
                                        size: 9,
                                        weight: .semibold
                                    )
                                )
                                .foregroundStyle(.tertiary)
                        }
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "requestControlsModelButton"
                    )
                    Button(action: onOpenRequestCustomization) {
                        Image(systemName: "gearshape")
                            .font(
                                .system(
                                    size: 13,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(localized: "Request Customization")
                    )
                    .accessibilityIdentifier(
                        "requestControlsConfigurationButton"
                    )
                }
                .padding(.horizontal, 2)

                if shouldShowBuiltInThinking {
                    thinkingSlider
                }
                if !enabledControls.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(enabledControls) { control in
                            controlRow(control)
                        }
                    }
                }
                if !shouldShowBuiltInThinking
                    && enabledControls.isEmpty {
                    Text(
                        String(
                            localized:
                                "No request controls are configured for this model."
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                guard height > 0 else { return }
                measuredContentHeight = height
            }
        }
        .frame(
            height: min(
                measuredContentHeight,
                maximumPanelHeight
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("requestControlsPanel")
    }

    private var maximumPanelHeight: CGFloat {
        min(UIScreen.main.bounds.height * 0.36, 300)
    }

    private var shouldShowBuiltInThinking: Bool {
        !availableThinkingLevels.isEmpty
            && !RequestBodyControlDefaults
                .containsThinkingControl(controls)
    }

    private var enabledControls: [RequestBodyControl] {
        controls.filter(\.isEnabled)
    }

    private var displayedControlIDs: [String] {
        (shouldShowBuiltInThinking ? ["builtInThinking"] : [])
            + enabledControls.map(\.id)
    }

    private var thinkingSlider: some View {
        let levels = availableThinkingLevels
        let selectedIndex = levels.firstIndex {
            ThinkingLevelRegistry.definition(
                forLevelId: $0.rawValue
            )?.definitionId == currentThinkingDefinitionId
        } ?? 0
        let position = Binding<Double>(
            get: {
                builtInThinkingPosition
                    ?? (
                        levels.count > 1
                            ? Double(selectedIndex)
                                / Double(levels.count - 1)
                            : 0
                    )
            },
            set: { raw in
                guard !levels.isEmpty else { return }
                builtInThinkingPosition = min(max(raw, 0), 1)
            }
        )
        let displayedIndex = min(
            max(
                Int(
                    round(
                        position.wrappedValue
                            * Double(max(levels.count - 1, 0))
                    )
                ),
                0
            ),
            max(levels.count - 1, 0)
        )
        let displayedTitle =
            levels.indices.contains(displayedIndex)
            ? levels[displayedIndex].displayName
            : currentThinkingLevelTitle
        return requestControlCard(id: "builtInThinking") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(
                        systemName: RequestControlSymbols.resolved(
                            preferred: RequestControlSymbols.thinking,
                            fallbacks: ["brain"]
                        )
                    )
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        requestControlSliderColor(
                            at: position.wrappedValue
                        )
                    )
                    .frame(width: 30, height: 30)
                    .background(
                        requestControlSliderColor(
                            at: position.wrappedValue
                        )
                        .opacity(
                            currentThinkingDefinitionId
                                == ThinkingLevelRegistry
                                    .offDefinitionId
                                ? 0.09
                                : 0.13
                        )
                    )
                    .clipShape(
                        RoundedRectangle(cornerRadius: 9)
                    )
                    .opacity(
                        currentThinkingDefinitionId
                            == ThinkingLevelRegistry
                                .offDefinitionId
                            ? 0.65
                            : 1
                    )
                    Text(String(localized: "Thinking Intensity"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    MinixRequestControlAnimatedLabel(
                        text: displayedTitle,
                        position: position.wrappedValue
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        requestControlSliderColor(
                            at: position.wrappedValue
                        )
                    )
                }
                if levels.count > 1 {
                    MinixRequestControlGradientSlider(
                        value: position,
                        anchorCount: levels.count,
                        startColor:
                            requestControlSliderColor(at: 0),
                        endColor:
                            requestControlSliderColor(at: 1),
                        onAnchorChanged: { index in
                            provideSelectionFeedbackIfNeeded(
                                controlID: "builtInThinking",
                                anchorIndex: index
                            )
                        },
                        onEditingChanged: { _ in },
                        onEditingEnded: {
                            let index = min(
                                max(
                                    Int(
                                        round(
                                            position.wrappedValue
                                                * Double(
                                                    levels.count
                                                        - 1
                                                )
                                        )
                                    ),
                                    0
                                ),
                                levels.count - 1
                            )
                            let resting =
                                Double(index)
                                / Double(levels.count - 1)
                            let definitionId =
                                ThinkingLevelRegistry.definition(
                                    forLevelId:
                                        levels[index].rawValue
                                )?.definitionId
                                ?? ThinkingLevelRegistry
                                    .offDefinitionId
                            if definitionId
                                != currentThinkingDefinitionId {
                                onSelectThinkingDefinitionId(
                                    definitionId
                                )
                            }
                            if abs(
                                resting - position.wrappedValue
                            ) > 0.000_001 {
                                withAnimation(
                                    .spring(
                                        response: 0.3,
                                        dampingFraction: 0.82
                                    )
                                ) {
                                    builtInThinkingPosition =
                                        resting
                                }
                            }
                        }
                    )
                }
            }
        }
        .onChange(of: currentThinkingDefinitionId) { _ in
            builtInThinkingPosition = nil
        }
    }

    @ViewBuilder
    private func controlRow(
        _ control: RequestBodyControl
    ) -> some View {
        switch control.kind {
        case .toggle:
            let isOn = Binding(
                get: {
                    state.toggleValuesByControlID[control.id]
                        ?? control.defaultIsActive
                },
                set: { value in
                    var next = state
                    next.toggleValuesByControlID[control.id] =
                        value
                    save(next)
                }
            )
            requestControlCard(id: control.id) {
                HStack(spacing: 10) {
                    Image(
                        systemName:
                            RequestControlSymbols.resolvedName(
                                for: control
                            )
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        isOn.wrappedValue
                            ? Color.accentColor
                            : .secondary
                    )
                    .frame(width: 30, height: 30)
                    .background(
                        (
                            isOn.wrappedValue
                                ? Color.accentColor
                                : Color.secondary
                        )
                        .opacity(isOn.wrappedValue ? 0.13 : 0.09)
                    )
                    .clipShape(
                        RoundedRectangle(cornerRadius: 9)
                    )
                    Text(control.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 10)
                    Toggle("", isOn: isOn)
                        .labelsHidden()
                        .tint(.accentColor)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(control.title)
            .accessibilityValue(
                isOn.wrappedValue
                    ? String(localized: "On")
                    : String(localized: "Off")
            )
        case .optionGroup:
            optionGroup(control)
        }
    }

    @ViewBuilder
    private func optionGroup(
        _ control: RequestBodyControl
    ) -> some View {
        let options = displayOptions(for: control)
        if control.isSliderEnabled, options.count > 1 {
            sliderOptionGroup(control, options: options)
        } else {
            menuOptionGroup(control, options: options)
        }
    }

    private func sliderOptionGroup(
        _ control: RequestBodyControl,
        options: [RequestBodyControlOption]
    ) -> some View {
        let currentPosition = sliderValue(for: control)
        let currentColor = requestControlSliderColor(
            at: currentPosition,
            startColor:
                requestControlColor(
                    from: control.sliderStartColorHex
                ) ?? requestControlSliderColor(at: 0),
            endColor:
                requestControlColor(
                    from: control.sliderEndColorHex
                ) ?? requestControlSliderColor(at: 1)
        )
        return requestControlCard(id: control.id) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    requestControlIcon(
                        RequestControlSymbols.resolvedName(
                            for: control
                        ),
                        isActive: true,
                        tint: currentColor
                    )
                    Text(control.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer()
                    MinixRequestControlAnimatedLabel(
                        text:
                            option(
                                for: control,
                                sliderValue: currentPosition
                            )?.title ?? "",
                        position: currentPosition
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(currentColor)
                }
                MinixRequestControlGradientSlider(
                    value: Binding(
                        get: { sliderValue(for: control) },
                        set: { value in
                            let clamped = min(max(value, 0), 1)
                            activeSliderPositions[
                                control.id
                            ] = clamped
                        }
                    ),
                    anchorCount: options.count,
                    startColor:
                        requestControlColor(
                            from: control.sliderStartColorHex
                        ) ?? requestControlSliderColor(at: 0),
                    endColor:
                        requestControlColor(
                            from: control.sliderEndColorHex
                        ) ?? requestControlSliderColor(at: 1),
                    onAnchorChanged: { anchorIndex in
                        provideSelectionFeedbackIfNeeded(
                            controlID: control.id,
                            anchorIndex: anchorIndex
                        )
                    },
                    onEditingChanged: { _ in },
                    onEditingEnded: {
                        let current = sliderValue(for: control)
                        let index = min(
                            max(
                                Int(
                                    round(
                                        current
                                            * Double(
                                                options.count - 1
                                            )
                                    )
                                ),
                                0
                            ),
                            options.count - 1
                        )
                        let resting =
                            Double(index)
                            / Double(options.count - 1)
                        var next = state
                        next.selectedOptionIDsByControlID[
                            control.id
                        ] = options[index].id
                        if control.semanticKind
                            == .thinkingBudget,
                            let definitionId =
                                options[index]
                                    .thinkingDefinitionId {
                            onSelectThinkingDefinitionId(
                                definitionId
                            )
                        }
                        if abs(resting - current) > 0.000_001 {
                            withAnimation(
                                .spring(
                                    response: 0.3,
                                    dampingFraction: 0.82
                                )
                            ) {
                                activeSliderPositions[
                                    control.id
                                ] = nil
                                state = next
                            }
                        } else {
                            activeSliderPositions[
                                control.id
                            ] = nil
                        }
                        save(next)
                    }
                )
            }
        }
    }

    private func menuOptionGroup(
        _ control: RequestBodyControl,
        options: [RequestBodyControlOption]
    ) -> some View {
        requestControlCard(id: control.id) {
            HStack(spacing: 10) {
                requestControlIcon(
                    RequestControlSymbols.resolvedName(
                        for: control
                    ),
                    isActive: selectedOptionID(
                        for: control
                    ) != nil
                )
                Text(control.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 10)
                Menu {
                    if options.isEmpty {
                        Text(String(localized: "No options"))
                    } else {
                        ForEach(options) { option in
                            Button {
                                var next = state
                                next.selectedOptionIDsByControlID[
                                    control.id
                                ] = option.id
                                save(next)
                                if control.semanticKind
                                    == .thinkingBudget,
                                    let definitionId =
                                        option
                                            .thinkingDefinitionId {
                                    onSelectThinkingDefinitionId(
                                        definitionId
                                    )
                                }
                            } label: {
                                if selectedOptionID(
                                    for: control
                                ) == option.id {
                                    Label(
                                        option.title,
                                        systemImage: "checkmark"
                                    )
                                } else {
                                    Text(option.title)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(
                            selectedOptionTitle(for: control)
                        )
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        Image(
                            systemName:
                                "chevron.up.chevron.down"
                        )
                        .font(
                            .system(
                                size: 9,
                                weight: .semibold
                            )
                        )
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Color.accentColor.opacity(0.10),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .disabled(options.isEmpty)
            }
        }
    }

    private func requestControlCard<Content: View>(
        id: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if displayedControlIDs.last != id {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 0.5)
                }
            }
            .contentShape(Rectangle())
            .accessibilityIdentifier(
                "requestControlCard.\(id)"
            )
    }

    private func requestControlIcon(
        _ systemName: String,
        isActive: Bool,
        tint: Color? = nil
    ) -> some View {
        let activeColor = tint ?? Color.accentColor
        return Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(
                isActive ? activeColor : .secondary
            )
            .frame(width: 30, height: 30)
            .background(
                (isActive ? activeColor : Color.secondary)
                    .opacity(isActive ? 0.13 : 0.09)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func selectedOptionID(
        for control: RequestBodyControl
    ) -> String? {
        if control.semanticKind == .thinkingBudget {
            return ThinkingLevelRegistry.option(
                forDefinitionId: currentThinkingDefinitionId,
                in: control
            )?.id
        }
        if control.isSliderEnabled,
            let option = option(
                for: control,
                sliderValue: sliderValue(for: control)
            ) {
            return option.id
        }
        return state.selectedOptionIDsByControlID[control.id]
            ?? control.defaultOptionID
            ?? displayOptions(for: control).first?.id
    }

    private func selectedOptionTitle(
        for control: RequestBodyControl
    ) -> String {
        guard let selectedID = selectedOptionID(
            for: control
        ) else {
            return String(localized: "None")
        }
        return displayOptions(for: control).first {
            $0.id == selectedID
        }?.title ?? String(localized: "None")
    }

    private func sliderValue(
        for control: RequestBodyControl
    ) -> Double {
        let options = displayOptions(for: control)
        if let value =
                activeSliderPositions[control.id],
            value.isFinite {
            return min(max(value, 0), 1)
        }
        if control.semanticKind == .thinkingBudget,
            options.count > 1,
            let selected = ThinkingLevelRegistry.option(
                forDefinitionId: currentThinkingDefinitionId,
                in: control
            ),
            let index = options.firstIndex(
                where: { $0.id == selected.id }
            ) {
            return Double(index) / Double(options.count - 1)
        }
        guard options.count > 1,
            let selectedID =
                state.selectedOptionIDsByControlID[control.id]
                ?? control.defaultOptionID,
            let index = options.firstIndex(
                where: { $0.id == selectedID }
            ) else {
            return 0
        }
        return Double(index) / Double(options.count - 1)
    }

    private func option(
        for control: RequestBodyControl,
        sliderValue: Double
    ) -> RequestBodyControlOption? {
        let options = displayOptions(for: control)
        guard !options.isEmpty else { return nil }
        let index = min(
            max(
                Int(
                    round(
                        sliderValue
                            * Double(options.count - 1)
                    )
                ),
                0
            ),
            options.count - 1
        )
        return options[index]
    }

    private func displayOptions(
        for control: RequestBodyControl
    ) -> [RequestBodyControlOption] {
        control.semanticKind == .thinkingBudget
            ? ThinkingLevelRegistry.sortedThinkingOptions(
                control.options.filter {
                    ThinkingLevelRegistry.definition(
                        forDefinitionId:
                            $0.thinkingDefinitionId
                    ) != nil
                }
            )
            : control.options
    }

    private func save(
        _ next: RequestBodyControlState
    ) {
        state = next
        RequestBodyControlRuntimeStore.save(
            next,
            forSessionKey: sessionKey,
            modelKey: modelKey,
            controls: controls
        )
    }

    private func provideSelectionFeedbackIfNeeded(
        controlID: String,
        anchorIndex: Int
    ) {
        guard lastAnchorIndices[controlID] != anchorIndex else {
            return
        }
        lastAnchorIndices[controlID] = anchorIndex
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

private struct MinixRequestControlAnimatedLabel: View {
    let text: String
    let position: Double

    var body: some View {
        ZStack {
            Text(text)
                .id(text)
                .transition(
                    .opacity.combined(
                        with: .scale(scale: 0.96)
                    )
                )
        }
        .animation(.easeOut(duration: 0.14), value: text)
    }
}

private struct MinixRequestControlGradientSlider: View {
    @Binding var value: Double
    let anchorCount: Int
    let startColor: Color
    let endColor: Color
    let onAnchorChanged: (Int) -> Void
    let onEditingChanged: (Bool) -> Void
    let onEditingEnded: () -> Void

    @ScaledMetric(relativeTo: .body)
    private var thumbDiameter: CGFloat = 24
    @ScaledMetric(relativeTo: .body)
    private var trackHeight: CGFloat = 8
    @State private var isEditing = false

    var body: some View {
        GeometryReader { proxy in
            slider(size: proxy.size)
                .contentShape(Rectangle())
                .gesture(
                    dragGesture(width: proxy.size.width)
                )
        }
        .frame(height: max(32, thumbDiameter))
    }

    private func slider(size: CGSize) -> some View {
        let normalized = min(max(value, 0), 1)
        let travelWidth = max(
            size.width - thumbDiameter,
            1
        )
        let thumbCenterX =
            thumbDiameter / 2 + travelWidth * normalized
        let fillWidth = size.width * normalized

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: trackHeight)

            LinearGradient(
                colors: [
                    color(at: 0),
                    color(at: 0.34),
                    color(at: 0.68),
                    color(at: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: trackHeight)
            .mask(alignment: .leading) {
                Rectangle().frame(width: fillWidth)
            }
            .clipShape(Capsule())

            anchorMarks(
                size: size,
                travelWidth: travelWidth,
                normalizedValue: normalized
            )

            Circle()
                .fill(.regularMaterial)
                .frame(
                    width: thumbDiameter,
                    height: thumbDiameter
                )
                .overlay {
                    Circle().fill(
                        color(at: normalized).opacity(0.16)
                    )
                }
                .overlay {
                    Circle().stroke(
                        color(at: normalized).opacity(0.5),
                        lineWidth: 1
                    )
                }
                .shadow(
                    color:
                        color(at: normalized).opacity(0.24),
                    radius: 4,
                    y: 2
                )
                .position(
                    x: thumbCenterX,
                    y: size.height / 2
                )
        }
        .frame(maxHeight: .infinity)
    }

    private func anchorMarks(
        size: CGSize,
        travelWidth: CGFloat,
        normalizedValue: Double
    ) -> some View {
        ZStack(alignment: .leading) {
            ForEach(
                0..<max(anchorCount, 0),
                id: \.self
            ) { index in
                let anchorPosition =
                    anchorCount > 1
                    ? Double(index)
                        / Double(anchorCount - 1)
                    : 0
                Circle()
                    .fill(
                        anchorPosition <= normalizedValue
                            ? Color.white.opacity(0.82)
                            : Color.secondary.opacity(0.48)
                    )
                    .frame(width: 4, height: 4)
                    .position(
                        x:
                            thumbDiameter / 2
                            + travelWidth * anchorPosition,
                        y: size.height / 2
                    )
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func dragGesture(
        width: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if !isEditing {
                    onEditingChanged(true)
                }
                isEditing = true
                updateValue(
                    for: drag.location.x,
                    width: width
                )
            }
            .onEnded { drag in
                updateValue(
                    for: drag.location.x,
                    width: width
                )
                isEditing = false
                onEditingEnded()
                DispatchQueue.main.async {
                    onEditingChanged(false)
                }
            }
    }

    private func updateValue(
        for xPosition: CGFloat,
        width: CGFloat
    ) {
        let travelWidth = max(
            width - thumbDiameter,
            1
        )
        let normalized = min(
            max(
                Double(
                    (xPosition - thumbDiameter / 2)
                        / travelWidth
                ),
                0
            ),
            1
        )
        value = normalized
        onAnchorChanged(
            nearestAnchorIndex(at: normalized)
        )
    }

    private func nearestAnchorIndex(
        at position: Double
    ) -> Int {
        guard anchorCount > 1 else { return 0 }
        return min(
            max(
                Int(
                    round(
                        position * Double(anchorCount - 1)
                    )
                ),
                0
            ),
            anchorCount - 1
        )
    }

    private func color(at position: Double) -> Color {
        interpolatedColor(
            from: startColor,
            to: endColor,
            at: position
        )
    }
}

private func requestControlColor(
    from hex: String?
) -> Color? {
    guard let hex else { return nil }
    var raw = hex.trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    if raw.hasPrefix("#") {
        raw.removeFirst()
    }
    guard raw.count == 6,
        let value = Int(raw, radix: 16) else {
        return nil
    }
    return Color(
        .sRGB,
        red: Double((value >> 16) & 0xFF) / 255.0,
        green: Double((value >> 8) & 0xFF) / 255.0,
        blue: Double(value & 0xFF) / 255.0,
        opacity: 1
    )
}

private func requestControlSliderColor(
    at position: Double
) -> Color {
    let clamped = min(max(position, 0), 1)
    return Color(
        hue: 0.58 + clamped * 0.29,
        saturation: 0.72,
        brightness: 0.94
    )
}

private func requestControlSliderColor(
    at position: Double,
    startColor: Color,
    endColor: Color
) -> Color {
    interpolatedColor(
        from: startColor,
        to: endColor,
        at: position
    )
}

private func interpolatedColor(
    from start: Color,
    to end: Color,
    at position: Double
) -> Color {
    let clamped = min(max(position, 0), 1)
    let startComponents =
        rgbaComponents(from: start)
        ?? (0.0, 0.2, 1.0, 1.0)
    let endComponents =
        rgbaComponents(from: end)
        ?? (1.0, 0.45, 0.0, 1.0)
    return Color(
        .sRGB,
        red:
            startComponents.red
            + (endComponents.red - startComponents.red)
                * clamped,
        green:
            startComponents.green
            + (endComponents.green - startComponents.green)
                * clamped,
        blue:
            startComponents.blue
            + (endComponents.blue - startComponents.blue)
                * clamped,
        opacity:
            startComponents.alpha
            + (
                endComponents.alpha
                    - startComponents.alpha
            ) * clamped
    )
}

private func rgbaComponents(
    from color: Color
) -> (
    red: Double,
    green: Double,
    blue: Double,
    alpha: Double
)? {
    let uiColor = UIColor(color)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard uiColor.getRed(
        &red,
        green: &green,
        blue: &blue,
        alpha: &alpha
    ) else {
        return nil
    }
    return (
        Double(red),
        Double(green),
        Double(blue),
        Double(alpha)
    )
}

struct MinixInteractivePopGestureController:
    UIViewRepresentable {
    let isDisabled: Bool

    func makeUIView(context: Context) -> UIView {
        let view = PopGestureControllerView()
        view.isDisabled = isDisabled
        return view
    }

    func updateUIView(
        _ uiView: UIView,
        context: Context
    ) {
        guard let view =
                uiView as? PopGestureControllerView else {
            return
        }
        view.isDisabled = isDisabled
        view.apply()
    }

    private final class PopGestureControllerView: UIView {
        var isDisabled = false
        private weak var navigationController:
            UINavigationController?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply(retries: 8)
        }

        override func willMove(
            toWindow newWindow: UIWindow?
        ) {
            if newWindow == nil {
                navigationController?
                    .interactivePopGestureRecognizer?
                    .isEnabled = true
            }
            super.willMove(toWindow: newWindow)
        }

        func apply(retries: Int = 0) {
            if navigationController == nil {
                var responder: UIResponder? = self
                while let current = responder {
                    if let navigation =
                            current as? UINavigationController {
                        navigationController = navigation
                        break
                    }
                    responder = current.next
                }
            }
            guard let navigationController else {
                guard retries > 0 else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.apply(retries: retries - 1)
                }
                return
            }
            navigationController
                .interactivePopGestureRecognizer?
                .isEnabled = !isDisabled
        }
    }
}

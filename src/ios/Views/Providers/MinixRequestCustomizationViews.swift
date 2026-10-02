import SwiftUI
import UIKit

// [Minix] Request customization, controls, expression help, and thinking-level management UI.

private struct CompactExpressionEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        CompactExpressionTextView(
            text: $text,
            placeholder: placeholder
        )
        .frame(height: CompactExpressionTextView.fixedHeight)
    }
}

private struct CompactExpressionTextView: UIViewRepresentable {
    static let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    static let verticalInset: CGFloat = 6
    static let fixedHeight = ceil(font.lineHeight * 3) + verticalInset * 2

    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = Self.font
        view.textContainerInset = UIEdgeInsets(
            top: Self.verticalInset,
            left: 0,
            bottom: Self.verticalInset,
            right: 0
        )
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.maximumNumberOfLines = 0
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        view.isScrollEnabled = true
        view.alwaysBounceVertical = false
        view.showsVerticalScrollIndicator = true
        view.text = text
        let placeholderLabel = UILabel()
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = Self.font
        placeholderLabel.textColor = .tertiaryLabel
        placeholderLabel.text = placeholder
        placeholderLabel.isUserInteractionEnabled = false
        view.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(
                equalTo: view.frameLayoutGuide.leadingAnchor
            ),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.frameLayoutGuide.trailingAnchor
            ),
            placeholderLabel.topAnchor.constraint(
                equalTo: view.contentLayoutGuide.topAnchor,
                constant: Self.verticalInset
            ),
        ])
        context.coordinator.placeholderLabel = placeholderLabel
        context.coordinator.updatePlaceholderVisibility(view)
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            coordinator.prioritizeInnerScrollingIfNeeded(view)
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text,
           view.markedTextRange == nil || text.isEmpty {
            let selection = view.selectedRange
            view.text = text
            view.selectedRange = NSRange(
                location: min(selection.location, text.utf16.count),
                length: 0
            )
        }
        context.coordinator.placeholderLabel?.text = placeholder
        context.coordinator.updatePlaceholderVisibility(view)
        context.coordinator.prioritizeInnerScrollingIfNeeded(view)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>
        private weak var prioritizedParentScrollView: UIScrollView?
        weak var placeholderLabel: UILabel?

        init(text: Binding<String>) {
            self.text = text
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            guard textView.markedTextRange == nil else {
                return true
            }
            guard let stringRange = Range(range, in: textView.text) else {
                return false
            }
            let raw = textView.text.replacingCharacters(
                in: stringRange,
                with: replacement
            )
            let normalized = normalizedExpressionEditorText(raw)
            guard normalized != raw else { return true }

            textView.text = normalized
            text.wrappedValue = normalized
            textView.selectedRange = NSRange(
                location: min(
                    range.location + replacement.utf16.count,
                    normalized.utf16.count
                ),
                length: 0
            )
            updatePlaceholderVisibility(textView)
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            updatePlaceholderVisibility(textView)
            guard textView.markedTextRange == nil else {
                return
            }
            let normalized = normalizedExpressionEditorText(textView.text)
            if normalized != textView.text {
                let selection = textView.selectedRange
                textView.text = normalized
                textView.selectedRange = NSRange(
                    location: min(
                        selection.location,
                        normalized.utf16.count
                    ),
                    length: 0
                )
            }
            text.wrappedValue = normalized
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            let finalized = finalizedExpressionEditorText(textView.text)
            guard finalized != textView.text else { return }
            textView.text = finalized
            text.wrappedValue = finalized
            updatePlaceholderVisibility(textView)
        }

        func updatePlaceholderVisibility(_ textView: UITextView) {
            placeholderLabel?.isHidden = !textView.text.isEmpty
        }

        func prioritizeInnerScrollingIfNeeded(
            _ textView: UITextView
        ) {
            var ancestor = textView.superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView,
                   scrollView !== textView {
                    guard prioritizedParentScrollView !== scrollView else {
                        return
                    }
                    scrollView.panGestureRecognizer.require(
                        toFail: textView.panGestureRecognizer
                    )
                    prioritizedParentScrollView = scrollView
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

func normalizedExpressionEditorText(_ raw: String) -> String {
    let lines = raw.components(separatedBy: .newlines)
    let nonEmptyLines = lines.filter {
        !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }
    guard !nonEmptyLines.isEmpty else { return "" }
    return nonEmptyLines.joined(separator: "\n")
        + (raw.last?.isNewline == true ? "\n" : "")
}

func finalizedExpressionEditorText(_ raw: String) -> String {
    normalizedExpressionEditorText(raw)
        .trimmingCharacters(in: .newlines)
}

private struct ExpressionSectionHeader: View {
    let title: String
    let onHelp: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: onHelp) {
                Image(systemName: "info.circle")
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Expression Help"))
        }
    }
}

private struct ExpressionSectionFooter: View {
    let text: String
    let issues: [RequestCustomizationExpression.ValidationIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(text)
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                Label {
                    Text(
                        String(
                            format: String(localized: "Expression error on line %d: %@"),
                            issue.line,
                            issue.message
                        )
                    )
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
            }
        }
    }
}

private func expressionLines(_ text: String) -> [String] {
    text
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func bodyValidationIssues(
    _ expressions: [String]
) -> [RequestCustomizationExpression.ValidationIssue] {
    RequestCustomizationExpression.validationIssues(
        expressions,
        target: .body
    )
}

private func controlValidationIssues(
    _ expressions: [String]
) -> [RequestCustomizationExpression.ValidationIssue] {
    RequestCustomizationExpression.validationIssues(
        expressions,
        target: .control
    )
}

private func requestControlIsValid(_ control: RequestBodyControl) -> Bool {
    if !controlValidationIssues(
        control.payloadExpressions
    ).isEmpty {
        return false
    }
    guard control.options.allSatisfy({
        controlValidationIssues(
            $0.payloadExpressions
        ).isEmpty
    }) else {
        return false
    }
    guard control.semanticKind == .thinkingBudget else {
        return true
    }
    let definitionIDs = control.options.compactMap(
        \.thinkingDefinitionId
    )
    return definitionIDs.count == control.options.count
        && Set(definitionIDs).count
            == definitionIDs.count
        && definitionIDs.allSatisfy {
            ThinkingLevelRegistry.definition(
                forDefinitionId: $0
            ) != nil
        }
}

struct ProviderRequestCustomizationEditor: View {
    let instance: ProviderInstance
    @ObservedObject private var store = ProviderConfigStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var customRequestHeadersText: String
    @State private var customRequestBodyText: String
    @State private var originalSnapshot: ProviderRequestCustomizationSnapshot
    @State private var showHelp = false
    @State private var showDiscardAlert = false

    init(instance: ProviderInstance) {
        self.instance = instance
        let snapshot = ProviderRequestCustomizationSnapshot(
            headers: instance.customRequestHeaders.joined(separator: "\n"),
            body: instance.customRequestBody.joined(separator: "\n")
        )
        _customRequestHeadersText = State(initialValue: snapshot.headers)
        _customRequestBodyText = State(initialValue: snapshot.body)
        _originalSnapshot = State(initialValue: snapshot)
    }

    var body: some View {
        List {
            Section {
                CompactExpressionEditor(
                    text: $customRequestHeadersText,
                    placeholder: String(localized: "user-agent = \"Minix/1.0\"")
                )
            } header: {
                ExpressionSectionHeader(
                    title: String(localized: "Custom Request Headers"),
                    onHelp: { showHelp = true }
                )
            } footer: {
                ExpressionSectionFooter(
                    text: String(localized: "One expression per line. Same-name headers replace defaults."),
                    issues: headerValidationIssues
                )
            }

            Section {
                CompactExpressionEditor(
                    text: $customRequestBodyText,
                    placeholder: String(localized: "temperature = 0.7")
                )
            } header: {
                ExpressionSectionHeader(
                    title: String(localized: "Custom Request Body"),
                    onHelp: { showHelp = true }
                )
            } footer: {
                ExpressionSectionFooter(
                    text: String(localized: "Objects merge recursively; scalar values and arrays replace. Use array functions to add, remove, or update elements."),
                    issues: bodyValidationIssues
                )
            }
        }
        .navigationTitle(String(localized: "Request Customization"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(true)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(String(localized: "Cancel")) {
                    cancelOrConfirmDiscard()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save")) {
                    saveAndDismiss()
                }
                .disabled(hasInvalidExpressions)
            }
        }
        .sheet(isPresented: $showHelp) {
            RequestExpressionHelpSheet()
        }
        .alert(String(localized: "Unsaved Changes"), isPresented: $showDiscardAlert) {
            Button(String(localized: "Save")) {
                saveAndDismiss()
            }
            .disabled(hasInvalidExpressions)
            Button(String(localized: "Discard"), role: .destructive) {
                dismiss()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Save your provider request customization before leaving?"))
        }
    }

    private var headerValidationIssues: [RequestCustomizationExpression.ValidationIssue] {
        RequestCustomizationExpression.validationIssues(
            expressionLines(customRequestHeadersText),
            target: .header
        )
    }

    private var bodyValidationIssues: [RequestCustomizationExpression.ValidationIssue] {
        RequestCustomizationExpression.validationIssues(
            expressionLines(customRequestBodyText),
            target: .body
        )
    }

    private var hasInvalidExpressions: Bool {
        !headerValidationIssues.isEmpty || !bodyValidationIssues.isEmpty
    }

    private func save() {
        guard !hasInvalidExpressions else { return }
        var updated = instance
        updated.customRequestHeaders = expressionLines(customRequestHeadersText)
        updated.customRequestBody = expressionLines(customRequestBodyText)
        store.updateInstance(updated)
        originalSnapshot = currentSnapshot
    }

    private func saveAndDismiss() {
        guard !hasInvalidExpressions else { return }
        save()
        dismiss()
    }

    private func cancelOrConfirmDiscard() {
        if currentSnapshot != originalSnapshot {
            showDiscardAlert = true
        } else {
            dismiss()
        }
    }

    private var currentSnapshot: ProviderRequestCustomizationSnapshot {
        ProviderRequestCustomizationSnapshot(
            headers: customRequestHeadersText,
            body: customRequestBodyText
        )
    }

    private func expressionLines(_ text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct ProviderRequestCustomizationSnapshot: Equatable {
    var headers: String
    var body: String
}

struct ModelRequestCustomizationSheet: View {
    private enum Destination: Hashable {
        case editor
    }

    let entry: ModelEntry
    @ObservedObject private var store = ProviderConfigStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var customRequestHeadersText: String
    @State private var customRequestBodyText: String
    @State private var requestBodyControls: [RequestBodyControl]
    @State private var path: [Destination] = [.editor]

    init(entry: ModelEntry) {
        self.entry = entry
        _customRequestHeadersText = State(
            initialValue: (entry.overrides.customRequestHeaders ?? [])
                .joined(separator: "\n")
        )
        _customRequestBodyText = State(
            initialValue: (entry.overrides.customRequestBody ?? [])
                .joined(separator: "\n")
        )
        _requestBodyControls = State(
            initialValue: entry.overrides.requestBodyControls ?? []
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            Color.clear
                .navigationDestination(
                    for: Destination.self
                ) { destination in
                    switch destination {
                    case .editor:
                        ModelRequestCustomizationEditor(
                            entry: entry,
                            provider: store.instance(
                                for:
                                    entry.providerInstanceId
                            ),
                            customRequestHeadersText:
                                $customRequestHeadersText,
                            customRequestBodyText:
                                $customRequestBodyText,
                            requestBodyControls:
                                $requestBodyControls,
                            onSave: save
                        )
                    }
                }
        }
        .interactiveDismissDisabled(true)
        .onChange(of: path) { newPath in
            if newPath.isEmpty {
                dismiss()
            }
        }
    }

    private func save() -> Bool {
        let headers = expressionLines(customRequestHeadersText)
        let body = expressionLines(customRequestBodyText)
        return store.updateModelRequestCustomization(
            entryId: entry.id,
            headers: headers,
            body: body,
            controls: requestBodyControls
        )
    }

    private func expressionLines(_ text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct ModelRequestCustomizationEditor: View {
    let entry: ModelEntry
    let provider: ProviderInstance?
    @Binding var customRequestHeadersText: String
    @Binding var customRequestBodyText: String
    @Binding var requestBodyControls: [RequestBodyControl]
    let onSave: () -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var showRequestExpressionHelp = false
    @State private var showDiscardAlert = false
    @State private var originalSnapshot: ModelRequestCustomizationSnapshot
    @ObservedObject private var store = ProviderConfigStore.shared

    init(
        entry: ModelEntry,
        provider: ProviderInstance?,
        customRequestHeadersText: Binding<String>,
        customRequestBodyText: Binding<String>,
        requestBodyControls: Binding<[RequestBodyControl]>,
        onSave: @escaping () -> Bool
    ) {
        self.entry = entry
        self.provider = provider
        _customRequestHeadersText = customRequestHeadersText
        _customRequestBodyText = customRequestBodyText
        _requestBodyControls = requestBodyControls
        self.onSave = onSave
        _originalSnapshot = State(initialValue: ModelRequestCustomizationSnapshot(
            headers: customRequestHeadersText.wrappedValue,
            body: customRequestBodyText.wrappedValue,
            controls: requestBodyControls.wrappedValue
        ))
    }

    var body: some View {
        List {
            Section {
                CompactExpressionEditor(
                    text: $customRequestHeadersText,
                    placeholder: String(localized: "user-agent = \"Minix/1.0\"")
                )
            } header: {
                ExpressionSectionHeader(
                    title: String(localized: "Custom Request Headers"),
                    onHelp: { showRequestExpressionHelp = true }
                )
            } footer: {
                ExpressionSectionFooter(
                    text: String(localized: "One expression per line. Same-name headers replace defaults."),
                    issues: headerValidationIssues
                )
            }

            Section {
                CompactExpressionEditor(
                    text: $customRequestBodyText,
                    placeholder: String(localized: "temperature = 0.7")
                )
            } header: {
                ExpressionSectionHeader(
                    title: String(localized: "Custom Request Body"),
                    onHelp: { showRequestExpressionHelp = true }
                )
            } footer: {
                ExpressionSectionFooter(
                    text: String(localized: "Objects merge recursively; scalar values and arrays replace. Use array functions to add, remove, or update elements."),
                    issues: bodyValidationIssues
                )
            }

            Section {
                if requestBodyControls.isEmpty {
                    Text(String(localized: "No request controls"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($requestBodyControls) { $control in
                        NavigationLink {
                            RequestBodyControlEditor(
                                control: $control,
                                provider: provider
                            )
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: RequestControlSymbols.resolvedName(for: control))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(control.title.isEmpty ? String(localized: "Untitled Control") : control.title)
                                    Text(controlSummary(control))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        requestBodyControls.remove(atOffsets: offsets)
                    }
                    .onMove { source, destination in
                        requestBodyControls.move(
                            fromOffsets: source,
                            toOffset: destination
                        )
                    }
                }
                Menu {
                    if !hasThinkingBudgetControl {
                        Button {
                            requestBodyControls.append(
                                RequestBodyControlDefaults
                                    .thinkingOptionGroup(for: provider)
                            )
                        } label: {
                            Label(
                                String(localized: "Thinking Intensity"),
                                systemImage: RequestControlSymbols.resolved(
                                    preferred: RequestControlSymbols.thinking,
                                    fallbacks: ["brain"]
                                )
                            )
                        }
                    }
                    Button {
                        requestBodyControls.append(RequestBodyControl(
                            title: String(localized: "Custom Toggle"),
                            iconName: RequestControlSymbols.toggle,
                            kind: .toggle
                        ))
                    } label: {
                        Label(
                            String(localized: "Custom Toggle"),
                            systemImage: RequestControlSymbols.resolved(
                                preferred: RequestControlSymbols.toggle,
                                fallbacks: ["power"]
                            )
                        )
                    }
                    Button {
                        requestBodyControls.append(RequestBodyControl(
                            title: String(localized: "Custom Options"),
                            iconName: RequestControlSymbols.optionGroup,
                            kind: .optionGroup
                        ))
                    } label: {
                        Label(
                            String(localized: "Custom Options"),
                            systemImage: RequestControlSymbols.resolved(
                                preferred: RequestControlSymbols.optionGroup,
                                fallbacks: [RequestControlSymbols.slider]
                            )
                        )
                    }
                } label: {
                    Label(String(localized: "Add Request Control"), systemImage: "plus")
                }
            } header: {
                Text(String(localized: "Request Controls"))
            } footer: {
                Text(String(localized: "Thinking Intensity options are sorted by the app-level thinking level rank. Custom option groups keep your manual order."))
            }

            Section {
                NavigationLink {
                    CopyModelRequestCustomizationView(currentEntryId: entry.id) { source in
                        customRequestHeadersText = (source.overrides.customRequestHeaders ?? []).joined(separator: "\n")
                        customRequestBodyText = (source.overrides.customRequestBody ?? []).joined(separator: "\n")
                        requestBodyControls = source.overrides.requestBodyControls ?? []
                    }
                } label: {
                    Label(String(localized: "Copy From Another Model"), systemImage: "doc.on.doc")
                }
                NavigationLink {
                    ThinkingLevelsManagerView()
                } label: {
                    Label(String(localized: "Manage Thinking Levels"), systemImage: "slider.horizontal.3")
                }
            }
        }
        .accessibilityIdentifier("modelRequestCustomizationEditor")
        .navigationTitle(String(localized: "Request Customization"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(true)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(String(localized: "Cancel")) {
                    cancelOrConfirmDiscard()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save")) {
                    saveAndDismiss()
                }
                .disabled(hasInvalidExpressions)
                .accessibilityIdentifier(
                    "modelRequestCustomizationSaveButton"
                )
            }
        }
        .sheet(isPresented: $showRequestExpressionHelp) {
            RequestExpressionHelpSheet()
        }
        .alert(String(localized: "Unsaved Changes"), isPresented: $showDiscardAlert) {
            Button(String(localized: "Save")) {
                saveAndDismiss()
            }
            .disabled(hasInvalidExpressions)
            Button(String(localized: "Discard"), role: .destructive) {
                restoreOriginalSnapshot()
                dismiss()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Save your model request customization before closing?"))
        }
    }

    private func controlSummary(_ control: RequestBodyControl) -> String {
        switch control.kind {
        case .toggle:
            return String(localized: "Toggle · \(control.payloadExpressions.count) expressions")
        case .optionGroup:
            let kind = control.semanticKind == .thinkingBudget
                ? String(localized: "Thinking Intensity")
                : String(localized: "Option Group")
            let slider = control.isSliderEnabled ? String(localized: " · slider") : ""
            return String(localized: "\(kind) · \(control.options.count) options\(slider)")
        }
    }

    private var hasThinkingBudgetControl: Bool {
        requestBodyControls.contains { $0.semanticKind == .thinkingBudget }
    }

    private var headerValidationIssues: [RequestCustomizationExpression.ValidationIssue] {
        RequestCustomizationExpression.validationIssues(
            expressionLines(customRequestHeadersText),
            target: .header
        )
    }

    private var bodyValidationIssues: [RequestCustomizationExpression.ValidationIssue] {
        RequestCustomizationExpression.validationIssues(
            expressionLines(customRequestBodyText),
            target: .body
        )
    }

    private var hasInvalidExpressions: Bool {
        !headerValidationIssues.isEmpty
            || !bodyValidationIssues.isEmpty
            || requestBodyControls.contains { !requestControlIsValid($0) }
    }

    private var currentSnapshot: ModelRequestCustomizationSnapshot {
        ModelRequestCustomizationSnapshot(
            headers: customRequestHeadersText,
            body: customRequestBodyText,
            controls: requestBodyControls
        )
    }

    private func cancelOrConfirmDiscard() {
        if currentSnapshot != originalSnapshot {
            showDiscardAlert = true
        } else {
            dismiss()
        }
    }

    private func restoreOriginalSnapshot() {
        customRequestHeadersText = originalSnapshot.headers
        customRequestBodyText = originalSnapshot.body
        requestBodyControls = originalSnapshot.controls
    }

    private func saveAndDismiss() {
        guard !hasInvalidExpressions else { return }
        guard onSave() else { return }
        originalSnapshot = currentSnapshot
        dismiss()
    }
}

private struct ModelRequestCustomizationSnapshot: Equatable {
    var headers: String
    var body: String
    var controls: [RequestBodyControl]
}

private struct RequestBodyControlEditor: View {
    @Binding var control: RequestBodyControl
    let provider: ProviderInstance?
    @State private var showExpressionHelp = false

    var body: some View {
        List {
            Section {
                TextField(String(localized: "Title"), text: $control.title)
                Toggle(String(localized: "Enabled"), isOn: $control.isEnabled)
                NavigationLink {
                    RequestControlSymbolPicker(control: $control)
                } label: {
                    HStack {
                        Text(String(localized: "Icon"))
                        Spacer()
                        Image(systemName: RequestControlSymbols.resolvedName(for: control))
                            .foregroundStyle(Color.accentColor)
                        Text(control.iconName ?? String(localized: "Default"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            switch control.kind {
            case .toggle:
                Section {
                    Toggle(String(localized: "Default On"), isOn: $control.defaultIsActive)
                    CompactExpressionEditor(
                        text: expressionsText($control.payloadExpressions),
                        placeholder: String(localized: "body.web_search = true")
                    )
                } header: {
                    ExpressionSectionHeader(
                        title: String(localized: "Payload When On"),
                        onHelp: { showExpressionHelp = true }
                    )
                } footer: {
                    ExpressionSectionFooter(
                        text: String(localized: "These request expressions are applied only when the toggle is on. Use body. or headers. on the left side."),
                        issues: controlValidationIssues(control.payloadExpressions)
                    )
                }
            case .optionGroup:
                Section {
                    Toggle(String(localized: "Slider"), isOn: $control.isSliderEnabled)
                    if control.isSliderEnabled {
                        NavigationLink {
                            RequestBodySliderColorSettingsView(control: $control)
                        } label: {
                            Text(String(localized: "Slider Colors"))
                        }
                    }
                    if control.semanticKind != .thinkingBudget,
                       !displayOptions.isEmpty {
                        Picker(String(localized: "Default Option"), selection: Binding(
                            get: {
                                guard let defaultID = control.defaultOptionID,
                                      displayOptions.contains(where: {
                                          $0.id == defaultID
                                      }) else {
                                    return displayOptions[0].id
                                }
                                return defaultID
                            },
                            set: { control.defaultOptionID = $0 }
                        )) {
                            ForEach(displayOptions) { option in
                                Text(option.title).tag(option.id)
                            }
                        }
                    }
                }

                Section {
                    if displayOptions.isEmpty {
                        Text(String(localized: "No options"))
                            .foregroundStyle(.secondary)
                    } else if control.semanticKind == .thinkingBudget {
                        ForEach(displayOptions) { option in
                            optionNavigationLink(
                                for: option.id
                            )
                        }
                        .onDelete(perform: deleteOptions)
                    } else {
                        ForEach(displayOptions) { option in
                            optionNavigationLink(
                                for: option.id
                            )
                        }
                        .onDelete(perform: deleteOptions)
                        .onMove(perform: moveOptions)
                    }
                    if control.semanticKind == .thinkingBudget {
                        Menu {
                            ForEach(availableThinkingDefinitions) { def in
                                Button(def.title) {
                                    addThinkingOption(def)
                                }
                            }
                        } label: {
                            Label(String(localized: "Add Thinking Level"), systemImage: "plus")
                        }
                    } else {
                        Button {
                            let option = RequestBodyControlOption(
                                title: String(localized: "Option"),
                                payloadExpressions: []
                            )
                            if control.defaultOptionID == nil { control.defaultOptionID = option.id }
                            control.options.append(option)
                        } label: {
                            Label(String(localized: "Add Option"), systemImage: "plus")
                        }
                    }
                } header: {
                    Text(String(localized: "Options"))
                } footer: {
                    if control.semanticKind == .thinkingBudget {
                        Text(String(localized: "Thinking options are sorted by the app-level thinking level order. Change the order in Manage Thinking Levels."))
                    } else {
                        Text(String(localized: "Custom option groups use this manual order."))
                    }
                }
            }
        }
        .navigationTitle(control.title.isEmpty ? String(localized: "Request Control") : control.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExpressionHelp) {
            RequestExpressionHelpSheet()
        }
    }

    private var displayOptions: [RequestBodyControlOption] {
        control.semanticKind == .thinkingBudget
            ? ThinkingLevelRegistry.sortedThinkingOptions(control.options)
            : control.options
    }

    private var availableThinkingDefinitions: [ThinkingLevelDefinition] {
        let existing = Set(
            control.options.compactMap(
                \.thinkingDefinitionId
            )
        )
        return ThinkingLevelRegistry.definitions.filter {
            !existing.contains($0.definitionId)
        }
    }

    @ViewBuilder
    private func optionNavigationLink(
        for optionID: String
    ) -> some View {
        if let option = control.options.first(
            where: { $0.id == optionID }
        ) {
        NavigationLink {
            RequestBodyControlOptionEditor(
                option: Binding(
                    get: {
                        control.options.first(
                            where: {
                                $0.id == optionID
                            }
                        ) ?? option
                    },
                    set: { updated in
                        guard let index =
                                control.options
                                    .firstIndex(
                                        where: {
                                            $0.id
                                                == optionID
                                        }
                                    ) else {
                            return
                        }
                        control.options[index] =
                            updated
                    }
                ),
                isThinkingBudget: control.semanticKind == .thinkingBudget,
                existingThinkingDefinitionIDs: Set(
                    control.options.compactMap {
                        guard $0.id != optionID else {
                            return nil
                        }
                        return $0.thinkingDefinitionId
                    }
                )
            )
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(option.title)
                if let definitionId =
                        option.thinkingDefinitionId,
                   let definition =
                    ThinkingLevelRegistry.definition(
                        forDefinitionId: definitionId
                    ) {
                    Text(definition.levelId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        }
    }

    private func addThinkingOption(_ def: ThinkingLevelDefinition) {
        let option = RequestBodyControlOption(
            id: def.definitionId,
            thinkingDefinitionId:
                def.definitionId,
            title: def.title,
            payloadExpressions:
                RequestBodyControlDefaults
                    .thinkingExpressions(
                        for: def,
                        provider: provider
                    )
        )
        if control.defaultOptionID == nil { control.defaultOptionID = option.id }
        control.options.append(option)
    }

    private func deleteOptions(_ offsets: IndexSet) {
        let ids = offsets.compactMap { offset in
            displayOptions.indices.contains(offset) ? displayOptions[offset].id : nil
        }
        control.options.removeAll { ids.contains($0.id) }
        if let defaultID = control.defaultOptionID, ids.contains(defaultID) {
            control.defaultOptionID = control.options.first?.id
        }
    }

    private func moveOptions(from source: IndexSet, to destination: Int) {
        control.options.move(fromOffsets: source, toOffset: destination)
    }

}

private struct RequestControlSymbolPicker: View {
    @Binding var control: RequestBodyControl
    @State private var searchText = ""
    @State private var systemSymbols: [String] = []
    @State private var isLoadingSymbols = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: RequestControlSymbols.resolvedName(for: control))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Icon"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(control.iconName ?? String(localized: "Default"))
                    .font(.system(.body, design: .monospaced))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if let iconName = control.iconName,
               !RequestControlSymbols.isAvailable(iconName) {
                Text(String(localized: "This symbol is unavailable on this system. A compatible icon will be used instead."))
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            Divider()

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 58), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(availableSymbols, id: \.self) { symbol in
                        Button {
                            control.iconName = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 19, weight: .medium))
                                .foregroundStyle(
                                    control.iconName == symbol
                                        ? Color.white
                                        : Color.accentColor
                                )
                                .frame(width: 48, height: 44)
                                .background(
                                    control.iconName == symbol
                                        ? Color.accentColor
                                        : Color.accentColor.opacity(0.09)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 11))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(symbol)
                    }
                }
                .padding(16)
            }
            .overlay {
                if isLoadingSymbols {
                    ProgressView()
                } else if availableSymbols.isEmpty {
                    Text(String(localized: "No matching icons"))
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Button {
                    control.iconName = nil
                } label: {
                    Label(
                        String(localized: "Reset to Default"),
                        systemImage: "arrow.counterclockwise"
                    )
                }
                .disabled(control.iconName == nil)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle(String(localized: "Icon"))
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(true)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: String(localized: "Search Icons")
        )
        .task {
            let symbols = await Task.detached(priority: .userInitiated) {
                RequestControlSymbols.availableCatalog
            }.value
            guard !Task.isCancelled else { return }
            systemSymbols = symbols
            isLoadingSymbols = false
        }
    }

    private var availableSymbols: [String] {
        guard !searchText.isEmpty else {
            return systemSymbols
        }
        return systemSymbols.filter {
            $0.localizedCaseInsensitiveContains(searchText)
        }
    }
}

private struct RequestBodySliderColorSettingsView: View {
    @Binding var control: RequestBodyControl

    var body: some View {
        Form {
            Section {
                Capsule()
                    .fill(sliderColorGradient(for: control))
                    .frame(height: 28)
                    .overlay {
                        Capsule()
                            .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
                    }
                    .accessibilityHidden(true)
            } header: {
                Text(String(localized: "Preview"))
            }

            Section {
                ColorPicker(
                    String(localized: "Low Value Color"),
                    selection: colorBinding(
                        \.sliderStartColorHex,
                        fallback: defaultRequestControlSliderColor(at: 0)
                    ),
                    supportsOpacity: false
                )
                ColorPicker(
                    String(localized: "High Value Color"),
                    selection: colorBinding(
                        \.sliderEndColorHex,
                        fallback: defaultRequestControlSliderColor(at: 1)
                    ),
                    supportsOpacity: false
                )
            } footer: {
                Text(String(localized: "The colors between the low and high values blend smoothly."))
            }

            Section {
                Button {
                    control.sliderStartColorHex = nil
                    control.sliderEndColorHex = nil
                } label: {
                    Label(String(localized: "Reset to Default"), systemImage: "arrow.counterclockwise")
                }
                .disabled(control.sliderStartColorHex == nil && control.sliderEndColorHex == nil)
            }
        }
        .navigationTitle(String(localized: "Slider Colors"))
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(true)
    }

    private func colorBinding(
        _ keyPath: WritableKeyPath<RequestBodyControl, String?>,
        fallback: Color
    ) -> Binding<Color> {
        Binding(
            get: {
                requestControlColor(from: control[keyPath: keyPath]) ?? fallback
            },
            set: { color in
                control[keyPath: keyPath] = requestControlHex(from: color)
            }
        )
    }
}

private struct RequestBodyControlOptionEditor: View {
    @Binding var option: RequestBodyControlOption
    let isThinkingBudget: Bool
    let existingThinkingDefinitionIDs: Set<String>
    @State private var showExpressionHelp = false

    var body: some View {
        List {
            Section {
                TextField(
                    String(localized: "Display Name"),
                    text: $option.title
                )
                if isThinkingBudget {
                    Picker(
                        String(localized: "Thinking Level"),
                        selection:
                            $option.thinkingDefinitionId
                    ) {
                        ForEach(availableThinkingDefinitions) { definition in
                            Text(
                                "\(definition.title) (\(definition.levelId))"
                            )
                            .tag(
                                Optional(
                                    definition.definitionId
                                )
                            )
                        }
                    }
                }
            } footer: {
                if isThinkingBudget,
                   !isThinkingLevelAvailable {
                    Text(String(localized: "Invalid thinking level ID."))
                        .foregroundStyle(.red)
                }
            }
            Section {
                CompactExpressionEditor(
                    text: expressionsText($option.payloadExpressions),
                    placeholder: String(localized: "body.reasoning.effort = \"high\"")
                )
            } header: {
                ExpressionSectionHeader(
                    title: String(localized: "Payload Expressions"),
                    onHelp: { showExpressionHelp = true }
                )
            } footer: {
                ExpressionSectionFooter(
                    text: String(localized: "These request expressions are applied when this option is selected. Use body. or headers. on the left side."),
                    issues: controlValidationIssues(option.payloadExpressions)
                )
            }
        }
        .navigationTitle(option.title.isEmpty ? String(localized: "Option") : option.title)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(true)
        .sheet(isPresented: $showExpressionHelp) {
            RequestExpressionHelpSheet()
        }
    }

    private var availableThinkingDefinitions:
        [ThinkingLevelDefinition] {
        ThinkingLevelRegistry.definitions.filter {
            $0.definitionId
                    == option.thinkingDefinitionId
                || !existingThinkingDefinitionIDs
                    .contains($0.definitionId)
        }
    }

    private var isThinkingLevelAvailable: Bool {
        guard let definitionId =
                option.thinkingDefinitionId else {
            return false
        }
        return availableThinkingDefinitions.contains {
            $0.definitionId == definitionId
        }
    }
}

private struct CopyModelRequestCustomizationView: View {
    let currentEntryId: String
    let onCopy: (ModelEntry) -> Void
    @ObservedObject private var store = ProviderConfigStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(copyableEntries) { entry in
                Button {
                    onCopy(entry)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.model.displayName)
                        Text(copySummary(entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if copyableEntries.isEmpty {
                Text(String(localized: "No other model has request customization."))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "Copy From Model"))
    }

    private var copyableEntries: [ModelEntry] {
        store.config.modelEntries
            .filter { $0.id != currentEntryId && hasRequestCustomization($0) }
            .sorted { $0.model.displayName.localizedStandardCompare($1.model.displayName) == .orderedAscending }
    }

    private func hasRequestCustomization(_ entry: ModelEntry) -> Bool {
        !(entry.overrides.customRequestHeaders ?? []).isEmpty
            || !(entry.overrides.customRequestBody ?? []).isEmpty
            || !(entry.overrides.requestBodyControls ?? []).isEmpty
    }

    private func copySummary(_ entry: ModelEntry) -> String {
        let headers = entry.overrides.customRequestHeaders?.count ?? 0
        let body = entry.overrides.customRequestBody?.count ?? 0
        let controls = entry.overrides.requestBodyControls?.count ?? 0
        return String(localized: "\(headers) headers · \(body) body expressions · \(controls) controls")
    }
}

private enum MinixRequestExpressionHelp {
    static var markdown: String {
        guard let url = Bundle.main.url(
                  forResource: "ExpressionCapabilityHelp",
                  withExtension: "md"
              ),
              let markdown = try? String(
                  contentsOf: url,
                  encoding: .utf8
              ) else {
            assertionFailure(
                "ExpressionCapabilityHelp.md is missing"
            )
            return "# Expression Capability"
        }
        return markdown
    }
}

private struct RequestExpressionHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PaginatedMarkdownView(
                markdown: MinixRequestExpressionHelp.markdown
            )
            .navigationTitle(String(localized: "Request Expression Help"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(true)
    }
}

private struct ThinkingLevelEditorItem: Identifiable, Equatable {
    let definitionId: String
    var levelId: String
    var title: String
    var rank: Int
    var isBuiltIn: Bool

    var id: String { definitionId }

    init(_ definition: ThinkingLevelDefinition) {
        definitionId = definition.definitionId
        levelId = definition.levelId
        title = definition.title
        rank = definition.rank
        isBuiltIn = definition.isBuiltIn
    }
}

private enum ThinkingLevelFormMode: Identifiable {
    case add
    case edit(String)

    var id: String {
        switch self {
        case .add:
            return "add"
        case .edit(let definitionId):
            return definitionId
        }
    }
}

private struct PendingThinkingLevelDeletion:
    Identifiable {
    let definitionIds: [String]
    let referenceCount: Int

    var id: String {
        definitionIds.joined(separator: ",")
    }
}

struct ThinkingLevelsManagerSheet: View {
    private enum Destination: Hashable {
        case manager
    }

    @Environment(\.dismiss) private var dismiss
    @State private var path: [Destination] = [.manager]

    var body: some View {
        NavigationStack(path: $path) {
            Color.clear
                .navigationDestination(
                    for: Destination.self
                ) { destination in
                    switch destination {
                    case .manager:
                        ThinkingLevelsManagerView()
                    }
                }
        }
        .interactiveDismissDisabled(true)
        .onChange(of: path) { newPath in
            if newPath.isEmpty {
                dismiss()
            }
        }
    }
}

struct ThinkingLevelsManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ThinkingLevelEditorItem]
    @State private var originalItems: [ThinkingLevelEditorItem]
    @State private var formMode:
        ThinkingLevelFormMode?
    @State private var showDiscardAlert = false
    @State private var pendingDeletion:
        PendingThinkingLevelDeletion?

    init() {
        let items = ThinkingLevelRegistry.definitions.map(
            ThinkingLevelEditorItem.init
        )
        _items = State(initialValue: items)
        _originalItems = State(initialValue: items)
    }

    var body: some View {
        List {
            Section {
                ForEach(items) { item in
                    Button {
                        guard !item.isBuiltIn else {
                            return
                        }
                        formMode = .edit(
                            item.definitionId
                        )
                    } label: {
                        HStack {
                            VStack(
                                alignment: .leading,
                                spacing: 6
                            ) {
                                Text(item.title)
                                Text(item.levelId)
                                    .font(
                                        .caption
                                            .monospaced()
                                    )
                                    .foregroundStyle(
                                        .secondary
                                    )
                            }
                            Spacer(minLength: 12)
                            if item.isBuiltIn {
                                Text(
                                    String(
                                        localized:
                                            "Built In"
                                    )
                                )
                                .font(.caption2)
                                .foregroundStyle(
                                    .secondary
                                )
                            } else {
                                Image(
                                    systemName:
                                        "chevron.right"
                                )
                                .font(.caption)
                                .foregroundStyle(
                                    .tertiary
                                )
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .deleteDisabled(item.isBuiltIn)
                }
                .onDelete(perform: deleteItems)
                .onMove(perform: moveItems)
            } header: {
                Text(String(localized: "Thinking Levels"))
            }

            Section {
                Button {
                    formMode = .add
                } label: {
                    Label(String(localized: "Add Custom Level"), systemImage: "plus")
                }
            } header: {
                Text(String(localized: "Custom Levels"))
            }
        }
        .navigationTitle(String(localized: "Thinking Levels"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(true)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(String(localized: "Cancel")) {
                    cancelOrConfirmDiscard()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save")) {
                    saveAndDismiss()
                }
                .disabled(hasInvalidItems)
                .accessibilityIdentifier("thinkingLevelsSaveButton")
            }
        }
        .alert(String(localized: "Unsaved Changes"), isPresented: $showDiscardAlert) {
            Button(String(localized: "Save")) {
                saveAndDismiss()
            }
            .disabled(hasInvalidItems)
            Button(String(localized: "Discard"), role: .destructive) {
                dismiss()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Save your thinking level changes before leaving?"))
        }
        .alert(
            String(localized: "Delete Thinking Level?"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { presented in
                    if !presented {
                        pendingDeletion = nil
                    }
                }
            ),
            presenting: pendingDeletion
        ) { pending in
            Button(
                String(localized: "Delete"),
                role: .destructive
            ) {
                removeDefinitions(
                    pending.definitionIds
                )
            }
            Button(
                String(localized: "Cancel"),
                role: .cancel
            ) {}
        } message: { pending in
            Text(
                String(
                    format: String(
                        localized:
                            "Thinking level deletion reference warning format"
                    ),
                    pending.referenceCount
                )
            )
        }
        .sheet(item: $formMode) { mode in
            let editingItem: ThinkingLevelEditorItem? = {
                guard case .edit(
                    let definitionId
                ) = mode else {
                    return nil
                }
                return items.first {
                    $0.definitionId
                        == definitionId
                }
            }()
            ThinkingLevelFormSheet(
                mode: editingItem == nil
                    ? .add : .edit,
                initialLevelId:
                    editingItem?.levelId ?? "",
                initialTitle:
                    editingItem?.title ?? "",
                existingLevelIds: Set(
                    items.compactMap {
                        $0.definitionId
                                == editingItem?
                                    .definitionId
                            ? nil
                            : $0.levelId
                    }
                ),
                onCommit: { levelId, title in
                    if let editingItem {
                        updateCustomLevel(
                            definitionId:
                                editingItem
                                    .definitionId,
                            levelId: levelId,
                            title: title
                        )
                    } else {
                        addCustomLevel(
                            levelId: levelId,
                            title: title
                        )
                    }
                }
            )
        }
    }

    private func save() {
        ThinkingLevelRegistry.saveDefinitions(items.enumerated().map { index, item in
            ThinkingLevelDefinition(
                definitionId:
                    item.definitionId,
                levelId: item.levelId,
                title: item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? item.levelId
                    : item.title,
                rank: index,
                isBuiltIn: item.isBuiltIn
            )
        })
    }

    private func saveAndDismiss() {
        guard !hasInvalidItems else { return }
        save()
        originalItems = items
        dismiss()
    }

    private func cancelOrConfirmDiscard() {
        if items != originalItems {
            showDiscardAlert = true
        } else {
            dismiss()
        }
    }

    private func addCustomLevel(
        levelId: String,
        title: String
    ) {
        guard !levelId.isEmpty,
              !items.contains(
                where: {
                    $0.levelId == levelId
                }
              ) else {
            return
        }
        items.append(
            ThinkingLevelEditorItem(
                ThinkingLevelDefinition(
                    levelId: levelId,
                    title: title,
                    rank: items.count
                )
            )
        )
    }

    private func updateCustomLevel(
        definitionId: String,
        levelId: String,
        title: String
    ) {
        guard let index = items.firstIndex(
            where: {
                $0.definitionId == definitionId
            }
        ) else {
            return
        }
        items[index].levelId = levelId
        items[index].title = title
    }

    private func moveItems(
        from source: IndexSet,
        to destination: Int
    ) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    private func deleteItems(at offsets: IndexSet) {
        let definitionIds = offsets.compactMap {
            items.indices.contains($0)
                && !items[$0].isBuiltIn
                ? items[$0].definitionId
                : nil
        }
        guard !definitionIds.isEmpty else {
            return
        }
        let count = definitionIds.reduce(0) {
            $0 + ProviderConfigStore.shared
                .thinkingDefinitionReferenceCount($1)
        }
        if count > 0 {
            pendingDeletion =
                PendingThinkingLevelDeletion(
                    definitionIds: definitionIds,
                    referenceCount: count
                )
        } else {
            removeDefinitions(definitionIds)
        }
    }

    private func removeDefinitions(
        _ definitionIds: [String]
    ) {
        let ids = Set(definitionIds)
        items.removeAll {
            ids.contains($0.definitionId)
                && !$0.isBuiltIn
        }
    }

    private var hasInvalidItems: Bool {
        items.contains { levelIDIssue(for: $0) != nil }
    }

    private func levelIDIssue(
        for item: ThinkingLevelEditorItem
    ) -> String? {
        guard !item.isBuiltIn else { return nil }
        let trimmed = item.levelId.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard item.levelId == trimmed,
              !trimmed.isEmpty,
              trimmed.range(
                of: #"^[a-z0-9_]+$"#,
                options: .regularExpression
              ) != nil else {
            return String(localized: "Invalid thinking level ID.")
        }
        guard items.filter({ $0.levelId == item.levelId }).count == 1 else {
            return String(
                localized: "This thinking level ID already exists."
            )
        }
        return nil
    }
}

private struct ThinkingLevelFormSheet: View {
    enum Mode: Equatable {
        case add
        case edit
    }

    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    let existingLevelIds: Set<String>
    let onCommit: (String, String) -> Void
    @State private var levelId: String
    @State private var title: String

    init(
        mode: Mode,
        initialLevelId: String,
        initialTitle: String,
        existingLevelIds: Set<String>,
        onCommit:
            @escaping (String, String) -> Void
    ) {
        self.mode = mode
        self.existingLevelIds =
            existingLevelIds
        self.onCommit = onCommit
        _levelId = State(
            initialValue: initialLevelId
        )
        _title = State(
            initialValue: initialTitle
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Level ID"), text: $levelId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    TextField(String(localized: "Display Name"), text: $title)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Level IDs may contain only lowercase letters, numbers, and underscores."))
                        if !levelId.isEmpty, !isLevelIdValid {
                            Text(String(localized: "Invalid thinking level ID."))
                                .foregroundStyle(.red)
                        } else if isDuplicate {
                            Text(String(localized: "This thinking level ID already exists."))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(
                mode == .add
                    ? String(
                        localized:
                            "Add Custom Level"
                    )
                    : String(
                        localized:
                            "Edit Custom Level"
                    )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        mode == .add
                            ? String(localized: "Add")
                            : String(localized: "Save")
                    ) {
                        onCommit(
                            trimmedLevelId,
                            title.trimmingCharacters(
                                in:
                                    .whitespacesAndNewlines
                            ).isEmpty
                                ? trimmedLevelId
                                : title
                        )
                        dismiss()
                    }
                    .disabled(
                        !isLevelIdValid || isDuplicate
                    )
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(true)
    }

    private var trimmedLevelId: String {
        levelId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isLevelIdValid: Bool {
        levelId == trimmedLevelId
            && !trimmedLevelId.isEmpty
            && trimmedLevelId.range(
                of: #"^[a-z0-9_]+$"#,
                options: .regularExpression
            ) != nil
    }

    private var isDuplicate: Bool {
        existingLevelIds.contains(
            trimmedLevelId
        )
    }
}

private func expressionsText(_ expressions: Binding<[String]>) -> Binding<String> {
    Binding<String>(
        get: { expressions.wrappedValue.joined(separator: "\n") },
        set: { value in
            expressions.wrappedValue = value
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    )
}

private func requestControlColor(from hex: String?) -> Color? {
    guard let hex else { return nil }
    var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.hasPrefix("#") { raw.removeFirst() }
    guard raw.count == 6, let value = Int(raw, radix: 16) else { return nil }
    return Color(
        .sRGB,
        red: Double((value >> 16) & 0xFF) / 255.0,
        green: Double((value >> 8) & 0xFF) / 255.0,
        blue: Double(value & 0xFF) / 255.0,
        opacity: 1
    )
}

private func sliderColorGradient(for control: RequestBodyControl) -> LinearGradient {
    LinearGradient(
        colors: [
            requestControlColor(from: control.sliderStartColorHex)
                ?? defaultRequestControlSliderColor(at: 0),
            requestControlColor(from: control.sliderEndColorHex)
                ?? defaultRequestControlSliderColor(at: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
}

private func defaultRequestControlSliderColor(at position: Double) -> Color {
    let clamped = min(max(position, 0), 1)
    return Color(
        hue: 0.58 + clamped * 0.29,
        saturation: 0.72,
        brightness: 0.94
    )
}

private func requestControlHex(from color: Color) -> String? {
    let uiColor = UIColor(color)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
    return String(
        format: "#%02X%02X%02X",
        Int(round(red * 255)),
        Int(round(green * 255)),
        Int(round(blue * 255))
    )
}

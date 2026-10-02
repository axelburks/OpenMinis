#!/bin/bash
# Guard Minix behavior and workflows against silent upstream regressions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

FAILED=0

pass() {
    printf 'OK  %s\n' "$1"
}

fail() {
    printf 'ERR %s\n' "$1" >&2
    FAILED=1
}

require_fixed() {
    local file="$1"
    local value="$2"
    local description="$3"
    if rg -q -F -- "$value" "$file"; then
        pass "$description"
    else
        fail "$description (missing '$value' in $file)"
    fi
}

require_file() {
    local file="$1"
    local description="$2"
    if [ -f "$file" ]; then
        pass "$description"
    else
        fail "$description (missing $file)"
    fi
}

forbid_file() {
    local file="$1"
    local description="$2"
    if [ ! -e "$file" ]; then
        pass "$description"
    else
        fail "$description (unexpected $file)"
    fi
}

require_fixed_count() {
    local file="$1"
    local value="$2"
    local expected="$3"
    local description="$4"
    local actual
    actual="$(rg -c -F -- "$value" "$file" 2>/dev/null || true)"
    if [ "${actual:-0}" -eq "$expected" ]; then
        pass "$description"
    else
        fail "$description (expected $expected occurrences of '$value' in $file, found ${actual:-0})"
    fi
}

forbid_regex() {
    local description="$1"
    local pattern="$2"
    shift 2
    local matches
    matches="$(rg -n --pcre2 -- "$pattern" "$@" 2>/dev/null || true)"
    if [ -z "$matches" ]; then
        pass "$description"
    else
        fail "$description"
        printf '%s\n' "$matches" >&2
    fi
}

require_help_contract() {
    local file="$1"
    local description="$2"
    shift 2
    local sections=("$@")
    local functions=(
        array.filter array.map array.reduce append concat remove update insert remove_at
        deep_merge min max sum avg clamp length count upper lower string
        json url_encode url_decode md5 sha256 if exists now format_time
        parse_time uuid delete
    )
    local issues=()
    local value
    if rg -q '^### ' "$file"; then
        issues+=("function-level headings")
    fi
    for value in "${sections[@]}"; do
        if ! rg -q -F -- "$value" "$file"; then
            issues+=("$value")
        fi
    done
    for value in "${functions[@]}"; do
        if ! rg -q -F -- "**\`$value(" "$file"; then
            issues+=("$value")
        fi
    done
    if [ "$(rg -c '^- \*\*`[^`]+\([^`]*\) -> [^`]+`\*\*[:：]' "$file" || true)" -ne "${#functions[@]}" ]; then
        issues+=("exactly ${#functions[@]} bulleted function signatures")
    fi
    if [ "${#issues[@]}" -eq 0 ]; then
        pass "$description"
    else
        fail "$description (missing or invalid: ${issues[*]})"
    fi
}

require_equal_files() {
    local first="$1"
    local second="$2"
    local description="$3"
    if cmp -s "$first" "$second"; then
        pass "$description"
    else
        fail "$description ($first differs from $second)"
    fi
}

require_xcstrings_locale_absent() {
    local file="$1"
    local locale="$2"
    local description="$3"
    shift 3
    local issues
    if issues="$(python3 - "$file" "$locale" "$@" <<'PY'
import json
import sys

path, locale, *keys = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    strings = json.load(source).get("strings", {})

missing = [key for key in keys if key not in strings]
localized = [
    key for key in keys
    if locale in (strings.get(key, {}).get("localizations") or {})
]
if missing or localized:
    if missing:
        print(f"missing keys: {', '.join(missing)}")
    if localized:
        print(f"unexpected {locale} localizations: {', '.join(localized)}")
    raise SystemExit(1)
PY
)"; then
        pass "$description"
    else
        fail "$description${issues:+ ($issues)}"
    fi
}

echo "Checking Minix invariants..."

require_fixed \
    "src/ios/Providers/ProviderConfigDB.swift" \
    "request_customization_json" \
    "Provider Header and Body use the shared persistence envelope"
forbid_regex \
    "Removed provider persistence fields stay removed" \
    'custom_request_headers_json|var[[:space:]]+customUserAgent' \
    "src/ios/Providers/ProviderInstance.swift" \
    "src/ios/Providers/ProviderConfigDB.swift" \
    "src/ios/Providers/ProviderConfigStore.swift" \
    "src/ios/Views/Providers/ProviderInstanceDetailView.swift"
forbid_regex \
    "Dedicated provider custom User-Agent API stays removed" \
    'custom_user_agent|customUserAgent|applyUserAgentOverride' \
    "src/ios/Providers/Anthropic/AnthropicProvider.swift" \
    "src/ios/Providers/Anthropic/OAuthHTTPClient.swift" \
    "src/ios/Providers/LLMProviderFactory.swift" \
    "src/android/app/src/main/java/com/openminis/app/provider/openai/OpenAIProvider.kt" \
    "src/android/app/src/main/java/com/openminis/app/provider/openai/OpenAIModelsApi.kt" \
    "src/android/app/src/main/java/com/openminis/app/provider/anthropic/AnthropicProvider.kt" \
    "src/android/app/src/main/java/com/openminis/app/provider/anthropic/AnthropicModelsApi.kt"

require_file \
    "src/android/app/src/main/java/com/openminis/app/provider/MinixRequestCustomization.kt" \
    "Android request orchestration uses a Minix-owned filename"
require_file \
    "src/android/app/src/main/java/com/openminis/app/provider/MinixDefaultUserAgent.kt" \
    "Android Minix default User-Agent uses a Minix-owned filename"
require_file \
    "src/android/app/src/main/java/com/openminis/app/ui/components/MinixRequestControlIcons.kt" \
    "Android request-control icons use a Minix-owned filename"
require_file \
    "src/android/app/src/main/java/com/openminis/app/ui/components/MinixRequestControlMaterialIcons.generated.kt" \
    "Android generated request-control icons use a Minix-owned filename"
require_file \
    "src/android/app/src/main/java/com/openminis/app/ui/settings/MinixThinkingLevelsManagerDialog.kt" \
    "Android thinking-level management uses a Minix-owned filename"
require_file \
    "src/ios/Resources/MinixRequestControlSFSymbolCatalog.txt" \
    "iOS request-control symbol catalog uses a Minix-owned filename"
forbid_file \
    "src/android/app/src/main/java/com/openminis/app/provider/RequestCustomization.kt" \
    "Generic Android request-customization filename stays removed"
forbid_file \
    "src/android/app/src/main/java/com/openminis/app/provider/DefaultUserAgent.kt" \
    "Generic Android default User-Agent filename stays removed"
forbid_file \
    "src/android/app/src/main/java/com/openminis/app/ui/components/RequestControlIcons.kt" \
    "Generic Android request-control icon filename stays removed"
forbid_file \
    "src/android/app/src/main/java/com/openminis/app/ui/components/RequestControlMaterialIcons.generated.kt" \
    "Generic Android generated icon filename stays removed"
forbid_file \
    "src/android/app/src/main/java/com/openminis/app/ui/settings/ThinkingLevelsManagerDialog.kt" \
    "Generic Android thinking-level filename stays removed"
forbid_file \
    "src/ios/Resources/SFSymbolCatalog.txt" \
    "Generic iOS symbol-catalog filename stays removed"

require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testApply_usesProviderThenModelThenControlPriority_BitsUT" \
    "Request layer ordering behavior test remains present"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testApplyDefaultChatThinking_handlesProtocolAndLevelBranches_BitsUT" \
    "Protocol-level default thinking behavior test remains present"
require_fixed \
    "src/ios/MinisTests/ThinkingLevelTests.swift" \
    "testSortedAndResolvedDefinitions_useRankAndDanglingFallback_BitsUT" \
    "Semantic fallback behavior test remains present"
require_fixed \
    "src/ios/Providers/MinixThinkingLevelRegistry.swift" \
    "let definitionId: String" \
    "Thinking definitions retain immutable reference IDs"
require_fixed \
    "src/ios/Providers/MinixRequestControls.swift" \
    "struct RequestCustomization" \
    "iOS request orchestration remains isolated in a Minix-owned file"
require_fixed \
    "src/ios/Views/Providers/MinixRequestCustomizationViews.swift" \
    "struct ModelRequestCustomizationSheet" \
    "iOS request customization UI remains isolated in a Minix-owned file"
require_fixed \
    "src/ios/Views/Providers/MinixRequestCustomizationViews.swift" \
    "private enum MinixRequestExpressionHelp" \
    "iOS expression-help loading remains in the Minix-owned UI file"
forbid_regex \
    "iOS provider detail does not regain expression-help loading" \
    'requestExpressionHelpText|ExpressionCapabilityHelp' \
    "src/ios/Views/Providers/ProviderInstanceDetailView.swift"
forbid_regex \
    "Transactional editors do not regain interactive-pop gesture plumbing" \
    'TransactionalPopGesture|transactionalPopGesture|interactivePopGestureRecognizer' \
    "src/ios/Views/Providers/MinixRequestCustomizationViews.swift"
require_fixed_count \
    "src/ios/Views/Providers/MinixRequestCustomizationViews.swift" \
    ".navigationBarBackButtonHidden(true)" \
    3 \
    "The three iOS transactional editors keep swipe-back disabled"
require_fixed \
    "src/ios/Views/Chat/MinixChatRequestControls.swift" \
    "struct MinixChatRequestControlsPanel" \
    "iOS chat request-controls UI remains isolated in a Minix-owned file"
require_fixed \
    "src/ios/Agent/Chat/AIChatViewModel+MinixRequestControls.swift" \
    "extension AIChatViewModel" \
    "iOS chat request-control logic remains in its Minix-owned extension"
forbid_regex \
    "iOS core chat view model does not regain Minix request-control methods" \
    'func[[:space:]]+(setThinkingDefinitionId|availableThinkingDefinitionIds|clampedThinkingDefinitionId|flushPendingThinkingLevel)\b|var[[:space:]]+(currentRequestBodyControls|currentRequestCustomizationEntry|currentRequestBodyControlSessionKey|currentRequestBodyControlModelKey)\b' \
    "src/ios/Agent/Chat/AIChatViewModel.swift"
forbid_regex \
    "iOS chat screen does not regain the request-controls implementation" \
    'struct[[:space:]]+(StructuredControlsSheetView|MinixChatRequestControlsPanel)|struct[[:space:]]+RequestControlGradientSlider' \
    "src/ios/Views/Chat/AIChatView.swift"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testControlExpressions_writeHeadersBodyAndEvaluateConditions_BitsUT" \
    "Request controls retain mixed Header and Body expression coverage"
require_fixed \
    "src/ios/Providers/MinixRequestExpression.swift" \
    "enum MinixRequestExpression" \
    "iOS expression AST remains isolated in a Minix-owned file"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/provider/MinixRequestExpression.kt" \
    "internal object MinixRequestExpression" \
    "Android expression AST remains isolated in a Minix-owned file"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/ui/settings/MinixRequestExpressionEditor.kt" \
    "R.raw.expression_capability_help" \
    "Android expression help uses localized Markdown resources"
forbid_regex \
    "Legacy expression-help string resources stay removed" \
    'Expression Capability Help Markdown|Request Expression Help V2|request_expression_help_(markdown|body)' \
    "src/ios/Localizable.xcstrings" \
    "src/ios/Views/Providers/ProviderInstanceDetailView.swift" \
    "src/android/app/src/main/res/values/strings.xml" \
    "src/android/app/src/main/res/values-zh/strings.xml" \
    "src/android/app/src/main/java/com/openminis/app/ui/settings/MinixRequestExpressionEditor.kt"
require_xcstrings_locale_absent \
    "src/ios/Localizable.xcstrings" \
    "zh-Hans" \
    "iOS built-in thinking levels remain English in Simplified Chinese" \
    "Off" "Minimal" "Low" "Med" "High" "XHigh" "Max" "Ultra"
require_help_contract \
    "src/ios/en.lproj/ExpressionCapabilityHelp.md" \
    "iOS English expression help uses grouped, complete function documentation" \
    "## Collection functions" \
    "## Numeric and length functions" \
    "## Text, encoding, JSON, and hash functions" \
    "## Dynamic and utility functions"
require_help_contract \
    "src/ios/zh-Hans.lproj/ExpressionCapabilityHelp.md" \
    "iOS Simplified Chinese expression help uses grouped, complete function documentation" \
    "## 集合函数" \
    "## 数值与长度函数" \
    "## 文本、编码、JSON 与哈希函数" \
    "## 动态与工具函数"
require_help_contract \
    "src/android/app/src/main/res/raw/expression_capability_help.md" \
    "Android English expression help uses grouped, complete function documentation" \
    "## Collection functions" \
    "## Numeric and length functions" \
    "## Text, encoding, JSON, and hash functions" \
    "## Dynamic and utility functions"
require_help_contract \
    "src/android/app/src/main/res/raw-zh/expression_capability_help.md" \
    "Android Simplified Chinese expression help uses grouped, complete function documentation" \
    "## 集合函数" \
    "## 数值与长度函数" \
    "## 文本、编码、JSON 与哈希函数" \
    "## 动态与工具函数"
require_equal_files \
    "src/ios/en.lproj/ExpressionCapabilityHelp.md" \
    "src/android/app/src/main/res/raw/expression_capability_help.md" \
    "iOS and Android English expression help stay identical"
require_equal_files \
    "src/ios/zh-Hans.lproj/ExpressionCapabilityHelp.md" \
    "src/android/app/src/main/res/raw-zh/expression_capability_help.md" \
    "iOS and Android Simplified Chinese expression help stay identical"
require_fixed \
    "src/ios/Providers/MinixRequestExpression.swift" \
    '"delete": 0...0' \
    "iOS keeps null distinct from the delete() mutation"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/provider/MinixRequestExpression.kt" \
    '"delete" to 0..0' \
    "Android keeps null distinct from the delete() mutation"
forbid_regex \
    "JSON null does not regain field-deletion semantics" \
    'value[[:space:]]+(is|==)[[:space:]]+(NSNull|JSONObject\.NULL).{0,60}(removeValue|remove)\(' \
    "src/ios/Providers/MinixRequestExpression.swift" \
    "src/android/app/src/main/java/com/openminis/app/provider/MinixRequestExpression.kt" \
    "src/android/app/src/main/java/com/openminis/app/provider/MinixRequestCustomization.kt"
forbid_regex \
    "Object literals retain colon-only field syntax" \
    'consume\("="\)[^\n]{0,80}consume\(":"\)|consume\(":"\)[^\n]{0,80}consume\("="\)' \
    "src/ios/Providers/MinixRequestExpression.swift" \
    "src/android/app/src/main/java/com/openminis/app/provider/MinixRequestExpression.kt"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    'config = {mode = "strict"}' \
    "iOS rejects equals inside object literals"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/RequestCustomizationTest.kt" \
    'testExpressionValidator_rejectsEqualsInsideObjectLiteral_BitsUT' \
    "Android rejects equals inside object literals"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/data/model/MinixThinkingLevelRegistry.kt" \
    "val definitionId: String" \
    "Android thinking definitions remain isolated with immutable IDs"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/data/model/MinixRequestControlModels.kt" \
    "data class RequestBodyControl" \
    "Android request-control models remain isolated in a Minix-owned file"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/ui/chat/MinixChatRequestControls.kt" \
    "fun MinixChatRequestControlsPanel" \
    "Android chat request-controls UI remains isolated in a Minix-owned file"
forbid_regex \
    "Android chat screen does not regain the request-controls implementation" \
    'fun[[:space:]]+(RequestControlsPanel|MinixChatRequestControlsPanel|GradientControlSlider)[[:space:]]*\(' \
    "src/android/app/src/main/java/com/openminis/app/ui/chat/ChatScreen.kt"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testControlExpressions_buildStableJSONHeaderWithLazyFallbackAndFiltering_BitsUT" \
    "iOS complex filtering and fallback coverage remains present"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/RequestCustomizationTest.kt" \
    "testControlExpressions_buildStableJSONHeaderWithLazyFallbackAndFiltering_BitsUT" \
    "Android complex filtering and fallback coverage remains present"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testEvaluateTemplate_coversRemainingFunctionsAndLazyBranches_BitsUT" \
    "iOS direct function and lazy-branch coverage remains present"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/RequestCustomizationTest.kt" \
    "testApply_coversRemainingFunctionsAndLazyBranches_BitsUT" \
    "Android direct function and lazy-branch coverage remains present"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testValidation_reportsExpressionResourceLimits_BitsUT" \
    "iOS expression source-limit coverage remains present"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/RequestCustomizationTest.kt" \
    "testExpressionValidator_reportsExpressionResourceLimits_BitsUT" \
    "Android expression source-limit coverage remains present"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testParseBodyExpressions_evaluationLimitSkipsOnlyFailingLine_BitsUT" \
    "iOS evaluation-limit failures remain isolated per line"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/RequestCustomizationTest.kt" \
    "testApply_evaluationLimitSkipsOnlyFailingLine_BitsUT" \
    "Android evaluation-limit failures remain isolated per line"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testRuntimeExpressionErrorsSkipOnlyFailingLines_BitsUT" \
    "iOS runtime expression errors remain isolated per line"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/RequestCustomizationTest.kt" \
    "testApply_runtimeExpressionErrorsSkipOnlyFailingLines_BitsUT" \
    "Android runtime expression errors remain isolated per line"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testState_newConversationUsingSameModelStartsFromDefaults_BitsUT" \
    "iOS request-control runtime state remains session-scoped"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/RequestCustomizationTest.kt" \
    "testState_newConversationUsingSameModelStartsFromDefaults_BitsUT" \
    "Android request-control runtime state remains session-scoped"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testActivateModel_AtoBtoAUsesDefaultsEachSwitch_BitsUT" \
    "iOS model switching discards prior request-control state"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/RequestCustomizationTest.kt" \
    "testActivateModel_AtoBtoAUsesDefaultsEachSwitch_BitsUT" \
    "Android model switching discards prior request-control state"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testActivateModel_sameModelPreservesStateAcrossReload_BitsUT" \
    "iOS preserves state for the same active model across reload"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/RequestCustomizationTest.kt" \
    "testActivateModel_sameModelPreservesStateAcrossReload_BitsUT" \
    "Android preserves state for the same active model across reload"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testMigrate_movesCurrentDraftSnapshot_BitsUT" \
    "iOS migrates one current draft snapshot"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/RequestCustomizationTest.kt" \
    "testMigrate_movesCurrentDraftSnapshot_BitsUT" \
    "Android migrates one current draft snapshot"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testApply_internalTaskGetsSessionButUsesConfiguredDefaults_BitsUT" \
    "iOS separates expression session from interactive control state"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testRequestBodyPatcher_preservesConversationStateFlag_BitsUT" \
    "Anthropic pending requests preserve interactive-state context"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/RequestCustomizationTest.kt" \
    "testApply_internalTaskGetsSessionButUsesConfiguredDefaults_BitsUT" \
    "Android separates expression session from interactive control state"
require_fixed \
    "src/ios/Providers/MinixRequestControls.swift" \
    "RequestBodyControlRuntimeSnapshot" \
    "iOS persists one active-model runtime snapshot"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/data/model/MinixRequestControlModels.kt" \
    "RequestBodyControlRuntimeSnapshot" \
    "Android persists one active-model runtime snapshot"
forbid_regex \
    "Request-control runtime state does not regain model-global storage keys" \
    'requestBodyControls\.state\.model\.|private const val PREFIX[[:space:]]*=[[:space:]]*"model\."' \
    "src/ios/Providers/MinixRequestControls.swift" \
    "src/android/app/src/main/java/com/openminis/app/provider/MinixRequestCustomization.kt" \
    "docs/minix/request-controls-tech.md"
forbid_regex \
    "Request-control runtime storage does not retain per-model session keys" \
    'storageKey\([^)]*modelKey|sessionKey[[:space:]]*\+[[:space:]]*[".][[:space:]]*\+[[:space:]]*modelKey' \
    "src/ios/Providers/MinixRequestControls.swift" \
    "src/android/app/src/main/java/com/openminis/app/provider/MinixRequestCustomization.kt"
forbid_regex \
    "Slider positions remain transient UI state" \
    'sliderPositionsByControlID' \
    "src/ios" \
    "src/android/app/src/main" \
    "docs/minix"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/provider/MinixRequestCustomization.kt" \
    "EVALUATION_LIMIT" \
    "Android preserves a distinct expression evaluation-limit error"
require_fixed \
    "src/ios/MinisTests/ModelRequestCustomizationPersistenceTests.swift" \
    "testProviderShare_roundTripPreservesAllRequestCustomization_BitsUT" \
    "iOS provider sharing retains complete request customization"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/data/db/ProviderConfigPersistenceTest.kt" \
    "testProviderRequestCustomization_usesSingleEnvelopeRoundTrip_BitsUT" \
    "Android provider persistence retains the shared customization envelope"
forbid_regex \
    "Request expressions do not gain an embedded JavaScript runtime" \
    'JavaScriptCore|QuickJS|JSContext|evaluateJavaScript' \
    "src/ios/Providers/MinixRequestExpression.swift" \
    "src/android/app/src/main/java/com/openminis/app/provider/MinixRequestExpression.kt"
forbid_regex \
    "Thinking alias edits do not regain cascade-renaming" \
    'renameThinkingLevelReferences' \
    "src/ios" \
    "src/android/app/src/main"
forbid_regex \
    "Custom thinking options do not regain a global catalog clamp" \
    'min\(thinkingLevel,[[:space:]]*model\.catalogMaxThinkingLevel\)|fun[[:space:]]+clampThinkingLevel\(' \
    "src/ios/Providers/AgentProvider.swift" \
    "src/android/app/src/main/java/com/openminis/app/provider/LLMProvider.kt"

require_fixed \
    "src/ios/Providers/OpenAI/OpenAIAgentProvider.swift" \
    "ThinkingRuleResolver.apply(to: &body, ctx: context)" \
    "iOS OpenAI Chat preserves the upstream Thinking Rules resolver"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/provider/openai/OpenAIProvider.kt" \
    "val trace = ThinkingRuleResolver.apply(body, ctx)" \
    "Android OpenAI Chat preserves the upstream Thinking Rules resolver"
require_fixed \
    "src/ios/Providers/OpenAI/OpenAIAgentProvider.swift" \
    "guard provider.requestCustomization?.disablesBuiltInThinkingInjection != true else { return }" \
    "iOS semantic thinking controls bypass the upstream resolver"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/provider/openai/OpenAIProvider.kt" \
    "requestCustomization?.disablesBuiltInThinkingInjection != true &&" \
    "Android semantic thinking controls bypass the upstream resolver"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/provider/openai/OpenAIProvider.kt" \
    "requestCustomization?.disablesBuiltInThinkingInjection != true &&" \
    "Android retains the upstream Mistral transport gate after the semantic-control gate"
forbid_regex \
    "Provider bodies do not duplicate resolver-owned vendor thinking branches" \
    'body\["enable_thinking"\]|body\["thinking_budget"\]|lid\.contains\("deepseek-v4"\)|\["deepseek",[[:space:]]*"glm",[[:space:]]*"kimi",[[:space:]]*"minimax"\]' \
    "src/ios/Providers/OpenAI/OpenAIAgentProvider.swift" \
    "src/ios/Providers/OpenAI/OpenAIProvider.swift"
require_fixed \
    "src/ios/Providers/LLMProviderFactory.swift" \
    "p.providerInstanceId = instance.id" \
    "iOS preserves the upstream OpenAI Chat thinking-rule wiring boundary"
forbid_regex \
    "iOS OpenAI provider does not infer its thinking-rule owner from customization mutation" \
    'providerInstanceId[[:space:]]*=[[:space:]]*requestCustomization\?\.provider\.id' \
    "src/ios/Providers/OpenAI/OpenAIProvider.swift"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testFactory_preservesUpstreamThinkingRuleInstanceScope_BitsUT" \
    "iOS tests pin upstream thinking-rule scope without disabling Minix customization"
require_fixed_count \
    "src/ios/Providers/Gemini/GeminiProvider.swift" \
    "requestCustomization?.disablesBuiltInThinkingInjection != true" \
    3 \
    "All iOS Gemini request builders honor semantic thinking controls"
require_fixed \
    "src/ios/Providers/Gemini/GeminiProvider.swift" \
    "wrapCloudCodeBody(customizedBody)" \
    "Gemini OAuth wraps the protocol body only after request customization"
forbid_regex \
    "Gemini OAuth does not apply request customization to the outer envelope" \
    'requestCustomization\?\.apply\(to:[[:space:]]*&finalBody' \
    "src/ios/Providers/Gemini/GeminiProvider.swift"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testCloudCodeCustomizationTargetsInnerRequestBody_BitsUT" \
    "iOS tests pin Gemini Cloud Code customization to the inner request"
forbid_regex \
    "Anthropic OAuth does not replay deleted reserved headers after token refresh" \
    'customHeaderPatch|removedNames' \
    "src/ios/Providers/Anthropic/OAuthHTTPClient.swift"
forbid_regex \
    "iOS tests do not promise transport-level Authorization deletion" \
    'deletedAuthorizationSurvivesOAuthRefresh' \
    "src/ios/MinisTests/RequestCustomizationTests.swift"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/thinking/GeminiThinkingBranchTest.kt" \
    "ThinkingLevel.OFF, ThinkingLevel.MINIMAL, ThinkingLevel.LOW" \
    "Android Gemini tests cover the Minix Minimal tier"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/provider/thinking/ThinkingRuleResolver.kt" \
    "level == ThinkingLevel.OFF || level == ThinkingLevel.MINIMAL" \
    "Android Gemini 3 preserves the Minix Minimal compatibility floor"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testApplyDefaultChatThinking_preservesProviderScopedUserRules_BitsUT" \
    "iOS integration tests preserve Provider Thinking Rules"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/OpenAIProviderTest.kt" \
    "testStreamMessage_semanticThinkingControlSkipsResolver_BitsUT" \
    "Android OpenAI integration tests cover resolver bypass"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/ThinkingRulesRegressionTest.kt" \
    "provider custom rule cannot bypass the mistral transport gate" \
    "Android tests pin the upstream Mistral transport gate"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/data/db/ProviderDatabase.kt" \
    "version = 4" \
    "Android retains the upstream Provider Thinking Rules schema"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/data/db/ProviderDatabase.kt" \
    "MIGRATION_3_4" \
    "Android retains the upstream Provider Thinking Rules migration"
require_file \
    "src/ios/Views/Providers/ThinkingRulesSection.swift" \
    "iOS retains the upstream Provider Thinking Rules UI"
require_file \
    "src/android/app/src/main/java/com/openminis/app/ui/settings/ThinkingRulesSection.kt" \
    "Android retains the upstream Provider Thinking Rules UI"
require_fixed \
    "src/ios/Agent/Sync/V2/SyncedTypes.swift" \
    "ProviderThinkingRuleV3" \
    "iOS retains Provider Thinking Rules sync"
require_fixed \
    "src/ios/Agent/Backup/BackupExporter.swift" \
    "thinkingRules:" \
    "iOS backup retains Provider Thinking Rules"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/backup/BackupExporter.kt" \
    "thinkingRules =" \
    "Android backup retains Provider Thinking Rules"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testApplyDefaultResponsesThinking_preservesCodexOffFallbackAndSemanticOverride_BitsUT" \
    "iOS tests preserve the Codex Off fallback and semantic override"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/OpenAIProviderTest.kt" \
    "testCodexResponses_offKeepsRequiredLowUnlessSemanticControlOwnsThinking_BitsUT" \
    "Android tests preserve the Codex Off fallback and semantic override"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/AnthropicProviderTest.kt" \
    "testStreamMessage_appliesCustomHeaderAndBodyToRequest_BitsUT" \
    "Android Anthropic integration retains request customization coverage"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/GeminiProviderTest.kt" \
    "testStreamMessage_thinkingControlInjectsThinkingConfigIntoRequestBody_BitsUT" \
    "Android Gemini integration retains request-control coverage"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/data/ThinkingLevelTest.kt" \
    "immutableDefinitionId_survivesAliasRenameWithoutReferenceMigration" \
    "Android retains stable thinking-definition reference coverage"
require_fixed \
    "src/ios/Providers/LLMTypes.swift" \
    "case off" \
    "iOS ThinkingLevel retains the App-level off case"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/data/model/ProviderConfig.kt" \
    "OFF," \
    "Android ThinkingLevel retains the App-level OFF case"
forbid_regex \
    "Built-in thinking semantics do not regain auto, none, or Ultra wire output" \
    '^[[:space:]]*case[[:space:]]+(auto|none)([[:space:]]|$)|^[[:space:]]*(AUTO|NONE),|autoDefinitionId|noneDefinitionId|allowsCodexUltra|case[[:space:]]+\.ultra:[[:space:]]*"ultra"|ThinkingLevel\.ULTRA[[:space:]]*->[[:space:]]*"ultra"' \
    "src/ios/Providers/LLMTypes.swift" \
    "src/ios/Providers/MinixThinkingLevelRegistry.swift" \
    "src/ios/Providers/OpenAI/OpenAIAgentProvider.swift" \
    "src/android/app/src/main/java/com/openminis/app/data/model/ProviderConfig.kt" \
    "src/android/app/src/main/java/com/openminis/app/data/model/MinixThinkingLevelRegistry.kt" \
    "src/android/app/src/main/java/com/openminis/app/provider/ThinkingLevelCatalog.kt" \
    "src/android/app/src/main/java/com/openminis/app/provider/openai/OpenAIProvider.kt"

forbid_regex \
    "Codex requests do not regain post-customization field restoration" \
    'protectCodexOAuthRequest|enforceCodexOAuthBodyRequirements|enforceCodexOAuthHeaders' \
    "src/ios/Providers/OpenAI/OpenAIProvider.swift" \
    "src/android/app/src/main/java/com/openminis/app/provider/openai/OpenAIProvider.kt"
require_fixed \
    "src/ios/Agent/Sync/V2/SyncedTypes.swift" \
    "ThinkingLevelDefinitionsV3" \
    "App-level thinking definitions remain CloudKit-syncable"
require_fixed \
    "src/ios/Agent/Chat/ChatStore.swift" \
    '"ThinkingLevelDefinitionsV3"' \
    "App-level thinking definitions remain in the outbound sync whitelist"
require_fixed \
    "src/ios/Agent/Sync/V2/UploadPolicy.swift" \
    '"ThinkingLevelDefinitionsV3"' \
    "The Providers upload toggle governs app-level thinking definitions"
require_fixed \
    "src/ios/Agent/Sync/V2/ForceSyncHelper.swift" \
    'recordType: "ThinkingLevelDefinitionsV3"' \
    "Provider Force Sync requeues app-level thinking definitions"
require_fixed \
    "src/ios/Views/Chat/AIChatView.swift" \
    "inputPopupOverlay" \
    "Chat input popups remain in the unified overlay"

require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/RequestCustomizationTest.kt" \
    "testApply_usesProviderThenModelThenControlPriority_BitsUT" \
    "Android request layer ordering behavior test remains present"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/provider/ProviderFactory.kt" \
    "val requestCustomization =" \
    "Android provider factory creates shared request customization"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/provider/ProviderFactory.kt" \
    "requestCustomization = requestCustomization" \
    "Android Codex factory passes request customization"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/data/model/ProviderConfig.kt" \
    "var defaultThinkingDefinitionId: String?" \
    "Android model groups persist stable thinking definition IDs"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/ui/chat/ChatViewModel.kt" \
    "internal val _thinkingDefinitionId" \
    "Android sessions retain stable thinking definition IDs"
require_fixed \
    "src/ios/Agent/Chat/AIChatViewModel+Fallback.swift" \
    "usesFallbackRequestControlDefaults: inout Bool" \
    "iOS fallback routing carries candidate Request Control state"
require_fixed_count \
    "src/ios/Agent/Chat/AIChatViewModel+Fallback.swift" \
    "usesFallbackRequestControlDefaults = true" \
    4 \
    "Every iOS fallback advance switches to candidate Request Control defaults"
require_fixed \
    "src/ios/Agent/Chat/AIChatViewModel+Fallback.swift" \
    "var fallbackProvider = provider" \
    "iOS empty-response fallback carries the actual candidate provider"
require_fixed \
    "src/ios/Agent/Chat/AIChatViewModel+Fallback.swift" \
    "func assembledAgentSystemPrompt(" \
    "Every iOS fallback candidate uses the complete conversation prompt builder"
require_fixed_count \
    "src/ios/Agent/Chat/AIChatViewModel+Fallback.swift" \
    "ProviderConfigStore.shared.setBinding(binding, for: sid)" \
    3 \
    "iOS preserves upstream immediate fallback binding updates"
require_fixed \
    "src/ios/Agent/Chat/AIChatViewModel+Fallback.swift" \
    "if pendingModelSwitch {" \
    "iOS fallback binding still yields to a newer model selection"
forbid_regex \
    "iOS fallback does not add a terminal-result transaction layer" \
    'fallbackResponseMayCommit|fallbackSelectionMayCommit|thinkingSelectionRevision' \
    "src/ios/Agent/Chat/AIChatViewModel.swift" \
    "src/ios/Agent/Chat/AIChatViewModel+Fallback.swift" \
    "src/ios/Agent/Chat/AIChatViewModel+MinixRequestControls.swift"
forbid_regex \
    "iOS Thinking Rules regression suites remain in the XCTest target" \
    '^[[:space:]]*(ThinkingRulesRegressionTests|ThinkingWireGoldenSnapshotTests)\.swift,' \
    "src/ios/Minis.xcodeproj/project.pbxproj"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testFallbackThinkingSelection_preservesConversationAndClampsToCandidate_BitsUT" \
    "iOS tests pin fallback semantic inheritance and candidate clamping"
forbid_regex \
    "Fallback does not replace session thinking with a candidate control default" \
    'defaultRequestControlThinkingDefinitionId' \
    "src/ios/Agent/Chat/AIChatViewModel+MinixRequestControls.swift" \
    "src/android/app/src/main/java/com/openminis/app/provider/LLMProvider.kt" \
    "src/android/app/src/main/java/com/openminis/app/provider/openai/OpenAIProvider.kt" \
    "src/android/app/src/main/java/com/openminis/app/provider/anthropic/AnthropicProvider.kt" \
    "src/android/app/src/main/java/com/openminis/app/provider/gemini/GeminiProvider.kt" \
    "src/android/app/src/main/java/com/openminis/app/ui/chat/ChatViewModel.kt"
forbid_regex \
    "Request customization does not expose candidate thinking defaults" \
    '(var|val)[[:space:]]+defaultThinkingDefinitionId' \
    "src/ios/Providers/MinixRequestControls.swift" \
    "src/android/app/src/main/java/com/openminis/app/provider/MinixRequestCustomization.kt"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/ui/chat/ChatViewModel.kt" \
    "this@ChatViewModel.currentProvider = next" \
    "Android preserves upstream immediate fallback binding updates"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/ui/chat/ChatViewModel.kt" \
    "fallbackMayRebindSession(" \
    "Android fallback binding still yields to a newer model selection"
forbid_regex \
    "Android fallback does not add a terminal-result transaction layer" \
    'requestControlStateMayCommit|requestResultMayCommit|thinkingSelectionRevision|fallbackEntryIdAwaitingCommit' \
    "src/android/app/src/main/java/com/openminis/app/ui/chat/ChatViewModel.kt"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/provider/gemini/GeminiProvider.kt" \
    'lastFinishReason ?: "end_turn"' \
    "Android Gemini preserves the upstream missing-finish fallback"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/ui/chat/ChatViewModel.kt" \
    "currentProvider.model.supportsReasoning != false" \
    "Android sends selected thinking for models without explicit capability metadata"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/ui/chat/ChatViewModel.kt" \
    "provider.thinkingDefinitionId = null" \
    "Android internal chat requests clear interactive thinking state"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/speech/correction/CorrectionStrategy.kt" \
    "provider.thinkingDefinitionId = null" \
    "Android correction requests clear interactive thinking state"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/ui/chat/FallbackRespectsUserSwitchTest.kt" \
    "fallback requests keep conversation thinking and use candidate control defaults" \
    "Android tests pin fallback semantic inheritance and ordinary control defaults"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/RequestCustomizationTest.kt" \
    "testInternalTask_keepsNullThinkingSoControlDefaultWins_BitsUT" \
    "Android internal requests preserve semantic control defaults"
require_fixed \
    "src/ios/MinisTests/RequestCustomizationTests.swift" \
    "testApply_withoutControlsKeepsProviderAndModelLayers_BitsUT" \
    "iOS tests pin non-conversation base customization without controls"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/RequestCustomizationTest.kt" \
    "testApply_withoutControlsKeepsProviderAndModelLayers_BitsUT" \
    "Android tests pin non-conversation base customization without controls"
forbid_regex \
    "Android does not add transport-level reserved Header finalization" \
    'applyFinalHeaderMutations|enforceFinalHeaderMutations|effectiveDeletedHeaders|FinalRequestHeaders' \
    "src/android/app/src/main/java/com/openminis/app/provider"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/OpenAIEditImageTest.kt" \
    "testEditImage_appliesBaseCustomizationWithoutControls_BitsUT" \
    "Android OpenAI image edits retain base customization and exclude controls"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/OpenAIEditImageTest.kt" \
    "testEditImage_emptyTokenOmitsAuthorization_BitsUT" \
    "Android OpenAI image edits preserve upstream empty-token auth behavior"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/OpenAIProviderTest.kt" \
    "testSendMessage_emptyTokenOmitsAuthorization_BitsUT" \
    "Android OpenAI chat preserves upstream empty-token auth behavior"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/OpenAIProviderTest.kt" \
    "testRawPassthrough_emptyTokenOmitsAuthorization_BitsUT" \
    "Android OpenAI raw passthrough preserves upstream empty-token auth behavior"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/provider/OpenAIProviderTest.kt" \
    "testImageGeneration_emptyTokenOmitsAuthorization_BitsUT" \
    "Android OpenAI image generation preserves upstream empty-token auth behavior"
require_fixed \
    "src/ios/Views/Providers/MinixRequestCustomizationViews.swift" \
    ".thinkingExpressions(" \
    "iOS newly-added built-in thinking options reuse route-aware templates"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/ui/settings/MinixModelRequestCustomizationEditor.kt" \
    "RequestBodyControlDefaults" \
    "Android newly-added built-in thinking options reuse route-aware templates"
require_fixed_count \
    "src/ios/Providers/OpenAI/OpenAIProvider.swift" \
    "includeControls: false" \
    3 \
    "iOS raw and Images API paths skip conversation Request Controls"
require_fixed_count \
    "src/android/app/src/main/java/com/openminis/app/provider/openai/OpenAIProvider.kt" \
    "includeControls = false" \
    3 \
    "Android raw and Images API paths skip conversation Request Controls"
require_fixed \
    "src/ios/Providers/OpenAI/OpenAIProvider.swift" \
    "includeRequestControls: false" \
    "iOS Codex image generation skips conversation Request Controls"
require_fixed \
    "src/android/app/src/main/java/com/openminis/app/provider/openai/OpenAIProvider.kt" \
    "includeControls = !isCodexImageModel" \
    "Android Codex image generation skips conversation Request Controls"
require_fixed \
    "src/ios/en.lproj/ExpressionCapabilityHelp.md" \
    'Do not override or delete `Authorization` or `Content-Type`' \
    "English expression help documents reserved transport Headers"
require_fixed \
    "src/ios/zh-Hans.lproj/ExpressionCapabilityHelp.md" \
    '请勿覆盖或删除 `Authorization` 和 `Content-Type`' \
    "Simplified Chinese expression help documents reserved transport Headers"
require_fixed \
    "src/android/app/src/test/java/com/openminis/app/ui/chat/SwitchModelMidTurnEdgeTest.kt" \
    "currentProvider.model.supportsReasoning != false" \
    "Android tests pin the unknown-capability thinking gate"
forbid_regex \
    "Android provider persistence does not regain custom User-Agent" \
    'custom_user_agent|customUserAgent' \
    "src/android/app/src/main/java/com/openminis/app/data/db/ProviderDatabase.kt" \
    "src/android/app/src/main/java/com/openminis/app/data/db/ProviderInstanceEntity.kt"
forbid_regex \
    "Android Codex requests do not skip request customization" \
    'if[[:space:]]*\(!\(isOAuth[[:space:]]*&&[[:space:]]*!forceChatCompletions\)\)' \
    "src/android/app/src/main/java/com/openminis/app/provider/openai/OpenAIProvider.kt"
forbid_regex \
    "Android thinking-control detection remains semantic, not payload text scanning" \
    'lower\.contains\("reasoning"\)|lower\.contains\("thinking"\)|lower\.contains\("effort"\)' \
    "src/android/app/src/main/java/com/openminis/app/provider/MinixRequestCustomization.kt"
require_file \
    "scripts/minix-debug.sh" \
    "Shared-key Android Debug workflow remains available"
require_file \
    "scripts/minix-test.sh" \
    "Cross-platform test workflow remains available"
require_file \
    "scripts/minix-android-toolchain.sh" \
    "Android scripts share one JDK 17 resolver"
require_file \
    "scripts/minix-bootstrap.sh" \
    "Fresh-checkout bootstrap workflow remains available"
require_file \
    "scripts/minix-deps.sh" \
    "Native dependency reconciliation remains centralized"
require_fixed \
    "scripts/minix-bootstrap.sh" \
    '"$REPO_ROOT/scripts/minix-deps.sh"' \
    "Bootstrap delegates native dependencies to the reconciler"
require_fixed \
    "scripts/minix-bootstrap.sh" \
    '"$REPO_ROOT/scripts/minix-debug.sh"' \
    "Bootstrap produces a Debug build through the shared workflow"
require_fixed \
    "scripts/minix-sync.sh" \
    '"$REPO_ROOT/scripts/minix-deps.sh"' \
    "Upstream sync delegates native dependencies to the reconciler"
forbid_regex \
    "Upstream sync does not own individual native dependency rules" \
    'deps/(build_(ffmpeg|ish|lame|proot|rclone_(android|ios))|prepare_alpine_rootfs)\.sh|prepare_android_sandbox\.sh' \
    "scripts/minix-sync.sh"
require_fixed \
    "src/android/app/build.gradle.kts" \
    'signingConfigs.getByName("minix")' \
    "Android Debug, Perf, and Release can share the persistent Minix certificate"
require_fixed \
    "scripts/minix-android-toolchain.sh" \
    'openjdk@17/libexec/openjdk.jdk/Contents/Home' \
    "Android scripts use a Gradle-compatible JDK 17"

if [ "$FAILED" -ne 0 ]; then
    echo "Minix invariant check failed. Review the upstream diff before continuing." >&2
    exit 1
fi

echo "All Minix invariants passed."

import CryptoKit
import CoreFoundation
import Foundation

private let requestExpressionLogger = AppLogger(
    category: "RequestExpression"
)

/// [Minix] Safe expression evaluator for request customization.
///
/// This lives outside upstream provider files so the Minix expression language
/// can evolve without repeatedly touching merge hotspots.
enum MinixRequestExpression {
    enum Target {
        case header
        case body
        case control
    }

    struct ValidationIssue: Equatable {
        let line: Int
        let message: String
    }

    enum ExpressionError: LocalizedError {
        case missingAssignment
        case invalidTarget
        case invalidExpression(String)
        case unknownIdentifier(String)
        case unknownFunction(String)
        case invalidArguments(String)
        case typeMismatch(String)
        case evaluationLimit

        var errorDescription: String? {
            switch self {
            case .missingAssignment:
                return String(localized: "Use key = value format.")
            case .invalidTarget:
                return String(localized: "Invalid request expression path.")
            case .invalidExpression:
                return String(localized: "Invalid expression syntax.")
            case .unknownIdentifier, .unknownFunction:
                return String(
                    localized: "Unknown template variable or function."
                )
            case .invalidArguments, .typeMismatch:
                return String(localized: "Invalid function arguments.")
            case .evaluationLimit:
                return String(
                    localized: "Expression evaluation limit exceeded."
                )
            }
        }
    }

    fileprivate indirect enum Value: Equatable {
        case missing
        case null
        case delete
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([Value])
        case object([String: Value], caseInsensitive: Bool)

        var isMissingOrNull: Bool {
            switch self {
            case .missing, .null:
                return true
            default:
                return false
            }
        }
    }

    private indirect enum Expression {
        case literal(Value)
        case template(String)
        case identifier(String)
        case array([Expression])
        case object([(String, Expression)])
        case unary(String, Expression)
        case binary(String, Expression, Expression)
        case conditional(Expression, Expression, Expression)
        case call(String, [Expression])
        case member(Expression, String)
        case index(Expression, Expression)
        case method(Expression, String, [Expression])
    }

    private struct Assignment {
        let path: [String]
        let expression: Expression
    }

    private final class DeleteMarker {}
    private static let deleteMarker = DeleteMarker()

    private struct Environment {
        let context: RequestCustomizationExpression.Context
        var locals: [String: Value] = [:]
        var steps = 0

        mutating func tick() throws {
            steps += 1
            if steps > 100_000 {
                throw ExpressionError.evaluationLimit
            }
        }
    }

    private enum Token: Equatable {
        case identifier(String)
        case number(String)
        case string(String)
        case symbol(String)
        case eof
    }

    private struct Lexer {
        let input: String
        var index: String.Index

        init(_ input: String) {
            self.input = input
            index = input.startIndex
        }

        mutating func tokenize() throws -> [Token] {
            var tokens: [Token] = []
            while true {
                let token = try nextToken()
                tokens.append(token)
                if tokens.count > 1_024 {
                    throw ExpressionError.evaluationLimit
                }
                if token == .eof {
                    return tokens
                }
            }
        }

        private mutating func nextToken() throws -> Token {
            skipWhitespace()
            guard index < input.endIndex else {
                return .eof
            }
            let character = input[index]
            if character == "\"" || character == "'" {
                return try readString(quote: character)
            }
            if character.isNumber ||
                (character == "." && peek()?.isNumber == true) {
                return readNumber()
            }
            if character.isLetter || character == "_" {
                return readIdentifier()
            }
            for symbol in ["&&", "||", "??", ">=", "<=", "==", "!="] {
                if input[index...].hasPrefix(symbol) {
                    index = input.index(index, offsetBy: symbol.count)
                    return .symbol(symbol)
                }
            }
            if "+-*/%><!?:.,()[]{}=".contains(character) {
                index = input.index(after: index)
                return .symbol(String(character))
            }
            throw ExpressionError.invalidExpression(
                "unexpected character \(character)"
            )
        }

        private mutating func skipWhitespace() {
            while index < input.endIndex,
                  input[index].isWhitespace {
                index = input.index(after: index)
            }
        }

        private func peek() -> Character? {
            let next = input.index(after: index)
            return next < input.endIndex ? input[next] : nil
        }

        private mutating func readIdentifier() -> Token {
            let start = index
            while index < input.endIndex {
                let character = input[index]
                guard character.isLetter ||
                        character.isNumber ||
                        character == "_" else {
                    break
                }
                index = input.index(after: index)
            }
            return .identifier(String(input[start..<index]))
        }

        private mutating func readNumber() -> Token {
            let start = index
            var hasDot = false
            while index < input.endIndex {
                let character = input[index]
                if character == "." {
                    if hasDot {
                        break
                    }
                    hasDot = true
                } else if !character.isNumber {
                    break
                }
                index = input.index(after: index)
            }
            return .number(String(input[start..<index]))
        }

        private mutating func readString(
            quote: Character
        ) throws -> Token {
            index = input.index(after: index)
            var result = ""
            while index < input.endIndex {
                let character = input[index]
                if character == quote {
                    index = input.index(after: index)
                    return .string(result)
                }
                if character == "\\" {
                    index = input.index(after: index)
                    guard index < input.endIndex else {
                        break
                    }
                    switch input[index] {
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "\\": result.append("\\")
                    case "\"": result.append("\"")
                    case "'": result.append("'")
                    default: result.append(input[index])
                    }
                } else {
                    result.append(character)
                }
                index = input.index(after: index)
            }
            throw ExpressionError.invalidExpression(
                "unterminated string"
            )
        }
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0

        init(_ source: String) throws {
            var lexer = Lexer(source)
            tokens = try lexer.tokenize()
        }

        mutating func parse() throws -> Expression {
            let expression = try parseConditional()
            guard current == .eof else {
                throw ExpressionError.invalidExpression(
                    "unexpected token"
                )
            }
            return expression
        }

        private var current: Token {
            tokens[min(index, tokens.count - 1)]
        }

        private mutating func advance() -> Token {
            let token = current
            index = min(index + 1, tokens.count - 1)
            return token
        }

        private mutating func consume(
            _ symbol: String
        ) -> Bool {
            guard current == .symbol(symbol) else {
                return false
            }
            _ = advance()
            return true
        }

        private mutating func expect(
            _ symbol: String
        ) throws {
            guard consume(symbol) else {
                throw ExpressionError.invalidExpression(
                    "expected \(symbol)"
                )
            }
        }

        private mutating func parseConditional()
            throws -> Expression {
            let condition = try parseCoalescing()
            guard consume("?") else {
                return condition
            }
            let trueValue = try parseConditional()
            try expect(":")
            let falseValue = try parseConditional()
            return .conditional(
                condition,
                trueValue,
                falseValue
            )
        }

        private mutating func parseCoalescing()
            throws -> Expression {
            let lhs = try parseOr()
            if consume("??") {
                return .binary(
                    "??",
                    lhs,
                    try parseCoalescing()
                )
            }
            return lhs
        }

        private mutating func parseOr() throws -> Expression {
            var expression = try parseAnd()
            while consume("||") {
                expression = .binary(
                    "||",
                    expression,
                    try parseAnd()
                )
            }
            return expression
        }

        private mutating func parseAnd() throws -> Expression {
            var expression = try parseEquality()
            while consume("&&") {
                expression = .binary(
                    "&&",
                    expression,
                    try parseEquality()
                )
            }
            return expression
        }

        private mutating func parseEquality()
            throws -> Expression {
            var expression = try parseComparison()
            while case .symbol(let symbol) = current,
                  symbol == "==" || symbol == "!=" {
                _ = advance()
                expression = .binary(
                    symbol,
                    expression,
                    try parseComparison()
                )
            }
            return expression
        }

        private mutating func parseComparison()
            throws -> Expression {
            var expression = try parseTerm()
            while case .symbol(let symbol) = current,
                  [">", ">=", "<", "<="].contains(symbol) {
                _ = advance()
                expression = .binary(
                    symbol,
                    expression,
                    try parseTerm()
                )
            }
            return expression
        }

        private mutating func parseTerm() throws -> Expression {
            var expression = try parseFactor()
            while case .symbol(let symbol) = current,
                  symbol == "+" || symbol == "-" {
                _ = advance()
                expression = .binary(
                    symbol,
                    expression,
                    try parseFactor()
                )
            }
            return expression
        }

        private mutating func parseFactor()
            throws -> Expression {
            var expression = try parseUnary()
            while case .symbol(let symbol) = current,
                  ["*", "/", "%"].contains(symbol) {
                _ = advance()
                expression = .binary(
                    symbol,
                    expression,
                    try parseUnary()
                )
            }
            return expression
        }

        private mutating func parseUnary() throws -> Expression {
            if case .symbol(let symbol) = current,
               ["!", "-", "+"].contains(symbol) {
                _ = advance()
                return .unary(
                    symbol,
                    try parseUnary()
                )
            }
            return try parsePostfix()
        }

        private mutating func parsePostfix()
            throws -> Expression {
            var expression = try parsePrimary()
            while true {
                if consume(".") {
                    guard case .identifier(let name) = advance()
                    else {
                        throw ExpressionError.invalidExpression(
                            "expected member name"
                        )
                    }
                    if consume("(") {
                        expression = .method(
                            expression,
                            name,
                            try parseArguments(afterOpening: true)
                        )
                    } else {
                        expression = .member(expression, name)
                    }
                    continue
                }
                if consume("[") {
                    let subscriptExpression =
                        try parseConditional()
                    try expect("]")
                    expression = .index(
                        expression,
                        subscriptExpression
                    )
                    continue
                }
                return expression
            }
        }

        private mutating func parsePrimary()
            throws -> Expression {
            switch advance() {
            case .number(let raw):
                if raw.contains("."),
                   let value = Double(raw) {
                    return .literal(.double(value))
                }
                guard let value = Int(raw) else {
                    throw ExpressionError.invalidExpression(raw)
                }
                return .literal(.int(value))
            case .string(let value):
                return value.contains("{{")
                    ? .template(value)
                    : .literal(.string(value))
            case .identifier(let name):
                switch name.lowercased() {
                case "true":
                    return .literal(.bool(true))
                case "false":
                    return .literal(.bool(false))
                case "null":
                    return .literal(.null)
                default:
                    if consume("(") {
                        return .call(
                            name,
                            try parseArguments(afterOpening: true)
                        )
                    }
                    return .identifier(name)
                }
            case .symbol("("):
                let expression = try parseConditional()
                try expect(")")
                return expression
            case .symbol("["):
                return try parseArray()
            case .symbol("{"):
                return try parseObject()
            default:
                throw ExpressionError.invalidExpression(
                    "expected value"
                )
            }
        }

        private mutating func parseArguments(
            afterOpening: Bool
        ) throws -> [Expression] {
            if consume(")") {
                return []
            }
            var arguments: [Expression] = []
            repeat {
                arguments.append(try parseConditional())
            } while consume(",")
            try expect(")")
            return arguments
        }

        private mutating func parseArray()
            throws -> Expression {
            if consume("]") {
                return .array([])
            }
            var elements: [Expression] = []
            repeat {
                elements.append(try parseConditional())
            } while consume(",")
            try expect("]")
            return .array(elements)
        }

        private mutating func parseObject()
            throws -> Expression {
            if consume("}") {
                return .object([])
            }
            var fields: [(String, Expression)] = []
            repeat {
                let key: String
                switch advance() {
                case .identifier(let value),
                     .string(let value):
                    key = value
                default:
                    throw ExpressionError.invalidExpression(
                        "expected object key"
                    )
                }
                guard consume(":") else {
                    throw ExpressionError.invalidExpression(
                        "expected :"
                    )
                }
                fields.append((
                    key,
                    try parseConditional()
                ))
            } while consume(",")
            try expect("}")
            return .object(fields)
        }
    }

    static func validationIssues(
        _ expressions: [String],
        target: Target
    ) -> [ValidationIssue] {
        expressions.enumerated().compactMap { index, line in
            guard !line.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                return nil
            }
            do {
                let assignment = try compileAssignment(line)
                try validateTarget(
                    assignment.path,
                    target: target
                )
                try validateExpression(
                    assignment.expression,
                    variables: []
                )
                return nil
            } catch {
                return ValidationIssue(
                    line: index + 1,
                    message: error.localizedDescription
                )
            }
        }
    }

    static func applyHeaderExpressions(
        _ expressions: [String],
        to headers: inout [String: String],
        context: RequestCustomizationExpression.Context
    ) throws {
        try evaluateHeaderExpressions(
            expressions,
            context: context
        ) { name, value in
            switch value {
            case .set(let text):
                setHeader(text, for: name, in: &headers)
            case .delete:
                removeHeader(name, from: &headers)
            }
        }
    }

    private enum HeaderMutation {
        case set(String)
        case delete
    }

    private static func evaluateHeaderExpressions(
        _ expressions: [String],
        context: RequestCustomizationExpression.Context,
        apply: (String, HeaderMutation) throws -> Void
    ) throws {
        var workingHeaders = context.headers
        for (index, line) in expressions.enumerated() {
            guard !line.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                continue
            }
            do {
                let assignment = try compileAssignment(line)
                try validateTarget(
                    assignment.path,
                    target: .header
                )
                var environment = Environment(
                    context: replacing(
                        context,
                        headers: workingHeaders
                    )
                )
                let value = try evaluate(
                    assignment.expression,
                    environment: &environment
                )
                guard value != .missing else {
                    continue
                }
                let name = assignment.path[0]
                if value == .delete {
                    try apply(name, .delete)
                    removeHeader(name, from: &workingHeaders)
                } else {
                    guard value != .null else {
                        throw ExpressionError.typeMismatch(
                            "headers require text or delete()"
                        )
                    }
                    let text = try stringify(value)
                    try apply(name, .set(text))
                    setHeader(
                        text,
                        for: name,
                        in: &workingHeaders
                    )
                }
            } catch {
                logRuntimeIssue(
                    target: .header,
                    zeroBasedLine: index,
                    error: error
                )
            }
        }
    }

    static func parseBodyExpressions(
        _ expressions: [String],
        context: RequestCustomizationExpression.Context
    ) throws -> [String: Any] {
        var result: [String: Any] = [:]
        var workingBody = context.body
        for (index, line) in expressions.enumerated() {
            guard !line.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                continue
            }
            do {
                let assignment = try compileAssignment(line)
                try validateTarget(
                    assignment.path,
                    target: .body
                )
                var environment = Environment(
                    context: replacing(
                        context,
                        body: workingBody
                    )
                )
                let value = try evaluate(
                    assignment.expression,
                    environment: &environment
                )
                guard value != .missing else {
                    continue
                }
                var lineOverlay: [String: Any] = [:]
                put(
                    try toAny(value),
                    at: assignment.path,
                    in: &lineOverlay
                )
                result = mergeOverlay(
                    result,
                    with: lineOverlay
                )
                workingBody = merge(
                    workingBody,
                    with: lineOverlay
                )
            } catch {
                logRuntimeIssue(
                    target: .body,
                    zeroBasedLine: index,
                    error: error
                )
            }
        }
        return result
    }

    static func applyControlExpressions(
        _ expressions: [String],
        to body: inout [String: Any],
        headers: inout [String: String],
        context: RequestCustomizationExpression.Context
    ) throws {
        for (index, line) in expressions.enumerated() {
            guard !line.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                continue
            }
            do {
                let assignment = try compileAssignment(line)
                try validateTarget(
                    assignment.path,
                    target: .control
                )
                var environment = Environment(
                    context: replacing(
                        context,
                        headers: headers,
                        body: body
                    )
                )
                let value = try evaluate(
                    assignment.expression,
                    environment: &environment
                )
                guard value != .missing else {
                    continue
                }
                if assignment.path[0] == "headers" {
                    let name = assignment.path[1]
                    if value == .delete {
                        removeHeader(name, from: &headers)
                    } else {
                        guard value != .null else {
                            throw ExpressionError.typeMismatch(
                                "headers require text or delete()"
                            )
                        }
                        setHeader(
                            try stringify(value),
                            for: name,
                            in: &headers
                        )
                    }
                } else {
                    var overlay: [String: Any] = [:]
                    put(
                        try toAny(value),
                        at: Array(
                            assignment.path.dropFirst()
                        ),
                        in: &overlay
                    )
                    body = merge(body, with: overlay)
                }
            } catch {
                logRuntimeIssue(
                    target: .control,
                    zeroBasedLine: index,
                    error: error
                )
            }
        }
    }

    private static func logRuntimeIssue(
        target: Target,
        zeroBasedLine: Int,
        error: Error
    ) {
        let kind: String
        if let expressionError = error as? ExpressionError {
            kind = String(describing: expressionError)
        } else {
            kind = String(describing: type(of: error))
        }
        requestExpressionLogger.warning(
            "Skipped \(String(describing: target)) expression " +
                "line \(zeroBasedLine + 1): \(kind)"
        )
    }

    static func evaluateTemplate(
        _ raw: String,
        context: RequestCustomizationExpression.Context
    ) throws -> Any {
        var environment = Environment(context: context)
        let expression = try compileValue(raw)
        let value = try evaluate(
            expression,
            environment: &environment
        )
        guard value != .missing else {
            throw ExpressionError.invalidExpression(
                "missing value"
            )
        }
        return try toAny(value)
    }

    static func merge(
        _ base: [String: Any],
        with overlay: [String: Any]
    ) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if value is DeleteMarker {
                result.removeValue(forKey: key)
            } else if let rhs = value as? [String: Any] {
                let lhs = result[key] as? [String: Any] ?? [:]
                result[key] = merge(lhs, with: rhs)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func mergeOverlay(
        _ base: [String: Any],
        with overlay: [String: Any]
    ) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if let lhs = result[key] as? [String: Any],
               let rhs = value as? [String: Any] {
                result[key] = mergeOverlay(lhs, with: rhs)
            } else {
                // Preserve NSNull until this overlay is applied to the request.
                result[key] = value
            }
        }
        return result
    }

    private static func compileAssignment(
        _ raw: String
    ) throws -> Assignment {
        guard let assignment = assignmentIndex(in: raw)
        else {
            throw ExpressionError.missingAssignment
        }
        let lhs = String(raw[..<assignment])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = String(raw[raw.index(after: assignment)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty, !rhs.isEmpty else {
            throw ExpressionError.missingAssignment
        }
        return Assignment(
            path: try parseTargetPath(lhs),
            expression: try compileValue(rhs)
        )
    }

    private static func compileValue(
        _ raw: String
    ) throws -> Expression {
        let trimmed = raw.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        try validateSourceLimits(trimmed)
        if isWholeTemplate(trimmed) {
            let inner = String(
                trimmed.dropFirst(2).dropLast(2)
            ).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            var parser = try Parser(inner)
            return try parser.parse()
        }
        if trimmed.contains("{{") {
            return .template(unquoteIfNeeded(trimmed))
        }
        var parser = try Parser(trimmed)
        return try parser.parse()
    }

    private static func validateTarget(
        _ path: [String],
        target: Target
    ) throws {
        switch target {
        case .header:
            guard path.count == 1 else {
                throw ExpressionError.invalidTarget
            }
        case .body:
            guard !path.isEmpty else {
                throw ExpressionError.invalidTarget
            }
        case .control:
            guard path.count >= 2,
                  path[0] == "body" ||
                    (path[0] == "headers" && path.count == 2)
            else {
                throw ExpressionError.invalidTarget
            }
        }
    }

    private static let knownFunctions: [String: ClosedRange<Int>] = [
        "if": 3...3,
        "exists": 1...1,
        "append": 2...Int.max,
        "concat": 1...Int.max,
        "remove": 2...Int.max,
        "update": 3...3,
        "insert": 3...3,
        "remove_at": 2...2,
        "min": 1...Int.max,
        "max": 1...Int.max,
        "sum": 1...Int.max,
        "avg": 1...Int.max,
        "count": 1...1,
        "length": 1...1,
        "clamp": 3...3,
        "upper": 1...1,
        "lower": 1...1,
        "url_encode": 1...1,
        "url_decode": 1...1,
        "string": 1...1,
        "json": 1...1,
        "md5": 1...1,
        "sha256": 1...1,
        "deep_merge": 2...Int.max,
        "delete": 0...0,
        "now": 0...1,
        "format_time": 2...4,
        "parse_time": 2...4,
        "uuid": 0...0,
    ]

    private static let knownMethods = Set([
        "filter", "map", "reduce",
        "sum", "avg", "count", "length",
        "min", "max",
    ])

    private static func validateExpression(
        _ expression: Expression,
        variables: Set<String>
    ) throws {
        switch expression {
        case .literal:
            return
        case .template(let raw):
            for embedded in try templateExpressions(in: raw) {
                try validateExpression(
                    embedded,
                    variables: variables
                )
            }
        case .identifier(let name):
            guard variables.contains(name) ||
                    ["provider", "model", "session", "headers", "body"]
                    .contains(name) else {
                throw ExpressionError.unknownIdentifier(name)
            }
        case .array(let values):
            for value in values {
                try validateExpression(value, variables: variables)
            }
        case .object(let fields):
            for (_, value) in fields {
                try validateExpression(value, variables: variables)
            }
        case .unary(_, let value):
            try validateExpression(value, variables: variables)
        case .binary(_, let lhs, let rhs):
            try validateExpression(lhs, variables: variables)
            try validateExpression(rhs, variables: variables)
        case .conditional(let condition, let lhs, let rhs):
            try validateExpression(condition, variables: variables)
            try validateExpression(lhs, variables: variables)
            try validateExpression(rhs, variables: variables)
        case .call(let rawName, let arguments):
            let name = rawName.lowercased()
            guard let allowed = knownFunctions[name] else {
                throw ExpressionError.unknownFunction(rawName)
            }
            guard allowed.contains(arguments.count) else {
                throw ExpressionError.invalidArguments(rawName)
            }
            for argument in arguments {
                try validateExpression(
                    argument,
                    variables: variables
                )
            }
        case .member(let base, _),
             .index(let base, _):
            try validateExpression(base, variables: variables)
            if case .index(_, let index) = expression {
                try validateExpression(
                    index,
                    variables: variables
                )
            }
        case .method(let base, let rawName, let arguments):
            let name = rawName.lowercased()
            guard knownMethods.contains(name) else {
                throw ExpressionError.unknownFunction(rawName)
            }
            try validateExpression(base, variables: variables)
            switch name {
            case "filter", "map":
                guard arguments.count == 2,
                      case .identifier(let variable) = arguments[0]
                else {
                    throw ExpressionError.invalidArguments(rawName)
                }
                try validateExpression(
                    arguments[1],
                    variables: variables.union([variable])
                )
            case "reduce":
                guard arguments.count == 4,
                      case .identifier(let accumulator) = arguments[0],
                      case .identifier(let item) = arguments[1]
                else {
                    throw ExpressionError.invalidArguments(rawName)
                }
                try validateExpression(
                    arguments[2],
                    variables: variables
                )
                try validateExpression(
                    arguments[3],
                    variables: variables.union([
                        accumulator, item,
                    ])
                )
            default:
                guard arguments.isEmpty else {
                    throw ExpressionError.invalidArguments(rawName)
                }
            }
        }
    }

    private static func evaluate(
        _ expression: Expression,
        environment: inout Environment
    ) throws -> Value {
        try environment.tick()
        switch expression {
        case .literal(let value):
            return value
        case .template(let raw):
            return try evaluateTemplateString(
                raw,
                environment: &environment
            )
        case .identifier(let name):
            if let local = environment.locals[name] {
                return local
            }
            return rootValue(
                name,
                context: environment.context
            )
        case .array(let expressions):
            return .array(try expressions.map {
                try evaluate($0, environment: &environment)
            })
        case .object(let fields):
            var result: [String: Value] = [:]
            for (key, fieldExpression) in fields {
                result[key] = try evaluate(
                    fieldExpression,
                    environment: &environment
                )
            }
            return .object(result, caseInsensitive: false)
        case .unary(let operation, let valueExpression):
            let value = try evaluate(
                valueExpression,
                environment: &environment
            )
            if value == .missing {
                return .missing
            }
            switch operation {
            case "!":
                guard case .bool(let bool) = value else {
                    throw ExpressionError.typeMismatch(
                        "! requires a boolean"
                    )
                }
                return .bool(!bool)
            case "-":
                if case .int(let int) = value {
                    return .int(-int)
                }
                guard let number = number(value) else {
                    throw ExpressionError.typeMismatch(
                        "- requires a number"
                    )
                }
                return .double(-number)
            case "+":
                guard number(value) != nil else {
                    throw ExpressionError.typeMismatch(
                        "+ requires a number"
                    )
                }
                return value
            default:
                throw ExpressionError.invalidExpression(operation)
            }
        case .binary(let operation, let lhsExpression, let rhsExpression):
            return try evaluateBinary(
                operation,
                lhs: lhsExpression,
                rhs: rhsExpression,
                environment: &environment
            )
        case .conditional(let conditionExpression, let trueExpression, let falseExpression):
            let condition = try evaluate(
                conditionExpression,
                environment: &environment
            )
            guard case .bool(let selected) = condition else {
                return condition == .missing
                    ? .missing
                    : try typeMismatch("condition requires a boolean")
            }
            return try evaluate(
                selected ? trueExpression : falseExpression,
                environment: &environment
            )
        case .call(let name, let arguments):
            return try evaluateCall(
                name,
                arguments: arguments,
                environment: &environment
            )
        case .member(let baseExpression, let name):
            let base = try evaluate(
                baseExpression,
                environment: &environment
            )
            return member(name, of: base)
        case .index(let baseExpression, let indexExpression):
            let base = try evaluate(
                baseExpression,
                environment: &environment
            )
            let index = try evaluate(
                indexExpression,
                environment: &environment
            )
            return try indexed(base, by: index)
        case .method(let baseExpression, let name, let arguments):
            let base = try evaluate(
                baseExpression,
                environment: &environment
            )
            return try evaluateMethod(
                name,
                base: base,
                arguments: arguments,
                environment: &environment
            )
        }
    }

    private static func evaluateBinary(
        _ operation: String,
        lhs lhsExpression: Expression,
        rhs rhsExpression: Expression,
        environment: inout Environment
    ) throws -> Value {
        let lhs = try evaluate(
            lhsExpression,
            environment: &environment
        )
        if operation == "??" {
            return lhs.isMissingOrNull
                ? try evaluate(rhsExpression, environment: &environment)
                : lhs
        }
        if operation == "&&" {
            if case .bool(false) = lhs {
                return .bool(false)
            }
            guard case .bool(true) = lhs else {
                return lhs == .missing
                    ? .missing
                    : try typeMismatch("&& requires booleans")
            }
            let rhs = try evaluate(
                rhsExpression,
                environment: &environment
            )
            guard case .bool(let bool) = rhs else {
                return rhs == .missing
                    ? .missing
                    : try typeMismatch("&& requires booleans")
            }
            return .bool(bool)
        }
        if operation == "||" {
            if case .bool(true) = lhs {
                return .bool(true)
            }
            guard case .bool(false) = lhs else {
                return lhs == .missing
                    ? .missing
                    : try typeMismatch("|| requires booleans")
            }
            let rhs = try evaluate(
                rhsExpression,
                environment: &environment
            )
            guard case .bool(let bool) = rhs else {
                return rhs == .missing
                    ? .missing
                    : try typeMismatch("|| requires booleans")
            }
            return .bool(bool)
        }

        let rhs = try evaluate(
            rhsExpression,
            environment: &environment
        )
        if operation == "==" || operation == "!=" {
            let equal = valuesEqual(lhs, rhs)
            return .bool(operation == "==" ? equal : !equal)
        }
        if lhs == .missing || rhs == .missing {
            return .missing
        }
        switch operation {
        case "+":
            if case .string(let left) = lhs,
               case .string(let right) = rhs {
                return .string(left + right)
            }
            if case .array(let left) = lhs,
               case .array(let right) = rhs {
                return .array(left + right)
            }
            return try numericBinary(lhs, rhs, operation: +)
        case "-":
            return try numericBinary(lhs, rhs, operation: -)
        case "*":
            return try numericBinary(lhs, rhs, operation: *)
        case "/":
            guard let left = number(lhs),
                  let right = number(rhs) else {
                throw ExpressionError.typeMismatch(
                    "/ requires numbers"
                )
            }
            guard right != 0 else {
                throw ExpressionError.invalidExpression(
                    "division by zero"
                )
            }
            return numericResult(
                left / right,
                preserveInteger: false
            )
        case "%":
            guard let left = integer(lhs),
                  let right = integer(rhs),
                  right != 0 else {
                throw ExpressionError.typeMismatch(
                    "% requires non-zero integers"
                )
            }
            return .int(left % right)
        case ">", ">=", "<", "<=":
            let ordering: ComparisonResult
            if let left = number(lhs),
               let right = number(rhs) {
                ordering = left == right
                    ? .orderedSame
                    : (left < right
                        ? .orderedAscending
                        : .orderedDescending)
            } else if case .string(let left) = lhs,
                      case .string(let right) = rhs {
                ordering = left.compare(right)
            } else {
                throw ExpressionError.typeMismatch(
                    "\(operation) requires numbers or strings"
                )
            }
            switch operation {
            case ">": return .bool(ordering == .orderedDescending)
            case ">=": return .bool(ordering != .orderedAscending)
            case "<": return .bool(ordering == .orderedAscending)
            default: return .bool(ordering != .orderedDescending)
            }
        default:
            throw ExpressionError.invalidExpression(operation)
        }
    }

    private static func evaluateCall(
        _ rawName: String,
        arguments: [Expression],
        environment: inout Environment
    ) throws -> Value {
        let name = rawName.lowercased()
        guard let range = knownFunctions[name] else {
            throw ExpressionError.unknownFunction(rawName)
        }
        guard range.contains(arguments.count) else {
            throw ExpressionError.invalidArguments(rawName)
        }
        if name == "if" {
            let condition = try evaluate(
                arguments[0],
                environment: &environment
            )
            guard case .bool(let selected) = condition else {
                return condition == .missing
                    ? .missing
                    : try typeMismatch("if condition requires a boolean")
            }
            return try evaluate(
                arguments[selected ? 1 : 2],
                environment: &environment
            )
        }
        if name == "exists" {
            return .bool(
                try evaluate(
                    arguments[0],
                    environment: &environment
                ) != .missing
            )
        }
        if name == "uuid" {
            return .string(UUID().uuidString)
        }
        if name == "delete" {
            return .delete
        }
        let values = try arguments.map {
            try evaluate($0, environment: &environment)
        }
        if values.contains(.missing) {
            return .missing
        }
        if name == "now" {
            return .int(
                try timestampUnit(values.first)
                    .timestamp(from: Date())
            )
        }
        switch name {
        case "append":
            guard case .array(let source) = values[0] else {
                throw ExpressionError.typeMismatch(
                    "append requires an array"
                )
            }
            return .array(source + Array(values.dropFirst()))
        case "concat":
            var result: [Value] = []
            for value in values {
                guard case .array(let array) = value else {
                    throw ExpressionError.typeMismatch(
                        "concat requires arrays"
                    )
                }
                result += array
            }
            return .array(result)
        case "remove":
            guard case .array(let source) = values[0] else {
                throw ExpressionError.typeMismatch(
                    "remove requires an array"
                )
            }
            let removals = values.dropFirst().flatMap {
                if case .array(let nested) = $0 {
                    return nested
                }
                return [$0]
            }
            return .array(source.filter { element in
                !removals.contains {
                    partialMatch(element, candidate: $0)
                }
            })
        case "update":
            guard case .array(let source) = values[0],
                  case .object(let criteria, _) = values[1],
                  case .object(let patch, _) = values[2] else {
                throw ExpressionError.typeMismatch(
                    "update requires array, object, object"
                )
            }
            return .array(source.map { element in
                guard partialMatch(
                    element,
                    candidate: .object(
                        criteria,
                        caseInsensitive: false
                    )
                ) else {
                    return element
                }
                return deepMerge(
                    element,
                    .object(patch, caseInsensitive: false)
                )
            })
        case "insert":
            guard case .array(var source) = values[0],
                  let rawIndex = integer(values[1]) else {
                throw ExpressionError.typeMismatch(
                    "insert requires array and integer index"
                )
            }
            let index = rawIndex < 0
                ? max(0, source.count + rawIndex + 1)
                : min(rawIndex, source.count)
            source.insert(values[2], at: index)
            return .array(source)
        case "remove_at":
            guard case .array(var source) = values[0],
                  let rawIndex = integer(values[1]) else {
                throw ExpressionError.typeMismatch(
                    "remove_at requires array and integer index"
                )
            }
            let index = normalizedIndex(
                rawIndex,
                count: source.count
            )
            if let index {
                source.remove(at: index)
            }
            return .array(source)
        case "min", "max":
            let candidates = numericCandidates(values)
            guard !candidates.isEmpty else {
                throw ExpressionError.typeMismatch(
                    "\(name) requires numbers"
                )
            }
            let selected = name == "min"
                ? candidates.min()!
                : candidates.max()!
            return numericResult(
                selected,
                preserveInteger: allIntegers(values)
            )
        case "sum":
            let candidates = numericCandidates(values)
            guard !candidates.isEmpty else {
                throw ExpressionError.typeMismatch(
                    "sum requires numbers"
                )
            }
            return numericResult(
                candidates.reduce(0, +),
                preserveInteger: allIntegers(values)
            )
        case "avg":
            let candidates = numericCandidates(values)
            guard !candidates.isEmpty else {
                throw ExpressionError.typeMismatch(
                    "avg requires numbers"
                )
            }
            return numericResult(
                candidates.reduce(0, +) /
                    Double(candidates.count),
                preserveInteger: false
            )
        case "count", "length":
            return try collectionLength(values[0])
        case "clamp":
            guard let value = number(values[0]),
                  let lower = number(values[1]),
                  let upper = number(values[2]),
                  lower <= upper else {
                throw ExpressionError.typeMismatch(
                    "clamp requires value, lower, upper numbers"
                )
            }
            return numericResult(
                min(max(value, lower), upper),
                preserveInteger: values.allSatisfy {
                    integer($0) != nil
                }
            )
        case "upper":
            return .string(
                try stringValue(values[0]).uppercased()
            )
        case "lower":
            return .string(
                try stringValue(values[0]).lowercased()
            )
        case "url_encode":
            guard let encoded = try stringValue(values[0])
                .addingPercentEncoding(
                    withAllowedCharacters:
                        urlComponentAllowedCharacters
                ) else {
                throw ExpressionError.invalidArguments(rawName)
            }
            return .string(encoded)
        case "url_decode":
            guard let decoded = try stringValue(values[0])
                .removingPercentEncoding else {
                throw ExpressionError.invalidArguments(rawName)
            }
            return .string(decoded)
        case "string":
            return .string(try stringify(values[0]))
        case "json":
            return .string(try jsonString(values[0]))
        case "md5":
            let data = Data(
                try stringValue(values[0]).utf8
            )
            return .string(
                Insecure.MD5.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
            )
        case "sha256":
            let data = Data(
                try stringValue(values[0]).utf8
            )
            return .string(
                SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
            )
        case "format_time":
            return .string(try formatTime(values))
        case "parse_time":
            return .int(try parseTime(values))
        case "deep_merge":
            return values.dropFirst().reduce(values[0], deepMerge)
        default:
            throw ExpressionError.unknownFunction(rawName)
        }
    }

    private enum TimestampUnit {
        case seconds
        case milliseconds

        func timestamp(from date: Date) throws -> Int {
            let multiplier = self == .seconds
                ? 1.0 : 1_000.0
            let raw = floor(
                date.timeIntervalSince1970 * multiplier
            )
            guard raw >= Double(Int.min),
                  raw <= Double(Int.max) else {
                throw ExpressionError.invalidArguments(
                    "timestamp out of range"
                )
            }
            return Int(raw)
        }

        func date(from timestamp: Int) -> Date {
            Date(
                timeIntervalSince1970:
                    self == .seconds
                        ? Double(timestamp)
                        : Double(timestamp) / 1_000.0
            )
        }
    }

    private static func timestampUnit(
        _ value: Value?
    ) throws -> TimestampUnit {
        guard let value else { return .seconds }
        switch try stringValue(value).lowercased() {
        case "seconds":
            return .seconds
        case "milliseconds":
            return .milliseconds
        default:
            throw ExpressionError.invalidArguments(
                "invalid timestamp unit"
            )
        }
    }

    private static func timeZone(
        _ value: Value?
    ) throws -> TimeZone {
        guard let value else { return .current }
        let identifier = try stringValue(value)
        guard let timeZone = TimeZone(
            identifier: identifier
        ) else {
            throw ExpressionError.invalidArguments(
                "invalid time zone"
            )
        }
        return timeZone
    }

    private static func translatedTimeFormat(
        _ rawFormat: String
    ) throws -> String {
        guard !rawFormat.isEmpty else {
            throw ExpressionError.invalidArguments(
                "empty time format"
            )
        }
        let tokens: [(source: String, target: String)] = [
            ("YYYY", "yyyy"),
            ("SSS", "SSS"),
            ("YY", "yy"),
            ("MM", "MM"),
            ("DD", "dd"),
            ("HH", "HH"),
            ("hh", "hh"),
            ("mm", "mm"),
            ("ss", "ss"),
            ("SS", "SS"),
            ("M", "M"),
            ("D", "d"),
            ("H", "H"),
            ("h", "h"),
            ("m", "m"),
            ("s", "s"),
            ("S", "S"),
            ("a", "a"),
        ]
        var result = ""
        var index = rawFormat.startIndex
        while index < rawFormat.endIndex {
            if let token = tokens.first(where: {
                rawFormat[index...].hasPrefix($0.source)
            }) {
                result += token.target
                index = rawFormat.index(
                    index,
                    offsetBy: token.source.count
                )
            } else {
                let character = rawFormat[index]
                result += character == "'"
                    ? "''" : "'\(character)'"
                index = rawFormat.index(after: index)
            }
        }
        return result
    }

    private static func timeFormatter(
        format: String,
        timeZone: TimeZone
    ) throws -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(
            identifier: "en_US_POSIX"
        )
        var calendar = Calendar(
            identifier: .gregorian
        )
        calendar.timeZone = timeZone
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.twoDigitStartDate = calendar.date(
            from: DateComponents(
                year: 2000,
                month: 1,
                day: 1
            )
        )
        formatter.isLenient = false
        formatter.dateFormat = try translatedTimeFormat(
            format
        )
        return formatter
    }

    private static func formatTime(
        _ values: [Value]
    ) throws -> String {
        guard let timestamp = integer(values[0]) else {
            throw ExpressionError.typeMismatch(
                "format_time requires an integer timestamp"
            )
        }
        let formatter = try timeFormatter(
            format: try stringValue(values[1]),
            timeZone: try timeZone(
                values.count > 3 ? values[3] : nil
            )
        )
        return formatter.string(
            from: try timestampUnit(
                values.count > 2 ? values[2] : nil
            ).date(from: timestamp)
        )
    }

    private static func parseTime(
        _ values: [Value]
    ) throws -> Int {
        let text = try stringValue(values[0])
        let format = try stringValue(values[1])
        guard format.contains("YYYY")
                || format.contains("YY"),
              format.contains("M"),
              format.contains("D"),
              !format.contains("h")
                || format.contains("a") else {
            throw ExpressionError.invalidArguments(
                "parse_time requires a complete date"
            )
        }
        let formatter = try timeFormatter(
            format: format,
            timeZone: try timeZone(
                values.count > 3 ? values[3] : nil
            )
        )
        guard let date = formatter.date(from: text),
              formatter.string(from: date) == text else {
            throw ExpressionError.invalidArguments(
                "invalid formatted time"
            )
        }
        return try timestampUnit(
            values.count > 2 ? values[2] : nil
        ).timestamp(from: date)
    }

    private static let urlComponentAllowedCharacters =
        CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )

    private static func evaluateMethod(
        _ rawName: String,
        base: Value,
        arguments: [Expression],
        environment: inout Environment
    ) throws -> Value {
        if base == .missing {
            return .missing
        }
        let name = rawName.lowercased()
        switch name {
        case "filter", "map":
            guard case .array(let source) = base,
                  arguments.count == 2,
                  case .identifier(let variable) = arguments[0]
            else {
                throw ExpressionError.invalidArguments(rawName)
            }
            var result: [Value] = []
            for value in source {
                let previous = environment.locals[variable]
                environment.locals[variable] = value
                defer {
                    environment.locals[variable] = previous
                }
                let evaluated = try evaluate(
                    arguments[1],
                    environment: &environment
                )
                if name == "filter" {
                    if case .bool(true) = evaluated {
                        result.append(value)
                    } else if evaluated != .missing,
                              evaluated != .bool(false) {
                        throw ExpressionError.typeMismatch(
                            "filter predicate requires a boolean"
                        )
                    }
                } else {
                    if evaluated == .missing {
                        return .missing
                    }
                    result.append(evaluated)
                }
            }
            return .array(result)
        case "reduce":
            guard case .array(let source) = base,
                  arguments.count == 4,
                  case .identifier(let accumulatorName) = arguments[0],
                  case .identifier(let itemName) = arguments[1]
            else {
                throw ExpressionError.invalidArguments(rawName)
            }
            var accumulator = try evaluate(
                arguments[2],
                environment: &environment
            )
            for item in source {
                let previousAccumulator =
                    environment.locals[accumulatorName]
                let previousItem =
                    environment.locals[itemName]
                environment.locals[accumulatorName] =
                    accumulator
                environment.locals[itemName] = item
                accumulator = try evaluate(
                    arguments[3],
                    environment: &environment
                )
                environment.locals[accumulatorName] =
                    previousAccumulator
                environment.locals[itemName] = previousItem
                if accumulator == .missing {
                    return .missing
                }
            }
            return accumulator
        case "sum", "avg", "count", "length", "min", "max":
            guard arguments.isEmpty else {
                throw ExpressionError.invalidArguments(rawName)
            }
            return try evaluateCall(
                name,
                arguments: [.literal(base)],
                environment: &environment
            )
        default:
            throw ExpressionError.unknownFunction(rawName)
        }
    }

    private static func evaluateTemplateString(
        _ raw: String,
        environment: inout Environment
    ) throws -> Value {
        // A quoted / mixed-content template always produces a string: the
        // surrounding quotes are the author's explicit request to stringify.
        // (A bare whole template `{{ x }}` never reaches here — it is compiled
        // straight into its inner expression and keeps its native type.)
        let matches = try templateRanges(in: raw)
        var output = raw
        for match in matches.reversed() {
            let value = try evaluate(
                match.expression,
                environment: &environment
            )
            if value == .missing {
                return .missing
            }
            output.replaceSubrange(
                match.full,
                with: try stringify(value)
            )
        }
        return .string(output)
    }

    private static func templateExpressions(
        in raw: String
    ) throws -> [Expression] {
        try templateRanges(in: raw).map(\.expression)
    }

    private static func templateRanges(
        in raw: String
    ) throws -> [(
        full: Range<String.Index>,
        expression: Expression
    )] {
        var result: [(
            full: Range<String.Index>,
            expression: Expression
        )] = []
        var search = raw.startIndex
        while let open = raw.range(
            of: "{{",
            range: search..<raw.endIndex
        ) {
            guard let close = raw.range(
                of: "}}",
                range: open.upperBound..<raw.endIndex
            ) else {
                throw ExpressionError.invalidExpression(
                    "unterminated template"
                )
            }
            let source = String(
                raw[open.upperBound..<close.lowerBound]
            ).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            try validateSourceLimits(source)
            var parser = try Parser(source)
            result.append((
                open.lowerBound..<close.upperBound,
                try parser.parse()
            ))
            search = close.upperBound
        }
        if raw[search...].contains("}}") {
            throw ExpressionError.invalidExpression(
                "unmatched template delimiter"
            )
        }
        return result
    }

    private static func validateSourceLimits(
        _ source: String
    ) throws {
        guard source.utf8.count <= 65_536 else {
            throw ExpressionError.evaluationLimit
        }
        var quote: Character?
        var escaped = false
        var depth = 0
        for character in source {
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
            case "(", "[", "{":
                depth += 1
                if depth > 128 {
                    throw ExpressionError.evaluationLimit
                }
            case ")", "]", "}":
                depth = max(0, depth - 1)
            default:
                break
            }
        }
    }

    private static func rootValue(
        _ name: String,
        context: RequestCustomizationExpression.Context
    ) -> Value {
        switch name {
        case "provider":
            var provider: [String: Value] = [
                "id": .string(context.provider.id),
                "label": .string(context.provider.label),
                "type": .string(
                    context.provider.providerType.rawValue
                ),
                "credentialType": .string(
                    context.provider.credentialType.rawValue
                ),
            ]
            provider["apiKey"] = context.apiKey.map(Value.string)
                ?? .missing
            provider["baseURL"] =
                context.provider.effectiveCustomBaseURL
                    .map(Value.string) ?? .missing
            return .object(
                provider,
                caseInsensitive: false
            )
        case "model":
            return .object([
                "id": .string(context.model.id),
                "displayName": .string(
                    context.model.displayName
                ),
                "provider": .string(context.model.provider),
            ], caseInsensitive: false)
        case "session":
            return .object([
                "id": context.sessionId.map(Value.string)
                    ?? .missing,
            ], caseInsensitive: false)
        case "headers":
            return .object(
                context.headers.mapValues(Value.string),
                caseInsensitive: true
            )
        case "body":
            return fromAny(context.body)
        default:
            return .missing
        }
    }

    private static func member(
        _ name: String,
        of value: Value
    ) -> Value {
        guard case .object(
            let object,
            let caseInsensitive
        ) = value else {
            return .missing
        }
        if let exact = object[name] {
            return exact
        }
        if caseInsensitive,
           let match = object.first(where: {
               $0.key.caseInsensitiveCompare(name) == .orderedSame
           }) {
            return match.value
        }
        return .missing
    }

    private static func indexed(
        _ value: Value,
        by index: Value
    ) throws -> Value {
        switch value {
        case .array(let array):
            guard let rawIndex = integer(index) else {
                throw ExpressionError.typeMismatch(
                    "array index must be an integer"
                )
            }
            guard let normalized = normalizedIndex(
                rawIndex,
                count: array.count
            ) else {
                return .missing
            }
            return array[normalized]
        case .object:
            guard case .string(let key) = index else {
                throw ExpressionError.typeMismatch(
                    "object index must be a string"
                )
            }
            return member(key, of: value)
        default:
            return .missing
        }
    }

    private static func normalizedIndex(
        _ index: Int,
        count: Int
    ) -> Int? {
        let normalized = index < 0
            ? count + index
            : index
        return (0..<count).contains(normalized)
            ? normalized
            : nil
    }

    private static func numericBinary(
        _ lhs: Value,
        _ rhs: Value,
        operation: (Double, Double) -> Double
    ) throws -> Value {
        guard let left = number(lhs),
              let right = number(rhs) else {
            throw ExpressionError.typeMismatch(
                "arithmetic requires numbers"
            )
        }
        let result = operation(left, right)
        return numericResult(
            result,
            preserveInteger:
                integer(lhs) != nil &&
                integer(rhs) != nil &&
                result.rounded() == result
        )
    }

    private static func number(_ value: Value) -> Double? {
        switch value {
        case .int(let number):
            return Double(number)
        case .double(let number):
            return number
        default:
            return nil
        }
    }

    private static func integer(_ value: Value) -> Int? {
        switch value {
        case .int(let number):
            return number
        case .double(let number)
            where number.isFinite &&
                number.rounded() == number &&
                number >= Double(Int.min) &&
                number <= Double(Int.max):
            return Int(number)
        default:
            return nil
        }
    }

    private static func numericResult(
        _ value: Double,
        preserveInteger: Bool
    ) -> Value {
        guard value.isFinite else {
            return .missing
        }
        if preserveInteger,
           value >= Double(Int.min),
           value <= Double(Int.max) {
            return .int(Int(value))
        }
        return .double(value)
    }

    private static func numericCandidates(
        _ values: [Value]
    ) -> [Double] {
        let expanded = values.flatMap { value -> [Value] in
            if case .array(let array) = value {
                return array
            }
            return [value]
        }
        guard expanded.allSatisfy({
            number($0) != nil
        }) else {
            return []
        }
        return expanded.compactMap(number)
    }

    private static func allIntegers(
        _ values: [Value]
    ) -> Bool {
        let expanded = values.flatMap { value -> [Value] in
            if case .array(let array) = value {
                return array
            }
            return [value]
        }
        return !expanded.isEmpty &&
            expanded.allSatisfy { integer($0) != nil }
    }

    private static func collectionLength(
        _ value: Value
    ) throws -> Value {
        switch value {
        case .string(let string):
            return .int(string.unicodeScalars.count)
        case .array(let array):
            return .int(array.count)
        case .object(let object, _):
            return .int(object.count)
        default:
            throw ExpressionError.typeMismatch(
                "length requires string, array, or object"
            )
        }
    }

    private static func stringValue(
        _ value: Value
    ) throws -> String {
        guard case .string(let string) = value else {
            throw ExpressionError.typeMismatch(
                "string value required"
            )
        }
        return string
    }

    private static func valuesEqual(
        _ lhs: Value,
        _ rhs: Value
    ) -> Bool {
        if lhs == .missing || rhs == .missing {
            return false
        }
        if let left = number(lhs),
           let right = number(rhs) {
            return left == right
        }
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let left), .bool(let right)):
            return left == right
        case (.string(let left), .string(let right)):
            return left == right
        case (.array(let left), .array(let right)):
            return left.count == right.count &&
                zip(left, right).allSatisfy {
                    valuesEqual($0.0, $0.1)
                }
        case (
            .object(let left, _),
            .object(let right, _)
        ):
            return left.count == right.count &&
                left.allSatisfy { key, value in
                    right[key].map {
                        valuesEqual(value, $0)
                    } ?? false
                }
        default:
            return false
        }
    }

    private static func partialMatch(
        _ value: Value,
        candidate: Value
    ) -> Bool {
        guard case .object(let expected, _) = candidate,
              case .object(let actual, _) = value else {
            return valuesEqual(value, candidate)
        }
        return expected.allSatisfy { key, expectedValue in
            actual[key].map {
                partialMatch($0, candidate: expectedValue)
            } ?? false
        }
    }

    private static func deepMerge(
        _ lhs: Value,
        _ rhs: Value
    ) -> Value {
        guard case .object(let left, let insensitive) = lhs,
              case .object(let right, _) = rhs else {
            return rhs
        }
        var result = left
        for (key, value) in right {
            if value == .delete {
                result.removeValue(forKey: key)
            } else if let existing = result[key] {
                result[key] = deepMerge(existing, value)
            } else {
                result[key] = value
            }
        }
        return .object(
            result,
            caseInsensitive: insensitive
        )
    }

    private static func fromAny(_ value: Any?) -> Value {
        guard let value else {
            return .null
        }
        if value is NSNull {
            return .null
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let double = number.doubleValue
            return double.rounded() == double
                ? .int(number.intValue)
                : .double(double)
        }
        if let bool = value as? Bool {
            return .bool(bool)
        }
        if let int = value as? Int {
            return .int(int)
        }
        if let double = value as? Double {
            return .double(double)
        }
        if let string = value as? String {
            return .string(string)
        }
        if let array = value as? [Any] {
            return .array(array.map(fromAny))
        }
        if let dictionary = value as? [String: Any] {
            return .object(
                dictionary.mapValues(fromAny),
                caseInsensitive: false
            )
        }
        if let dictionary = value as? [String: String] {
            return .object(
                dictionary.mapValues(Value.string),
                caseInsensitive: false
            )
        }
        return .string(String(describing: value))
    }

    private static func toAny(_ value: Value) throws -> Any {
        switch value {
        case .missing:
            throw ExpressionError.invalidExpression(
                "missing value"
            )
        case .null:
            return NSNull()
        case .delete:
            return deleteMarker
        case .bool(let bool):
            return bool
        case .int(let int):
            return int
        case .double(let double):
            return double
        case .string(let string):
            return string
        case .array(let array):
            guard !array.contains(.delete) else {
                throw ExpressionError.typeMismatch(
                    "delete() cannot be an array element"
                )
            }
            return try array.map(toAny)
        case .object(let object, _):
            return try object.mapValues(toAny)
        }
    }

    private static func stringify(
        _ value: Value
    ) throws -> String {
        switch value {
        case .string(let string):
            return string
        case .bool(let bool):
            return bool ? "true" : "false"
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .null:
            return ""
        case .delete:
            throw ExpressionError.typeMismatch(
                "delete() is only valid in request mutations"
            )
        case .array, .object:
            return try jsonString(value)
        case .missing:
            throw ExpressionError.invalidExpression(
                "missing value"
            )
        }
    }

    private static func jsonString(
        _ value: Value
    ) throws -> String {
        let object = try toAny(value)
        guard JSONSerialization.isValidJSONObject(object) ||
                value.isJSONFragment else {
            throw ExpressionError.typeMismatch(
                "value cannot be serialized as JSON"
            )
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.fragmentsAllowed, .sortedKeys]
        )
        guard let string = String(
            data: data,
            encoding: .utf8
        ) else {
            throw ExpressionError.invalidExpression(
                "JSON encoding failed"
            )
        }
        return string
    }

    private static func put(
        _ value: Any,
        at path: [String],
        in object: inout [String: Any]
    ) {
        guard let key = path.first else {
            return
        }
        if path.count == 1 {
            object[key] = value
            return
        }
        var child = object[key] as? [String: Any] ?? [:]
        put(
            value,
            at: Array(path.dropFirst()),
            in: &child
        )
        object[key] = child
    }

    private static func replacing(
        _ context: RequestCustomizationExpression.Context,
        headers: [String: String]? = nil,
        body: [String: Any]? = nil
    ) -> RequestCustomizationExpression.Context {
        RequestCustomizationExpression.Context(
            provider: context.provider,
            model: context.model,
            apiKey: context.apiKey,
            sessionId: context.sessionId,
            headers: headers ?? context.headers,
            body: body ?? context.body
        )
    }

    private static func setHeader(
        _ value: String,
        for name: String,
        in headers: inout [String: String]
    ) {
        let existing = headers.keys.first {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }
        headers[existing ?? name] = value
    }

    private static func removeHeader(
        _ name: String,
        from headers: inout [String: String]
    ) {
        guard let existing = headers.keys.first(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            return
        }
        headers.removeValue(forKey: existing)
    }

    private static func assignmentIndex(
        in raw: String
    ) -> String.Index? {
        var quote: Character?
        var depth = 0
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if let activeQuote = quote {
                if character == "\\" {
                    index = raw.index(after: index)
                    if index < raw.endIndex {
                        index = raw.index(after: index)
                    }
                    continue
                }
                if character == activeQuote {
                    quote = nil
                }
                index = raw.index(after: index)
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
            case "(", "[", "{":
                depth += 1
            case ")", "]", "}":
                depth = max(0, depth - 1)
            case "=" where depth == 0:
                let next = raw.index(after: index)
                if next < raw.endIndex,
                   raw[next] == "=" {
                    break
                }
                let previous = index > raw.startIndex
                    ? raw[raw.index(before: index)]
                    : nil
                if previous != "!" &&
                    previous != ">" &&
                    previous != "<" {
                    return index
                }
            default:
                break
            }
            index = raw.index(after: index)
        }
        return nil
    }

    private static func parseTargetPath(
        _ raw: String
    ) throws -> [String] {
        let text = raw.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        var result: [String] = []
        var token = ""
        var index = text.startIndex

        func flush() {
            let value = token.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !value.isEmpty {
                result.append(value)
            }
            token = ""
        }

        while index < text.endIndex {
            let character = text[index]
            if character == "." {
                flush()
                index = text.index(after: index)
                continue
            }
            if character == "[" {
                flush()
                index = text.index(after: index)
                while index < text.endIndex,
                      text[index].isWhitespace {
                    index = text.index(after: index)
                }
                guard index < text.endIndex,
                      text[index] == "\"" ||
                        text[index] == "'" else {
                    throw ExpressionError.invalidTarget
                }
                let quote = text[index]
                index = text.index(after: index)
                var value = ""
                while index < text.endIndex,
                      text[index] != quote {
                    value.append(text[index])
                    index = text.index(after: index)
                }
                guard index < text.endIndex else {
                    throw ExpressionError.invalidTarget
                }
                index = text.index(after: index)
                while index < text.endIndex,
                      text[index].isWhitespace {
                    index = text.index(after: index)
                }
                guard index < text.endIndex,
                      text[index] == "]" else {
                    throw ExpressionError.invalidTarget
                }
                result.append(value)
                index = text.index(after: index)
                continue
            }
            guard character.isLetter ||
                    character.isNumber ||
                    character == "_" ||
                    character == "-" else {
                throw ExpressionError.invalidTarget
            }
            token.append(character)
            index = text.index(after: index)
        }
        flush()
        guard !result.isEmpty,
              result.allSatisfy({ !$0.isEmpty }) else {
            throw ExpressionError.invalidTarget
        }
        return result
    }

    private static func isWholeTemplate(
        _ raw: String
    ) -> Bool {
        guard raw.hasPrefix("{{"),
              raw.hasSuffix("}}") else {
            return false
        }
        let inner = raw.dropFirst(2).dropLast(2)
        return !inner.contains("{{") &&
            !inner.contains("}}")
    }

    private static func unquoteIfNeeded(
        _ raw: String
    ) -> String {
        guard raw.count >= 2,
              let first = raw.first,
              let last = raw.last,
              first == last,
              first == "\"" || first == "'" else {
            return raw
        }
        return String(raw.dropFirst().dropLast())
    }

    private static func typeMismatch(
        _ message: String
    ) throws -> Value {
        throw ExpressionError.typeMismatch(message)
    }
}

private extension MinixRequestExpression.Value {
    var isJSONFragment: Bool {
        switch self {
        case .bool, .int, .double, .string, .null:
            return true
        case .missing, .delete, .array, .object:
            return false
        }
    }
}

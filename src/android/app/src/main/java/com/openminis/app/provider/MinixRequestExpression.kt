package com.openminis.app.provider

import com.openminis.app.logging.AppLogger
import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeFormatterBuilder
import java.time.format.ResolverStyle
import java.util.Locale
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

internal data object MinixDeleteMarker

/**
 * [Minix] Safe request-expression parser and evaluator.
 *
 * Kept in a Minix-owned file so upstream provider changes do not overlap with
 * the expression language implementation.
 */
internal object MinixRequestExpression {
    enum class Target { HEADER, BODY, CONTROL }

    data class Issue(
        val line: Int,
        val kind: RequestExpressionValidator.ErrorKind,
    )

    private class ExpressionException(
        val kind: RequestExpressionValidator.ErrorKind,
        message: String,
    ) : IllegalArgumentException(message)

    private sealed interface Value {
        data object Missing : Value
        data object Null : Value
        data object Delete : Value
        data class Bool(val value: Boolean) : Value
        data class Integer(val value: Long) : Value
        data class Decimal(val value: Double) : Value
        data class Text(val value: String) : Value
        data class ArrayValue(val values: List<Value>) : Value
        data class ObjectValue(
            val values: LinkedHashMap<String, Value>,
            val caseInsensitive: Boolean = false,
        ) : Value
    }

    private sealed interface Expression {
        data class Literal(val value: Value) : Expression
        data class Template(val source: String) : Expression
        data class Identifier(val name: String) : Expression
        data class ArrayExpression(val values: List<Expression>) : Expression
        data class ObjectExpression(
            val values: List<Pair<String, Expression>>,
        ) : Expression
        data class Unary(
            val operation: String,
            val value: Expression,
        ) : Expression
        data class Binary(
            val operation: String,
            val lhs: Expression,
            val rhs: Expression,
        ) : Expression
        data class Conditional(
            val condition: Expression,
            val ifTrue: Expression,
            val ifFalse: Expression,
        ) : Expression
        data class Call(
            val name: String,
            val arguments: List<Expression>,
        ) : Expression
        data class Member(
            val base: Expression,
            val name: String,
        ) : Expression
        data class Index(
            val base: Expression,
            val index: Expression,
        ) : Expression
        data class Method(
            val base: Expression,
            val name: String,
            val arguments: List<Expression>,
        ) : Expression
    }

    private data class Assignment(
        val path: List<String>,
        val expression: Expression,
    )

    private data class Environment(
        val context: RequestCustomizationContext,
        val locals: MutableMap<String, Value> = mutableMapOf(),
        var steps: Int = 0,
    ) {
        fun tick() {
            steps++
            if (steps > 100_000) {
                invalid(
                    RequestExpressionValidator.ErrorKind.EVALUATION_LIMIT,
                    "expression evaluation limit exceeded",
                )
            }
        }
    }

    private sealed interface Token {
        data class Identifier(val value: String) : Token
        data class NumberToken(val value: String) : Token
        data class StringToken(val value: String) : Token
        data class Symbol(val value: String) : Token
        data object End : Token
    }

    private class Lexer(private val input: String) {
        private var index = 0

        fun tokenize(): List<Token> = buildList {
            while (true) {
                val token = nextToken()
                add(token)
                if (size > 1_024) {
                    invalid(
                        RequestExpressionValidator.ErrorKind.EVALUATION_LIMIT,
                        "expression token limit exceeded",
                    )
                }
                if (token == Token.End) return@buildList
            }
        }

        private fun nextToken(): Token {
            while (index < input.length && input[index].isWhitespace()) {
                index++
            }
            if (index >= input.length) return Token.End
            val character = input[index]
            if (character == '"' || character == '\'') {
                return readString(character)
            }
            if (character.isDigit() ||
                (character == '.' && input.getOrNull(index + 1)?.isDigit() == true)
            ) {
                return readNumber()
            }
            if (character.isLetter() || character == '_') {
                return readIdentifier()
            }
            listOf("&&", "||", "??", ">=", "<=", "==", "!=")
                .firstOrNull { input.startsWith(it, index) }
                ?.let {
                    index += it.length
                    return Token.Symbol(it)
                }
            if (character in "+-*/%><!?:.,()[]{}=") {
                index++
                return Token.Symbol(character.toString())
            }
            invalid(
                RequestExpressionValidator.ErrorKind.UNBALANCED_DELIMITER,
                "unexpected character $character",
            )
        }

        private fun readIdentifier(): Token {
            val start = index
            while (index < input.length &&
                (input[index].isLetterOrDigit() || input[index] == '_')
            ) {
                index++
            }
            return Token.Identifier(input.substring(start, index))
        }

        private fun readNumber(): Token {
            val start = index
            var hasDot = false
            while (index < input.length) {
                val character = input[index]
                if (character == '.') {
                    if (hasDot) break
                    hasDot = true
                } else if (!character.isDigit()) {
                    break
                }
                index++
            }
            return Token.NumberToken(input.substring(start, index))
        }

        private fun readString(quote: Char): Token {
            index++
            val result = StringBuilder()
            while (index < input.length) {
                val character = input[index]
                if (character == quote) {
                    index++
                    return Token.StringToken(result.toString())
                }
                if (character == '\\') {
                    index++
                    if (index >= input.length) break
                    result.append(
                        when (input[index]) {
                            'n' -> '\n'
                            'r' -> '\r'
                            't' -> '\t'
                            '\\' -> '\\'
                            '"' -> '"'
                            '\'' -> '\''
                            else -> input[index]
                        },
                    )
                } else {
                    result.append(character)
                }
                index++
            }
            invalid(
                RequestExpressionValidator.ErrorKind.UNBALANCED_DELIMITER,
                "unterminated string",
            )
        }
    }

    private class Parser(source: String) {
        private val tokens = Lexer(source).tokenize()
        private var index = 0
        private val current: Token
            get() = tokens[index.coerceAtMost(tokens.lastIndex)]

        fun parse(): Expression {
            val expression = parseConditional()
            if (current != Token.End) {
                syntax("unexpected token")
            }
            return expression
        }

        private fun advance(): Token {
            val token = current
            index = (index + 1).coerceAtMost(tokens.lastIndex)
            return token
        }

        private fun consume(symbol: String): Boolean {
            if (current != Token.Symbol(symbol)) return false
            advance()
            return true
        }

        private fun expect(symbol: String) {
            if (!consume(symbol)) syntax("expected $symbol")
        }

        private fun parseConditional(): Expression {
            val condition = parseCoalescing()
            if (!consume("?")) return condition
            val ifTrue = parseConditional()
            expect(":")
            return Expression.Conditional(
                condition,
                ifTrue,
                parseConditional(),
            )
        }

        private fun parseCoalescing(): Expression {
            val lhs = parseOr()
            return if (consume("??")) {
                Expression.Binary("??", lhs, parseCoalescing())
            } else {
                lhs
            }
        }

        private fun parseOr(): Expression {
            var expression = parseAnd()
            while (consume("||")) {
                expression = Expression.Binary("||", expression, parseAnd())
            }
            return expression
        }

        private fun parseAnd(): Expression {
            var expression = parseEquality()
            while (consume("&&")) {
                expression = Expression.Binary("&&", expression, parseEquality())
            }
            return expression
        }

        private fun parseEquality(): Expression {
            var expression = parseComparison()
            while (current is Token.Symbol &&
                (current as Token.Symbol).value in setOf("==", "!=")
            ) {
                val operation = (advance() as Token.Symbol).value
                expression = Expression.Binary(
                    operation,
                    expression,
                    parseComparison(),
                )
            }
            return expression
        }

        private fun parseComparison(): Expression {
            var expression = parseTerm()
            while (current is Token.Symbol &&
                (current as Token.Symbol).value in setOf(">", ">=", "<", "<=")
            ) {
                val operation = (advance() as Token.Symbol).value
                expression = Expression.Binary(
                    operation,
                    expression,
                    parseTerm(),
                )
            }
            return expression
        }

        private fun parseTerm(): Expression {
            var expression = parseFactor()
            while (current is Token.Symbol &&
                (current as Token.Symbol).value in setOf("+", "-")
            ) {
                val operation = (advance() as Token.Symbol).value
                expression = Expression.Binary(
                    operation,
                    expression,
                    parseFactor(),
                )
            }
            return expression
        }

        private fun parseFactor(): Expression {
            var expression = parseUnary()
            while (current is Token.Symbol &&
                (current as Token.Symbol).value in setOf("*", "/", "%")
            ) {
                val operation = (advance() as Token.Symbol).value
                expression = Expression.Binary(
                    operation,
                    expression,
                    parseUnary(),
                )
            }
            return expression
        }

        private fun parseUnary(): Expression {
            if (current is Token.Symbol &&
                (current as Token.Symbol).value in setOf("!", "-", "+")
            ) {
                return Expression.Unary(
                    (advance() as Token.Symbol).value,
                    parseUnary(),
                )
            }
            return parsePostfix()
        }

        private fun parsePostfix(): Expression {
            var expression = parsePrimary()
            while (true) {
                when {
                    consume(".") -> {
                        val name = (advance() as? Token.Identifier)?.value
                            ?: syntax("expected member name")
                        expression = if (consume("(")) {
                            Expression.Method(
                                expression,
                                name,
                                parseArguments(),
                            )
                        } else {
                            Expression.Member(expression, name)
                        }
                    }
                    consume("[") -> {
                        val subscript = parseConditional()
                        expect("]")
                        expression = Expression.Index(expression, subscript)
                    }
                    else -> return expression
                }
            }
        }

        private fun parsePrimary(): Expression {
            return when (val token = advance()) {
                is Token.NumberToken -> {
                    if (token.value.contains('.')) {
                        Expression.Literal(
                            Value.Decimal(
                                token.value.toDoubleOrNull()
                                    ?: syntax("invalid number"),
                            ),
                        )
                    } else {
                        Expression.Literal(
                            Value.Integer(
                                token.value.toLongOrNull()
                                    ?: syntax("invalid number"),
                            ),
                        )
                    }
                }
                is Token.StringToken -> {
                    if (token.value.contains("{{")) {
                        Expression.Template(token.value)
                    } else {
                        Expression.Literal(Value.Text(token.value))
                    }
                }
                is Token.Identifier -> {
                    when (token.value.lowercase()) {
                        "true" -> Expression.Literal(Value.Bool(true))
                        "false" -> Expression.Literal(Value.Bool(false))
                        "null" -> Expression.Literal(Value.Null)
                        else -> if (consume("(")) {
                            Expression.Call(token.value, parseArguments())
                        } else {
                            Expression.Identifier(token.value)
                        }
                    }
                }
                Token.Symbol("(") -> {
                    val expression = parseConditional()
                    expect(")")
                    expression
                }
                Token.Symbol("[") -> parseArray()
                Token.Symbol("{") -> parseObject()
                else -> syntax("expected value")
            }
        }

        private fun parseArguments(): List<Expression> {
            if (consume(")")) return emptyList()
            val arguments = mutableListOf<Expression>()
            do {
                arguments += parseConditional()
            } while (consume(","))
            expect(")")
            return arguments
        }

        private fun parseArray(): Expression {
            if (consume("]")) return Expression.ArrayExpression(emptyList())
            val values = mutableListOf<Expression>()
            do {
                values += parseConditional()
            } while (consume(","))
            expect("]")
            return Expression.ArrayExpression(values)
        }

        private fun parseObject(): Expression {
            if (consume("}")) return Expression.ObjectExpression(emptyList())
            val values = mutableListOf<Pair<String, Expression>>()
            do {
                val key = when (val token = advance()) {
                    is Token.Identifier -> token.value
                    is Token.StringToken -> token.value
                    else -> syntax("expected object key")
                }
                if (!consume(":")) {
                    syntax("expected :")
                }
                values += key to parseConditional()
            } while (consume(","))
            expect("}")
            return Expression.ObjectExpression(values)
        }

        private fun syntax(message: String): Nothing = invalid(
            RequestExpressionValidator.ErrorKind.UNBALANCED_DELIMITER,
            message,
        )
    }

    fun validate(lines: List<String>, target: Target): List<Issue> =
        lines.mapIndexedNotNull { index, line ->
            if (line.isBlank()) return@mapIndexedNotNull null
            try {
                val assignment = compileAssignment(line)
                validateTarget(assignment.path, target)
                validateExpression(assignment.expression, emptySet())
                null
            } catch (error: ExpressionException) {
                Issue(index + 1, error.kind)
            } catch (_: Throwable) {
                Issue(
                    index + 1,
                    RequestExpressionValidator.ErrorKind.UNBALANCED_DELIMITER,
                )
            }
        }

    fun parseHeaders(
        lines: List<String>,
        context: RequestCustomizationContext,
    ): Map<String, String> {
        val result = linkedMapOf<String, String>()
        evaluateHeaders(lines, context) { name, value ->
            if (value != null) setHeader(result, name, value)
        }
        return result
    }

    fun applyHeaders(
        lines: List<String>,
        headers: MutableMap<String, String>,
        context: RequestCustomizationContext,
    ) {
        evaluateHeaders(lines, context) { name, value ->
            if (value == null) {
                removeHeader(headers, name)
            } else {
                setHeader(headers, name, value)
            }
        }
    }

    private fun evaluateHeaders(
        lines: List<String>,
        context: RequestCustomizationContext,
        apply: (String, String?) -> Unit,
    ) {
        val working = context.headers.toMutableMap()
        for ((index, line) in lines.withIndex()) {
            if (line.isBlank()) continue
            try {
                val assignment = compileAssignment(line)
                validateTarget(assignment.path, Target.HEADER)
                val value = evaluate(
                    assignment.expression,
                    Environment(context.copy(headers = working)),
                )
                if (value == Value.Missing) continue
                val name = assignment.path.first()
                if (value == Value.Delete) {
                    apply(name, null)
                    removeHeader(working, name)
                } else {
                    if (value == Value.Null) {
                        typeMismatch("headers require text or delete()")
                    }
                    val text = stringify(value)
                    apply(name, text)
                    setHeader(working, name, text)
                }
            } catch (error: Exception) {
                logRuntimeIssue(Target.HEADER, index, error)
            }
        }
    }

    fun parseBody(
        lines: List<String>,
        context: RequestCustomizationContext,
    ): JSONObject {
        val result = JSONObject()
        val working = JSONObject(context.body.toString())
        for ((index, line) in lines.withIndex()) {
            if (line.isBlank()) continue
            try {
                val assignment = compileAssignment(line)
                validateTarget(assignment.path, Target.BODY)
                val value = evaluate(
                    assignment.expression,
                    Environment(context.copy(body = working)),
                )
                if (value == Value.Missing) continue
                val overlay = JSONObject()
                putPath(overlay, assignment.path, toAny(value))
                mergeOverlayInto(
                    result,
                    overlay,
                )
                mergeInto(working, overlay)
            } catch (error: Exception) {
                logRuntimeIssue(Target.BODY, index, error)
            }
        }
        return result
    }

    fun applyControls(
        lines: List<String>,
        body: JSONObject,
        headers: MutableMap<String, String>,
        context: RequestCustomizationContext,
    ) {
        for ((index, line) in lines.withIndex()) {
            if (line.isBlank()) continue
            try {
                val assignment = compileAssignment(line)
                validateTarget(assignment.path, Target.CONTROL)
                val value = evaluate(
                    assignment.expression,
                    Environment(
                        context.copy(headers = headers, body = body),
                    ),
                )
                if (value == Value.Missing) continue
                if (assignment.path.first() == "headers") {
                    val name = assignment.path[1]
                    if (value == Value.Delete) {
                        removeHeader(headers, name)
                    } else {
                        if (value == Value.Null) {
                            typeMismatch("headers require text or delete()")
                        }
                        setHeader(headers, name, stringify(value))
                    }
                } else {
                    val overlay = JSONObject()
                    putPath(
                        overlay,
                        assignment.path.drop(1),
                        toAny(value),
                    )
                    mergeInto(body, overlay)
                }
            } catch (error: Exception) {
                logRuntimeIssue(Target.CONTROL, index, error)
            }
        }
    }

    private fun logRuntimeIssue(
        target: Target,
        zeroBasedLine: Int,
        error: Exception,
    ) {
        val kind = (error as? ExpressionException)?.kind
            ?.name ?: error::class.java.simpleName
        AppLogger.warning(
            "RequestExpression",
            "Skipped ${target.name.lowercase()} expression line " +
                "${zeroBasedLine + 1}: $kind",
        )
    }

    fun evaluateTemplate(
        raw: String,
        context: RequestCustomizationContext,
    ): Any? {
        val value = evaluate(
            compileValue(raw),
            Environment(context),
        )
        if (value == Value.Missing) {
            invalid(
                RequestExpressionValidator.ErrorKind.UNKNOWN_TEMPLATE_REFERENCE,
                "missing value",
            )
        }
        return toAny(value)
    }

    private val knownFunctions = mapOf(
        "if" to 3..3,
        "exists" to 1..1,
        "append" to 2..Int.MAX_VALUE,
        "concat" to 1..Int.MAX_VALUE,
        "remove" to 2..Int.MAX_VALUE,
        "update" to 3..3,
        "insert" to 3..3,
        "remove_at" to 2..2,
        "min" to 1..Int.MAX_VALUE,
        "max" to 1..Int.MAX_VALUE,
        "sum" to 1..Int.MAX_VALUE,
        "avg" to 1..Int.MAX_VALUE,
        "count" to 1..1,
        "length" to 1..1,
        "clamp" to 3..3,
        "upper" to 1..1,
        "lower" to 1..1,
        "url_encode" to 1..1,
        "url_decode" to 1..1,
        "string" to 1..1,
        "json" to 1..1,
        "md5" to 1..1,
        "sha256" to 1..1,
        "deep_merge" to 2..Int.MAX_VALUE,
        "delete" to 0..0,
        "now" to 0..1,
        "format_time" to 2..4,
        "parse_time" to 2..4,
        "uuid" to 0..0,
    )

    private val knownMethods = setOf(
        "filter", "map", "reduce",
        "sum", "avg", "count", "length", "min", "max",
    )

    private fun compileAssignment(raw: String): Assignment {
        val index = assignmentIndex(raw)
        if (index <= 0) {
            invalid(
                RequestExpressionValidator.ErrorKind.MISSING_ASSIGNMENT,
                "missing assignment",
            )
        }
        val lhs = raw.substring(0, index).trim()
        val rhs = raw.substring(index + 1).trim()
        if (lhs.isEmpty() || rhs.isEmpty()) {
            invalid(
                RequestExpressionValidator.ErrorKind.EMPTY_VALUE,
                "empty assignment",
            )
        }
        return Assignment(
            parseTargetPath(lhs),
            compileValue(rhs),
        )
    }

    private fun compileValue(raw: String): Expression {
        val value = raw.trim()
        validateSourceLimits(value)
        if (isWholeTemplate(value)) {
            return Parser(
                value.drop(2).dropLast(2).trim(),
            ).parse()
        }
        if (value.contains("{{")) {
            return Expression.Template(unquoteIfNeeded(value))
        }
        return Parser(value).parse()
    }

    private fun validateTarget(path: List<String>, target: Target) {
        val valid = when (target) {
            Target.HEADER -> path.size == 1
            Target.BODY -> path.isNotEmpty()
            Target.CONTROL ->
                path.size >= 2 &&
                    (
                        path.first() == "body" ||
                            (
                                path.first() == "headers" &&
                                    path.size == 2
                                )
                        )
        }
        if (!valid) {
            invalid(
                RequestExpressionValidator.ErrorKind.INVALID_PATH,
                "invalid target",
            )
        }
    }

    private fun validateExpression(
        expression: Expression,
        variables: Set<String>,
    ) {
        when (expression) {
            is Expression.Literal -> Unit
            is Expression.Template ->
                templateExpressions(expression.source).forEach {
                    validateExpression(it, variables)
                }
            is Expression.Identifier -> {
                if (expression.name !in variables &&
                    expression.name !in setOf(
                        "provider", "model", "session", "headers", "body",
                    )
                ) {
                    invalid(
                        RequestExpressionValidator.ErrorKind.UNKNOWN_TEMPLATE_REFERENCE,
                        "unknown identifier ${expression.name}",
                    )
                }
            }
            is Expression.ArrayExpression ->
                expression.values.forEach {
                    validateExpression(it, variables)
                }
            is Expression.ObjectExpression ->
                expression.values.forEach {
                    validateExpression(it.second, variables)
                }
            is Expression.Unary ->
                validateExpression(expression.value, variables)
            is Expression.Binary -> {
                validateExpression(expression.lhs, variables)
                validateExpression(expression.rhs, variables)
            }
            is Expression.Conditional -> {
                validateExpression(expression.condition, variables)
                validateExpression(expression.ifTrue, variables)
                validateExpression(expression.ifFalse, variables)
            }
            is Expression.Call -> {
                val range = knownFunctions[expression.name.lowercase()]
                    ?: invalid(
                        RequestExpressionValidator.ErrorKind.UNKNOWN_FUNCTION,
                        "unknown function ${expression.name}",
                    )
                if (expression.arguments.size !in range) {
                    invalid(
                        RequestExpressionValidator.ErrorKind.INVALID_FUNCTION_ARGUMENTS,
                        "invalid arguments",
                    )
                }
                expression.arguments.forEach {
                    validateExpression(it, variables)
                }
            }
            is Expression.Member ->
                validateExpression(expression.base, variables)
            is Expression.Index -> {
                validateExpression(expression.base, variables)
                validateExpression(expression.index, variables)
            }
            is Expression.Method -> {
                val name = expression.name.lowercase()
                if (name !in knownMethods) {
                    invalid(
                        RequestExpressionValidator.ErrorKind.UNKNOWN_FUNCTION,
                        "unknown method ${expression.name}",
                    )
                }
                validateExpression(expression.base, variables)
                when (name) {
                    "filter", "map" -> {
                        val variable =
                            (expression.arguments.getOrNull(0) as? Expression.Identifier)
                                ?.name
                                ?: invalidArguments()
                        if (expression.arguments.size != 2) invalidArguments()
                        validateExpression(
                            expression.arguments[1],
                            variables + variable,
                        )
                    }
                    "reduce" -> {
                        if (expression.arguments.size != 4) invalidArguments()
                        val accumulator =
                            (expression.arguments[0] as? Expression.Identifier)
                                ?.name
                                ?: invalidArguments()
                        val item =
                            (expression.arguments[1] as? Expression.Identifier)
                                ?.name
                                ?: invalidArguments()
                        validateExpression(expression.arguments[2], variables)
                        validateExpression(
                            expression.arguments[3],
                            variables + accumulator + item,
                        )
                    }
                    else -> if (expression.arguments.isNotEmpty()) {
                        invalidArguments()
                    }
                }
            }
        }
    }

    private fun evaluate(
        expression: Expression,
        environment: Environment,
    ): Value {
        environment.tick()
        return when (expression) {
            is Expression.Literal -> expression.value
            is Expression.Template ->
                evaluateTemplateString(expression.source, environment)
            is Expression.Identifier ->
                environment.locals[expression.name]
                    ?: rootValue(expression.name, environment.context)
            is Expression.ArrayExpression ->
                Value.ArrayValue(
                    expression.values.map {
                        evaluate(it, environment)
                    },
                )
            is Expression.ObjectExpression ->
                Value.ObjectValue(
                    LinkedHashMap<String, Value>().also { result ->
                        expression.values.forEach { (key, value) ->
                            result[key] = evaluate(value, environment)
                        }
                    },
                )
            is Expression.Unary ->
                evaluateUnary(expression, environment)
            is Expression.Binary ->
                evaluateBinary(expression, environment)
            is Expression.Conditional -> {
                when (val condition = evaluate(expression.condition, environment)) {
                    is Value.Bool -> evaluate(
                        if (condition.value) expression.ifTrue else expression.ifFalse,
                        environment,
                    )
                    Value.Missing -> Value.Missing
                    else -> typeMismatch("condition requires a boolean")
                }
            }
            is Expression.Call ->
                evaluateCall(expression, environment)
            is Expression.Member ->
                member(
                    expression.name,
                    evaluate(expression.base, environment),
                )
            is Expression.Index ->
                indexed(
                    evaluate(expression.base, environment),
                    evaluate(expression.index, environment),
                )
            is Expression.Method ->
                evaluateMethod(expression, environment)
        }
    }

    private fun evaluateUnary(
        expression: Expression.Unary,
        environment: Environment,
    ): Value {
        val value = evaluate(expression.value, environment)
        if (value == Value.Missing) return Value.Missing
        return when (expression.operation) {
            "!" -> Value.Bool(
                !(value as? Value.Bool)?.value
                    .orTypeMismatch("! requires a boolean"),
            )
            "-" -> when (value) {
                is Value.Integer -> Value.Integer(-value.value)
                is Value.Decimal -> Value.Decimal(-value.value)
                else -> typeMismatch("- requires a number")
            }
            "+" -> if (number(value) != null) value
            else typeMismatch("+ requires a number")
            else -> invalidArguments()
        }
    }

    private fun evaluateBinary(
        expression: Expression.Binary,
        environment: Environment,
    ): Value {
        val lhs = evaluate(expression.lhs, environment)
        when (expression.operation) {
            "??" -> return if (lhs == Value.Missing || lhs == Value.Null) {
                evaluate(expression.rhs, environment)
            } else {
                lhs
            }
            "&&" -> {
                if (lhs == Value.Bool(false)) return Value.Bool(false)
                if (lhs == Value.Missing) return Value.Missing
                if (lhs != Value.Bool(true)) {
                    return typeMismatch("&& requires booleans")
                }
                val rhs = evaluate(expression.rhs, environment)
                return when (rhs) {
                    is Value.Bool -> rhs
                    Value.Missing -> Value.Missing
                    else -> typeMismatch("&& requires booleans")
                }
            }
            "||" -> {
                if (lhs == Value.Bool(true)) return Value.Bool(true)
                if (lhs == Value.Missing) return Value.Missing
                if (lhs != Value.Bool(false)) {
                    return typeMismatch("|| requires booleans")
                }
                val rhs = evaluate(expression.rhs, environment)
                return when (rhs) {
                    is Value.Bool -> rhs
                    Value.Missing -> Value.Missing
                    else -> typeMismatch("|| requires booleans")
                }
            }
        }
        val rhs = evaluate(expression.rhs, environment)
        if (expression.operation == "==" || expression.operation == "!=") {
            val equal = valuesEqual(lhs, rhs)
            return Value.Bool(
                if (expression.operation == "==") equal else !equal,
            )
        }
        if (lhs == Value.Missing || rhs == Value.Missing) {
            return Value.Missing
        }
        return when (expression.operation) {
            "+" -> when {
                lhs is Value.Text && rhs is Value.Text ->
                    Value.Text(lhs.value + rhs.value)
                lhs is Value.ArrayValue && rhs is Value.ArrayValue ->
                    Value.ArrayValue(lhs.values + rhs.values)
                else -> numericBinary(lhs, rhs) { left, right -> left + right }
            }
            "-" -> numericBinary(lhs, rhs) { left, right -> left - right }
            "*" -> numericBinary(lhs, rhs) { left, right -> left * right }
            "/" -> {
                val left = number(lhs) ?: typeMismatch("/ requires numbers")
                val right = number(rhs) ?: typeMismatch("/ requires numbers")
                if (right == 0.0) invalidArguments()
                numericResult(left / right, preserveInteger = false)
            }
            "%" -> {
                val left = integer(lhs) ?: typeMismatch("% requires integers")
                val right = integer(rhs) ?: typeMismatch("% requires integers")
                if (right == 0L) invalidArguments()
                Value.Integer(left % right)
            }
            ">", ">=", "<", "<=" -> compare(
                lhs,
                rhs,
                expression.operation,
            )
            else -> invalidArguments()
        }
    }

    private fun evaluateCall(
        expression: Expression.Call,
        environment: Environment,
    ): Value {
        val name = expression.name.lowercase()
        val range = knownFunctions[name]
            ?: invalid(
                RequestExpressionValidator.ErrorKind.UNKNOWN_FUNCTION,
                "unknown function",
            )
        if (expression.arguments.size !in range) invalidArguments()
        if (name == "if") {
            return when (val condition = evaluate(expression.arguments[0], environment)) {
                is Value.Bool -> evaluate(
                    expression.arguments[if (condition.value) 1 else 2],
                    environment,
                )
                Value.Missing -> Value.Missing
                else -> typeMismatch("if condition requires a boolean")
            }
        }
        if (name == "exists") {
            return Value.Bool(
                evaluate(expression.arguments[0], environment) != Value.Missing,
            )
        }
        if (name == "uuid") return Value.Text(UUID.randomUUID().toString())
        if (name == "delete") return Value.Delete
        val values = expression.arguments.map {
            evaluate(it, environment)
        }
        if (values.any { it == Value.Missing }) return Value.Missing
        if (name == "now") {
            return Value.Integer(
                timestampUnit(values.firstOrNull())
                    .fromInstant(Instant.now()),
            )
        }
        return applyFunction(name, values)
    }

    private fun applyFunction(name: String, values: List<Value>): Value {
        return when (name) {
            "append" -> {
                val source = (values[0] as? Value.ArrayValue)
                    ?.values
                    ?: typeMismatch("append requires an array")
                Value.ArrayValue(source + values.drop(1))
            }
            "concat" -> Value.ArrayValue(
                values.flatMap {
                    (it as? Value.ArrayValue)?.values
                        ?: typeMismatch("concat requires arrays")
                },
            )
            "remove" -> {
                val source = (values[0] as? Value.ArrayValue)
                    ?.values
                    ?: typeMismatch("remove requires an array")
                val removals = values.drop(1).flatMap {
                    (it as? Value.ArrayValue)?.values ?: listOf(it)
                }
                Value.ArrayValue(
                    source.filter { element ->
                        removals.none {
                            partialMatch(element, it)
                        }
                    },
                )
            }
            "update" -> {
                val source = (values[0] as? Value.ArrayValue)
                    ?.values
                    ?: typeMismatch("update requires an array")
                val criteria = values[1] as? Value.ObjectValue
                    ?: typeMismatch("update requires an object condition")
                val patch = values[2] as? Value.ObjectValue
                    ?: typeMismatch("update requires an object patch")
                Value.ArrayValue(
                    source.map {
                        if (partialMatch(it, criteria)) {
                            deepMerge(it, patch)
                        } else {
                            it
                        }
                    },
                )
            }
            "insert" -> {
                val source = (values[0] as? Value.ArrayValue)
                    ?.values
                    ?.toMutableList()
                    ?: typeMismatch("insert requires an array")
                val rawIndex = integer(values[1])
                    ?: typeMismatch("insert requires an integer index")
                val index = if (rawIndex < 0) {
                    max(0, source.size + rawIndex.toInt() + 1)
                } else {
                    min(rawIndex.toInt(), source.size)
                }
                source.add(index, values[2])
                Value.ArrayValue(source)
            }
            "remove_at" -> {
                val source = (values[0] as? Value.ArrayValue)
                    ?.values
                    ?.toMutableList()
                    ?: typeMismatch("remove_at requires an array")
                val rawIndex = integer(values[1])
                    ?: typeMismatch("remove_at requires an integer index")
                normalizedIndex(rawIndex, source.size)?.let(source::removeAt)
                Value.ArrayValue(source)
            }
            "min", "max" -> {
                val candidates = numericCandidates(values)
                if (candidates.isEmpty()) {
                    typeMismatch("$name requires numbers")
                }
                numericResult(
                    if (name == "min") candidates.min() else candidates.max(),
                    allIntegers(values),
                )
            }
            "sum" -> {
                val candidates = numericCandidates(values)
                if (candidates.isEmpty()) typeMismatch("sum requires numbers")
                numericResult(candidates.sum(), allIntegers(values))
            }
            "avg" -> {
                val candidates = numericCandidates(values)
                if (candidates.isEmpty()) typeMismatch("avg requires numbers")
                numericResult(
                    candidates.average(),
                    preserveInteger = false,
                )
            }
            "count", "length" -> collectionLength(values[0])
            "clamp" -> {
                val value = number(values[0])
                    ?: typeMismatch("clamp requires numbers")
                val lower = number(values[1])
                    ?: typeMismatch("clamp requires numbers")
                val upper = number(values[2])
                    ?: typeMismatch("clamp requires numbers")
                if (lower > upper) invalidArguments()
                numericResult(
                    min(max(value, lower), upper),
                    values.all { integer(it) != null },
                )
            }
            "upper" -> Value.Text(
                text(values[0]).uppercase(Locale.ROOT),
            )
            "lower" -> Value.Text(
                text(values[0]).lowercase(Locale.ROOT),
            )
            "url_encode" -> Value.Text(
                urlEncode(text(values[0])),
            )
            "url_decode" -> Value.Text(
                urlDecode(text(values[0])),
            )
            "string" -> Value.Text(stringify(values[0]))
            "json" -> Value.Text(jsonString(values[0]))
            "md5" -> Value.Text(hash("MD5", text(values[0])))
            "sha256" -> Value.Text(hash("SHA-256", text(values[0])))
            "format_time" -> Value.Text(formatTime(values))
            "parse_time" -> Value.Integer(parseTime(values))
            "deep_merge" -> values.drop(1).fold(values[0], ::deepMerge)
            else -> invalid(
                RequestExpressionValidator.ErrorKind.UNKNOWN_FUNCTION,
                "unknown function $name",
            )
        }
    }

    private enum class TimestampUnit {
        SECONDS,
        MILLISECONDS;

        fun fromInstant(instant: Instant): Long = when (this) {
            SECONDS -> instant.epochSecond
            MILLISECONDS -> instant.toEpochMilli()
        }

        fun toInstant(timestamp: Long): Instant = when (this) {
            SECONDS -> Instant.ofEpochSecond(timestamp)
            MILLISECONDS -> Instant.ofEpochMilli(timestamp)
        }
    }

    private fun timestampUnit(value: Value?): TimestampUnit {
        if (value == null) return TimestampUnit.SECONDS
        return when (text(value).lowercase(Locale.ROOT)) {
            "seconds" -> TimestampUnit.SECONDS
            "milliseconds" -> TimestampUnit.MILLISECONDS
            else -> invalidArguments()
        }
    }

    private fun timeZone(value: Value?): ZoneId {
        if (value == null) return ZoneId.systemDefault()
        return try {
            ZoneId.of(text(value))
        } catch (_: Throwable) {
            invalidArguments()
        }
    }

    private fun timeFormatter(
        rawFormat: String,
        zoneId: ZoneId,
    ): DateTimeFormatter {
        if (rawFormat.isEmpty()) invalidArguments()
        val tokens = listOf(
            "YYYY" to "uuuu",
            "SSS" to "SSS",
            "YY" to "uu",
            "MM" to "MM",
            "DD" to "dd",
            "HH" to "HH",
            "hh" to "hh",
            "mm" to "mm",
            "ss" to "ss",
            "SS" to "SS",
            "M" to "M",
            "D" to "d",
            "H" to "H",
            "h" to "h",
            "m" to "m",
            "s" to "s",
            "S" to "S",
            "a" to "a",
        )
        val builder = DateTimeFormatterBuilder()
            .parseCaseSensitive()
        var index = 0
        while (index < rawFormat.length) {
            val token = tokens.firstOrNull { (source, _) ->
                rawFormat.startsWith(source, index)
            }
            if (token != null) {
                builder.appendPattern(token.second)
                index += token.first.length
            } else {
                builder.appendLiteral(rawFormat[index])
                index++
            }
        }
        return builder
            .toFormatter(Locale.ROOT)
            .withResolverStyle(ResolverStyle.STRICT)
            .withZone(zoneId)
    }

    private fun formatTime(values: List<Value>): String {
        val timestamp = integer(values[0])
            ?: typeMismatch("format_time requires an integer timestamp")
        val formatter = timeFormatter(
            text(values[1]),
            timeZone(values.getOrNull(3)),
        )
        return try {
            formatter.format(
                timestampUnit(values.getOrNull(2))
                    .toInstant(timestamp),
            )
        } catch (_: Throwable) {
            invalidArguments()
        }
    }

    private fun parseTime(values: List<Value>): Long {
        val rawText = text(values[0])
        val rawFormat = text(values[1])
        if (
            (
                !rawFormat.contains("YYYY") &&
                    !rawFormat.contains("YY")
                ) ||
            !rawFormat.contains("M") ||
            !rawFormat.contains("D") ||
            (
                rawFormat.contains("h") &&
                    !rawFormat.contains("a")
                )
        ) {
            invalidArguments()
        }
        val formatter = timeFormatter(
            rawFormat,
            timeZone(values.getOrNull(3)),
        )
        val instant = try {
            when (
                val parsed = formatter.parseBest(
                    rawText,
                    ZonedDateTime::from,
                    LocalDateTime::from,
                    LocalDate::from,
                )
            ) {
                is ZonedDateTime -> parsed.toInstant()
                is LocalDateTime ->
                    parsed.atZone(formatter.zone).toInstant()
                is LocalDate ->
                    parsed.atStartOfDay(formatter.zone).toInstant()
                else -> invalidArguments()
            }
        } catch (_: Throwable) {
            invalidArguments()
        }
        if (formatter.format(instant) != rawText) {
            invalidArguments()
        }
        return timestampUnit(values.getOrNull(2))
            .fromInstant(instant)
    }

    private fun urlEncode(value: String): String =
        buildString(value.length) {
            value.toByteArray(StandardCharsets.UTF_8).forEach { byte ->
                val unsigned = byte.toInt() and 0xFF
                if (
                    unsigned in 'A'.code..'Z'.code ||
                    unsigned in 'a'.code..'z'.code ||
                    unsigned in '0'.code..'9'.code ||
                    unsigned == '-'.code ||
                    unsigned == '.'.code ||
                    unsigned == '_'.code ||
                    unsigned == '~'.code
                ) {
                    append(unsigned.toChar())
                } else {
                    append('%')
                    append(HEX_DIGITS[unsigned ushr 4])
                    append(HEX_DIGITS[unsigned and 0x0F])
                }
            }
        }

    private fun urlDecode(value: String): String {
        val input = value.toByteArray(StandardCharsets.UTF_8)
        val output = ArrayList<Byte>(input.size)
        var index = 0
        while (index < input.size) {
            val current = input[index].toInt() and 0xFF
            if (current == '%'.code) {
                if (index + 2 >= input.size) invalidArguments()
                val high = hexValue(input[index + 1])
                val low = hexValue(input[index + 2])
                if (high < 0 || low < 0) invalidArguments()
                output += ((high shl 4) or low).toByte()
                index += 3
            } else {
                output += input[index]
                index++
            }
        }
        return runCatching {
            StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(output.toByteArray()))
                .toString()
        }.getOrElse {
            invalidArguments()
        }
    }

    private fun hexValue(byte: Byte): Int =
        when (val character = byte.toInt().toChar()) {
            in '0'..'9' -> character.code - '0'.code
            in 'A'..'F' -> character.code - 'A'.code + 10
            in 'a'..'f' -> character.code - 'a'.code + 10
            else -> -1
        }

    private const val HEX_DIGITS = "0123456789ABCDEF"

    private fun evaluateMethod(
        expression: Expression.Method,
        environment: Environment,
    ): Value {
        val base = evaluate(expression.base, environment)
        if (base == Value.Missing) return Value.Missing
        val name = expression.name.lowercase()
        return when (name) {
            "filter", "map" -> {
                val source = (base as? Value.ArrayValue)?.values
                    ?: typeMismatch("$name requires an array")
                if (expression.arguments.size != 2) invalidArguments()
                val variable =
                    (expression.arguments[0] as? Expression.Identifier)
                        ?.name
                        ?: invalidArguments()
                val result = mutableListOf<Value>()
                for (item in source) {
                    val hadPrevious = environment.locals.containsKey(variable)
                    val previous = environment.locals[variable]
                    environment.locals[variable] = item
                    val evaluated = evaluate(expression.arguments[1], environment)
                    if (hadPrevious) {
                        environment.locals[variable] = previous!!
                    } else {
                        environment.locals.remove(variable)
                    }
                    if (name == "filter") {
                        when (evaluated) {
                            Value.Bool(true) -> result += item
                            Value.Bool(false), Value.Missing -> Unit
                            else -> typeMismatch(
                                "filter predicate requires a boolean",
                            )
                        }
                    } else {
                        if (evaluated == Value.Missing) return Value.Missing
                        result += evaluated
                    }
                }
                Value.ArrayValue(result)
            }
            "reduce" -> {
                val source = (base as? Value.ArrayValue)?.values
                    ?: typeMismatch("reduce requires an array")
                if (expression.arguments.size != 4) invalidArguments()
                val accumulatorName =
                    (expression.arguments[0] as? Expression.Identifier)
                        ?.name
                        ?: invalidArguments()
                val itemName =
                    (expression.arguments[1] as? Expression.Identifier)
                        ?.name
                        ?: invalidArguments()
                var accumulator = evaluate(expression.arguments[2], environment)
                for (item in source) {
                    val previousAccumulator = environment.locals[accumulatorName]
                    val hadAccumulator =
                        environment.locals.containsKey(accumulatorName)
                    val previousItem = environment.locals[itemName]
                    val hadItem = environment.locals.containsKey(itemName)
                    environment.locals[accumulatorName] = accumulator
                    environment.locals[itemName] = item
                    accumulator = evaluate(expression.arguments[3], environment)
                    restoreLocal(
                        environment.locals,
                        accumulatorName,
                        hadAccumulator,
                        previousAccumulator,
                    )
                    restoreLocal(
                        environment.locals,
                        itemName,
                        hadItem,
                        previousItem,
                    )
                    if (accumulator == Value.Missing) return Value.Missing
                }
                accumulator
            }
            "sum", "avg", "count", "length", "min", "max" -> {
                if (expression.arguments.isNotEmpty()) invalidArguments()
                applyFunction(name, listOf(base))
            }
            else -> invalid(
                RequestExpressionValidator.ErrorKind.UNKNOWN_FUNCTION,
                "unknown method ${expression.name}",
            )
        }
    }

    private fun evaluateTemplateString(
        raw: String,
        environment: Environment,
    ): Value {
        val matches = templateRanges(raw)
        if (matches.size == 1 &&
            matches[0].start == 0 &&
            matches[0].end == raw.length
        ) {
            return evaluate(matches[0].expression, environment)
        }
        val output = StringBuilder(raw)
        matches.asReversed().forEach { match ->
            val value = evaluate(match.expression, environment)
            if (value == Value.Missing) return Value.Missing
            output.replace(match.start, match.end, stringify(value))
        }
        return Value.Text(output.toString())
    }

    private data class TemplateRange(
        val start: Int,
        val end: Int,
        val expression: Expression,
    )

    private fun templateExpressions(raw: String): List<Expression> =
        templateRanges(raw).map { it.expression }

    private fun templateRanges(raw: String): List<TemplateRange> {
        val result = mutableListOf<TemplateRange>()
        var search = 0
        while (true) {
            val start = raw.indexOf("{{", search)
            if (start < 0) break
            val end = raw.indexOf("}}", start + 2)
            if (end < 0) {
                invalid(
                    RequestExpressionValidator.ErrorKind.UNBALANCED_DELIMITER,
                    "unterminated template",
                )
            }
            result += TemplateRange(
                start,
                end + 2,
                raw.substring(start + 2, end).trim().let { source ->
                    validateSourceLimits(source)
                    Parser(source).parse()
                },
            )
            search = end + 2
        }
        if (raw.indexOf("}}", search) >= 0) {
            invalid(
                RequestExpressionValidator.ErrorKind.UNBALANCED_DELIMITER,
                "unmatched template",
            )
        }
        return result
    }

    private fun validateSourceLimits(source: String) {
        if (source.toByteArray(Charsets.UTF_8).size > 65_536) {
            invalid(
                RequestExpressionValidator.ErrorKind.EVALUATION_LIMIT,
                "expression length limit exceeded",
            )
        }
        var quote: Char? = null
        var escaped = false
        var depth = 0
        source.forEach { character ->
            if (quote != null) {
                when {
                    escaped -> escaped = false
                    character == '\\' -> escaped = true
                    character == quote -> quote = null
                }
            } else {
                when (character) {
                    '"', '\'' -> quote = character
                    '(', '[', '{' -> {
                        depth++
                        if (depth > 128) {
                            invalid(
                                RequestExpressionValidator.ErrorKind.EVALUATION_LIMIT,
                                "expression nesting limit exceeded",
                            )
                        }
                    }
                    ')', ']', '}' -> depth = max(0, depth - 1)
                }
            }
        }
    }

    private fun rootValue(
        name: String,
        context: RequestCustomizationContext,
    ): Value {
        return when (name) {
            "provider" -> Value.ObjectValue(
                linkedMapOf(
                    "id" to Value.Text(context.provider.id),
                    "label" to Value.Text(context.provider.label),
                    "type" to Value.Text(context.provider.providerType.name),
                    "credentialType" to Value.Text(
                        context.provider.credentialType.name,
                    ),
                    "apiKey" to (
                        context.apiKey?.let(Value::Text)
                            ?: Value.Missing
                        ),
                    "baseURL" to (
                        context.provider.effectiveBaseURL
                            ?.takeIf { it.isNotBlank() }
                            ?.let(Value::Text)
                            ?: Value.Missing
                        ),
                ),
            )
            "model" -> Value.ObjectValue(
                linkedMapOf(
                    "id" to Value.Text(context.model.id),
                    "displayName" to Value.Text(context.model.displayName),
                    "provider" to Value.Text(context.model.provider),
                ),
            )
            "session" -> Value.ObjectValue(
                linkedMapOf(
                    "id" to (
                        context.sessionId?.let(Value::Text)
                            ?: Value.Missing
                        ),
                ),
            )
            "headers" -> Value.ObjectValue(
                LinkedHashMap<String, Value>().also { result ->
                    context.headers.forEach { (key, value) ->
                        result[key] = Value.Text(value)
                    }
                },
                caseInsensitive = true,
            )
            "body" -> fromAny(context.body)
            else -> Value.Missing
        }
    }

    private fun member(name: String, value: Value): Value {
        val objectValue = value as? Value.ObjectValue
            ?: return Value.Missing
        objectValue.values[name]?.let { return it }
        if (objectValue.caseInsensitive) {
            objectValue.values.entries.firstOrNull {
                it.key.equals(name, ignoreCase = true)
            }?.let { return it.value }
        }
        return Value.Missing
    }

    private fun indexed(value: Value, index: Value): Value {
        return when (value) {
            is Value.ArrayValue -> {
                val rawIndex = integer(index)
                    ?: typeMismatch("array index must be an integer")
                normalizedIndex(rawIndex, value.values.size)
                    ?.let(value.values::get)
                    ?: Value.Missing
            }
            is Value.ObjectValue -> {
                val key = (index as? Value.Text)?.value
                    ?: typeMismatch("object index must be a string")
                member(key, value)
            }
            else -> Value.Missing
        }
    }

    private fun normalizedIndex(index: Long, count: Int): Int? {
        val normalized = if (index < 0) count + index.toInt() else index.toInt()
        return normalized.takeIf { it in 0 until count }
    }

    private fun numericBinary(
        lhs: Value,
        rhs: Value,
        operation: (Double, Double) -> Double,
    ): Value {
        val left = number(lhs) ?: typeMismatch("arithmetic requires numbers")
        val right = number(rhs) ?: typeMismatch("arithmetic requires numbers")
        val result = operation(left, right)
        return numericResult(
            result,
            integer(lhs) != null &&
                integer(rhs) != null &&
                result % 1.0 == 0.0,
        )
    }

    private fun compare(lhs: Value, rhs: Value, operation: String): Value {
        val comparison = when {
            lhs is Value.Text && rhs is Value.Text ->
                lhs.value.compareTo(rhs.value)
            number(lhs) != null && number(rhs) != null ->
                number(lhs)!!.compareTo(number(rhs)!!)
            else -> typeMismatch(
                "$operation requires numbers or strings",
            )
        }
        return Value.Bool(
            when (operation) {
                ">" -> comparison > 0
                ">=" -> comparison >= 0
                "<" -> comparison < 0
                else -> comparison <= 0
            },
        )
    }

    private fun number(value: Value): Double? = when (value) {
        is Value.Integer -> value.value.toDouble()
        is Value.Decimal -> value.value
        else -> null
    }

    private fun integer(value: Value): Long? = when (value) {
        is Value.Integer -> value.value
        is Value.Decimal ->
            value.value.takeIf { it % 1.0 == 0.0 }?.toLong()
        else -> null
    }

    private fun numericResult(
        value: Double,
        preserveInteger: Boolean,
    ): Value {
        if (!value.isFinite()) return Value.Missing
        return if (preserveInteger) {
            Value.Integer(value.toLong())
        } else {
            Value.Decimal(value)
        }
    }

    private fun numericCandidates(values: List<Value>): List<Double> {
        val expanded = values.flatMap { value ->
            (value as? Value.ArrayValue)?.values
                ?: listOf(value)
        }
        val result = expanded.mapNotNull(::number)
        if (result.size != expanded.size) {
            typeMismatch("numeric function requires numbers")
        }
        return result
    }

    private fun allIntegers(values: List<Value>): Boolean {
        val expanded = values.flatMap { value ->
            (value as? Value.ArrayValue)?.values
                ?: listOf(value)
        }
        return expanded.isNotEmpty() && expanded.all { integer(it) != null }
    }

    private fun collectionLength(value: Value): Value.Integer = when (value) {
        is Value.Text -> Value.Integer(
            value.value.codePointCount(0, value.value.length).toLong(),
        )
        is Value.ArrayValue -> Value.Integer(value.values.size.toLong())
        is Value.ObjectValue -> Value.Integer(value.values.size.toLong())
        else -> typeMismatch("length requires string, array, or object")
    }

    private fun text(value: Value): String =
        (value as? Value.Text)?.value
            ?: typeMismatch("string value required")

    private fun valuesEqual(lhs: Value, rhs: Value): Boolean {
        if (lhs == Value.Missing || rhs == Value.Missing) return false
        val leftNumber = number(lhs)
        val rightNumber = number(rhs)
        if (leftNumber != null && rightNumber != null) {
            return leftNumber == rightNumber
        }
        return when {
            lhs is Value.ArrayValue && rhs is Value.ArrayValue ->
                lhs.values.size == rhs.values.size &&
                    lhs.values.zip(rhs.values).all {
                        valuesEqual(it.first, it.second)
                    }
            lhs is Value.ObjectValue && rhs is Value.ObjectValue ->
                lhs.values.size == rhs.values.size &&
                    lhs.values.all { (key, value) ->
                        rhs.values[key]?.let {
                            valuesEqual(value, it)
                        } == true
                    }
            else -> lhs == rhs
        }
    }

    private fun partialMatch(value: Value, candidate: Value): Boolean {
        if (value !is Value.ObjectValue ||
            candidate !is Value.ObjectValue
        ) {
            return valuesEqual(value, candidate)
        }
        return candidate.values.all { (key, expected) ->
            value.values[key]?.let {
                partialMatch(it, expected)
            } == true
        }
    }

    private fun deepMerge(lhs: Value, rhs: Value): Value {
        if (lhs !is Value.ObjectValue ||
            rhs !is Value.ObjectValue
        ) {
            return rhs
        }
        val result = LinkedHashMap(lhs.values)
        rhs.values.forEach { (key, value) ->
            if (value == Value.Delete) {
                result.remove(key)
            } else {
                result[key] = result[key]?.let {
                    deepMerge(it, value)
                } ?: value
            }
        }
        return Value.ObjectValue(result, lhs.caseInsensitive)
    }

    private fun fromAny(value: Any?): Value = when (value) {
        null, JSONObject.NULL -> Value.Null
        is Boolean -> Value.Bool(value)
        is Byte, is Short, is Int, is Long ->
            Value.Integer((value as Number).toLong())
        is Number -> Value.Decimal(value.toDouble())
        is String -> Value.Text(value)
        is JSONArray -> Value.ArrayValue(
            (0 until value.length()).map {
                fromAny(value.opt(it))
            },
        )
        is JSONObject -> Value.ObjectValue(
            linkedMapOf<String, Value>().also { result ->
                value.keys().forEach { key ->
                    result[key] = fromAny(value.opt(key))
                }
            },
        )
        is Map<*, *> -> Value.ObjectValue(
            linkedMapOf<String, Value>().also { result ->
                value.forEach { (key, child) ->
                    if (key is String) result[key] = fromAny(child)
                }
            },
        )
        is Iterable<*> -> Value.ArrayValue(value.map(::fromAny))
        else -> Value.Text(value.toString())
    }

    private fun toAny(value: Value): Any? = when (value) {
        Value.Missing -> invalidArguments()
        Value.Null -> JSONObject.NULL
        Value.Delete -> MinixDeleteMarker
        is Value.Bool -> value.value
        is Value.Integer ->
            value.value.takeIf { it !in Int.MIN_VALUE..Int.MAX_VALUE }
                ?: value.value.toInt()
        is Value.Decimal -> value.value
        is Value.Text -> value.value
        is Value.ArrayValue -> JSONArray().also { result ->
            if (value.values.any { it == Value.Delete }) {
                typeMismatch("delete() cannot be an array element")
            }
            value.values.forEach { result.put(toAny(it)) }
        }
        is Value.ObjectValue -> JSONObject().also { result ->
            value.values.forEach { (key, child) ->
                result.put(key, toAny(child))
            }
        }
    }

    private fun stringify(value: Value): String = when (value) {
        Value.Missing -> invalidArguments()
        Value.Null -> ""
        Value.Delete ->
            typeMismatch("delete() is only valid in request mutations")
        is Value.Bool -> value.value.toString()
        is Value.Integer -> value.value.toString()
        is Value.Decimal -> value.value.toString()
        is Value.Text -> value.value
        is Value.ArrayValue, is Value.ObjectValue -> jsonString(value)
    }

    private fun jsonString(value: Value): String = when (value) {
        Value.Missing -> invalidArguments()
        Value.Null -> "null"
        Value.Delete ->
            typeMismatch("delete() is only valid in request mutations")
        is Value.Bool -> value.value.toString()
        is Value.Integer -> value.value.toString()
        is Value.Decimal -> JSONObject.numberToString(value.value)
        is Value.Text -> JSONObject.quote(value.value)
        is Value.ArrayValue -> value.values.joinToString(
            separator = ",",
            prefix = "[",
            postfix = "]",
        ) { jsonString(it) }
        is Value.ObjectValue -> value.values.entries
            .sortedBy { it.key }
            .joinToString(separator = ",", prefix = "{", postfix = "}") {
                "${JSONObject.quote(it.key)}:${jsonString(it.value)}"
            }
    }

    private fun hash(algorithm: String, value: String): String =
        MessageDigest.getInstance(algorithm)
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    private fun restoreLocal(
        locals: MutableMap<String, Value>,
        name: String,
        existed: Boolean,
        previous: Value?,
    ) {
        if (existed) {
            locals[name] = previous!!
        } else {
            locals.remove(name)
        }
    }

    private fun setHeader(
        headers: MutableMap<String, String>,
        name: String,
        value: String,
    ) {
        val existing = headers.keys.firstOrNull {
            it.equals(name, ignoreCase = true)
        }
        headers[existing ?: name] = value
    }

    private fun removeHeader(
        headers: MutableMap<String, String>,
        name: String,
    ) {
        headers.keys.firstOrNull {
            it.equals(name, ignoreCase = true)
        }?.let(headers::remove)
    }

    private fun putPath(
        target: JSONObject,
        path: List<String>,
        value: Any?,
    ) {
        if (path.isEmpty()) return
        var current = target
        path.dropLast(1).forEach { part ->
            current = current.optJSONObject(part)
                ?: JSONObject().also { current.put(part, it) }
        }
        current.put(path.last(), value)
    }

    private fun mergeInto(base: JSONObject, overlay: JSONObject) {
        overlay.keys().forEach { key ->
            val value = overlay.opt(key)
            val existing = base.opt(key)
            when {
                value === MinixDeleteMarker -> base.remove(key)
                existing is JSONObject && value is JSONObject ->
                    mergeInto(existing, value)
                value is JSONObject ->
                    base.put(key, JSONObject().also {
                        mergeInto(it, value)
                    })
                else -> base.put(key, value)
            }
        }
    }

    private fun mergeOverlayInto(
        base: JSONObject,
        overlay: JSONObject,
    ) {
        overlay.keys().forEach { key ->
            val value = overlay.opt(key)
            val existing = base.opt(key)
            if (existing is JSONObject && value is JSONObject) {
                mergeOverlayInto(existing, value)
            } else {
                // Keep JSONObject.NULL until the overlay reaches the request.
                base.put(key, value)
            }
        }
    }

    private fun assignmentIndex(raw: String): Int {
        var quote: Char? = null
        var escaped = false
        var depth = 0
        raw.forEachIndexed { index, character ->
            if (quote != null) {
                when {
                    escaped -> escaped = false
                    character == '\\' -> escaped = true
                    character == quote -> quote = null
                }
                return@forEachIndexed
            }
            when (character) {
                '"', '\'' -> quote = character
                '(', '[', '{' -> depth++
                ')', ']', '}' -> depth = max(0, depth - 1)
                '=' -> if (
                    depth == 0 &&
                    raw.getOrNull(index + 1) != '=' &&
                    raw.getOrNull(index - 1) !in setOf('!', '>', '<')
                ) {
                    return index
                }
            }
        }
        return -1
    }

    private fun parseTargetPath(raw: String): List<String> {
        val text = raw.trim()
        val result = mutableListOf<String>()
        val token = StringBuilder()
        fun flush() {
            token.toString().trim().takeIf { it.isNotEmpty() }
                ?.let(result::add)
            token.clear()
        }
        var index = 0
        while (index < text.length) {
            when (val character = text[index]) {
                '.' -> {
                    flush()
                    index++
                }
                '[' -> {
                    flush()
                    index++
                    while (text.getOrNull(index)?.isWhitespace() == true) index++
                    val quote = text.getOrNull(index)
                    if (quote != '"' && quote != '\'') invalidPath()
                    index++
                    val value = StringBuilder()
                    while (index < text.length && text[index] != quote) {
                        value.append(text[index++])
                    }
                    if (index >= text.length) invalidPath()
                    index++
                    while (text.getOrNull(index)?.isWhitespace() == true) index++
                    if (text.getOrNull(index) != ']') invalidPath()
                    index++
                    result += value.toString()
                }
                else -> {
                    if (!character.isLetterOrDigit() &&
                        character != '_' &&
                        character != '-'
                    ) {
                        invalidPath()
                    }
                    token.append(character)
                    index++
                }
            }
        }
        flush()
        if (result.isEmpty() || result.any { it.isEmpty() }) invalidPath()
        return result
    }

    private fun isWholeTemplate(raw: String): Boolean =
        raw.startsWith("{{") &&
            raw.endsWith("}}") &&
            !raw.drop(2).dropLast(2).contains("{{") &&
            !raw.drop(2).dropLast(2).contains("}}")

    private fun unquoteIfNeeded(raw: String): String {
        if (raw.length < 2 || raw.first() != raw.last() ||
            raw.first() !in setOf('"', '\'')
        ) {
            return raw
        }
        return raw.substring(1, raw.length - 1)
    }

    private fun invalidArguments(): Nothing = invalid(
        RequestExpressionValidator.ErrorKind.INVALID_FUNCTION_ARGUMENTS,
        "invalid arguments",
    )

    private fun invalidPath(): Nothing = invalid(
        RequestExpressionValidator.ErrorKind.INVALID_PATH,
        "invalid path",
    )

    private fun typeMismatch(message: String): Nothing = invalid(
        RequestExpressionValidator.ErrorKind.INVALID_FUNCTION_ARGUMENTS,
        message,
    )

    private fun Boolean?.orTypeMismatch(message: String): Boolean =
        this ?: typeMismatch(message)

    private fun invalid(
        kind: RequestExpressionValidator.ErrorKind,
        message: String,
    ): Nothing = throw ExpressionException(kind, message)
}

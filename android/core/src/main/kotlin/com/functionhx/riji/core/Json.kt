package com.functionhx.riji.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * 与同步协议对应的 JSON 值。规范化编码（[canonical]）与参考实现（spec/reference/riji.mjs）逐字节一致：
 * 对象键按 UTF-16 码元排序、无空白；字符串按 ECMAScript `JSON.stringify` 转义；数字按 ECMAScript 最短表示。
 */
sealed interface JsonValue {
    data object Null : JsonValue
    data class Bool(val value: Boolean) : JsonValue
    data class Num(val value: Double) : JsonValue
    data class Str(val value: String) : JsonValue
    data class Arr(val items: List<JsonValue>) : JsonValue
    data class Obj(val fields: Map<String, JsonValue>) : JsonValue

    operator fun get(key: String): JsonValue? = (this as? Obj)?.fields?.get(key)
    val string: String? get() = (this as? Str)?.value
    val bool: Boolean? get() = (this as? Bool)?.value
    val number: Double? get() = (this as? Num)?.value
    val int: Int? get() = number?.let { if (it == Math.rint(it)) it.toInt() else null }
    val long: Long? get() = number?.let { if (it == Math.rint(it)) it.toLong() else null }
    val array: List<JsonValue>? get() = (this as? Arr)?.items
    val obj: Map<String, JsonValue>? get() = (this as? Obj)?.fields

    fun canonical(): String = StringBuilder().also { write(it) }.toString()
    fun canonicalBytes(): ByteArray = canonical().toByteArray(Charsets.UTF_8)

    private fun write(out: StringBuilder) {
        when (this) {
            Null -> out.append("null")
            is Bool -> out.append(if (value) "true" else "false")
            is Num -> out.append(ecmaNumber(value))
            is Str -> writeString(value, out)
            is Arr -> {
                out.append('[')
                items.forEachIndexed { i, item -> if (i > 0) out.append(','); item.write(out) }
                out.append(']')
            }
            is Obj -> {
                out.append('{')
                // String 的 compareTo 就是按 UTF-16 码元比较，与 ECMAScript 的默认排序一致。
                fields.keys.sorted().forEachIndexed { i, key ->
                    if (i > 0) out.append(',')
                    writeString(key, out)
                    out.append(':')
                    fields.getValue(key).write(out)
                }
                out.append('}')
            }
        }
    }

    companion object {
        fun parse(text: String): JsonValue = from(Json.parseToJsonElement(text))
        fun parse(bytes: ByteArray): JsonValue = parse(bytes.toString(Charsets.UTF_8))

        fun obj(vararg pairs: Pair<String, JsonValue>): Obj = Obj(linkedMapOf(*pairs))
        fun str(value: String) = Str(value)
        fun num(value: Number) = Num(value.toDouble())

        private fun from(element: JsonElement): JsonValue = when (element) {
            is JsonNull -> Null
            is JsonPrimitive -> when {
                element.isString -> Str(element.content)
                element.content == "true" -> Bool(true)
                element.content == "false" -> Bool(false)
                else -> Num(element.content.toDouble())
            }
            is JsonArray -> Arr(element.map(::from))
            is JsonObject -> Obj(element.mapValues { from(it.value) })
        }

        internal fun writeString(value: String, out: StringBuilder) {
            out.append('"')
            for (ch in value) {
                when (ch) {
                    '"' -> out.append("\\\"")
                    '\\' -> out.append("\\\\")
                    '\b' -> out.append("\\b")
                    '\u000C' -> out.append("\\f")
                    '\n' -> out.append("\\n")
                    '\r' -> out.append("\\r")
                    '\t' -> out.append("\\t")
                    else -> if (ch < ' ') out.append(String.format("\\u%04x", ch.code)) else out.append(ch)
                }
            }
            out.append('"')
        }

        /** ECMAScript Number::toString 的子集：整数（|x| < 1e21）按十进制；其余用最短往返表示。 */
        internal fun ecmaNumber(value: Double): String {
            require(value.isFinite()) { "non-finite number" }
            if (value == 0.0) return "0"
            if (value == Math.rint(value) && Math.abs(value) < 1e21) return String.format("%.0f", value)
            val text = value.toString() // Kotlin: 0.5、1.0E-7、1.5E22
            if (!text.contains('E')) return text
            val mantissa = text.substringBefore('E').removeSuffix(".0")
            val exponent = text.substringAfter('E').toInt()
            return mantissa + "e" + (if (exponent >= 0) "+" else "-") + Math.abs(exponent)
        }
    }
}

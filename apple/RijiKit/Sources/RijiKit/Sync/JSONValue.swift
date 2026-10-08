import Foundation

/// 与同步协议对应的 JSON 值。日志段明文、记录内容都用它表示，
/// 这样规范化编码（`canonicalJSON`）与参考实现逐字节一致，不受 `JSONEncoder` 的键序与转义差异影响。
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case let .object(fields) = self { return fields[key] }
        return nil
    }

    public var string: String? { if case let .string(value) = self { return value } else { return nil } }
    public var bool: Bool? { if case let .bool(value) = self { return value } else { return nil } }
    public var number: Double? { if case let .number(value) = self { return value } else { return nil } }
    public var int: Int? { number.flatMap { $0.rounded() == $0 ? Int($0) : nil } }
    public var array: [JSONValue]? { if case let .array(value) = self { return value } else { return nil } }
    public var object: [String: JSONValue]? { if case let .object(value) = self { return value } else { return nil } }
}

public enum JSONValueError: Error, Equatable {
    case invalidJSON
    case nonFiniteNumber
    case unsupported
}

extension JSONValue {
    /// 从 UTF-8 JSON 解析。数字一律为 Double（协议里只用整数与简单小数）。
    public init(jsonData data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw JSONValueError.invalidJSON
        }
        self = try JSONValue(foundation: object)
    }

    init(foundation value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(try array.map { try JSONValue(foundation: $0) })
        case let dictionary as [String: Any]:
            self = .object(try dictionary.mapValues { try JSONValue(foundation: $0) })
        default:
            throw JSONValueError.unsupported
        }
    }

    /// 规范 JSON：对象键按 UTF-16 码元排序、无空白；字符串按 ECMAScript `JSON.stringify` 规则转义
    /// （`"`、`\`、控制字符；非 ASCII 原样输出）；数字按 ECMAScript 的最短表示。
    public func canonicalJSON() throws -> String {
        var out = ""
        try write(into: &out)
        return out
    }

    public func canonicalData() throws -> Data {
        Data(try canonicalJSON().utf8)
    }

    private func write(into out: inout String) throws {
        switch self {
        case .null:
            out += "null"
        case let .bool(value):
            out += value ? "true" : "false"
        case let .number(value):
            out += try JSONValue.ecmaNumber(value)
        case let .string(value):
            JSONValue.writeString(value, into: &out)
        case let .array(values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                try value.write(into: &out)
            }
            out += "]"
        case let .object(fields):
            out += "{"
            let keys = fields.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                JSONValue.writeString(key, into: &out)
                out += ":"
                try fields[key]!.write(into: &out)
            }
            out += "}"
        }
    }

    static func writeString(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// ECMAScript Number::toString 的子集：整数（|x| < 1e21）按十进制；其余用最短往返表示。
    static func ecmaNumber(_ value: Double) throws -> String {
        guard value.isFinite else { throw JSONValueError.nonFiniteNumber }
        if value == 0 { return "0" }
        if value.rounded() == value, abs(value) < 1e21 {
            return String(format: "%.0f", value)
        }
        var text = "\(value)"  // Swift 的 description 是最短往返表示
        if text.contains("e") {
            // Swift: 1e-07 / 1.5e+22 → ECMAScript: 1e-7 / 1.5e+22
            text = text.replacingOccurrences(of: "e-0", with: "e-").replacingOccurrences(of: "e+0", with: "e+")
            if !text.contains("e-"), !text.contains("e+") { text = text.replacingOccurrences(of: "e", with: "e+") }
        }
        return text
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

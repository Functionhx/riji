import Foundation

// 跨平台块格式 v1（docs/DESIGN.md §6）。每种实体是一种记录类型，记录值是 JSON 对象，
// 存储与同步都只认 JSONValue；这里的 struct 只是便于界面使用的视图。

public enum RecordType {
    public static let note = "note"
    public static let day = "day"
    public static let block = "block"
    public static let progress = "progress"
    public static let settings = "settings"
}

/// 富文本：`[{ text, marks? }]`。v1 界面先用纯文本编辑，marks 原样保留。
public struct RichText: Hashable, Sendable {
    public var runs: [JSONValue]

    public init(_ plain: String) { runs = plain.isEmpty ? [] : [["text": .string(plain)]] }
    public init(runs: [JSONValue]) { self.runs = runs }

    public var plain: String { runs.compactMap { $0["text"]?.string }.joined() }
    public var json: JSONValue { .array(runs) }
}

public struct Note: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case day, note }
    public var id: String
    public var kind: Kind
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    public var json: JSONValue {
        ["id": .string(id), "kind": .string(kind.rawValue), "title": .string(title),
         "created_at": .string(ISO8601.format(createdAt)), "updated_at": .string(ISO8601.format(updatedAt))]
    }

    public init(id: String, kind: Kind, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id; self.kind = kind; self.title = title; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.string, let kind = json["kind"]?.string.flatMap(Kind.init(rawValue:)) else { return nil }
        self.init(id: id, kind: kind, title: json["title"]?.string ?? "",
                  createdAt: ISO8601.parse(json["created_at"]?.string) ?? .distantPast,
                  updatedAt: ISO8601.parse(json["updated_at"]?.string) ?? .distantPast)
    }
}

/// 某一天。记录 id 就是日期字符串（`2026-10-08`），按发布时区计算。
public struct Day: Hashable, Sendable, Identifiable {
    public var date: String
    public var timeZone: String
    public var noteID: String
    public var summary: String
    public var id: String { date }

    public var json: JSONValue {
        ["date": .string(date), "tz": .string(timeZone), "note_id": .string(noteID), "summary": .string(summary)]
    }

    public init(date: String, timeZone: String, noteID: String, summary: String = "") {
        self.date = date; self.timeZone = timeZone; self.noteID = noteID; self.summary = summary
    }

    public init?(json: JSONValue) {
        guard let date = json["date"]?.string, let noteID = json["note_id"]?.string else { return nil }
        self.init(date: date, timeZone: json["tz"]?.string ?? DayClock.defaultTimeZone, noteID: noteID, summary: json["summary"]?.string ?? "")
    }
}

public struct Block: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case section, paragraph, list, check, spark, divider, image }
    public enum SectionRole: String, Sendable, CaseIterable { case todo, spark, notes, tomorrow }

    public var id: String
    public var noteID: String
    public var parentID: String?
    public var order: String
    public var kind: Kind
    public var attrs: [String: JSONValue]
    public var text: RichText
    public var createdAt: Date

    public init(id: String, noteID: String, parentID: String?, order: String, kind: Kind,
                attrs: [String: JSONValue] = [:], text: RichText = RichText(""), createdAt: Date) {
        self.id = id; self.noteID = noteID; self.parentID = parentID; self.order = order
        self.kind = kind; self.attrs = attrs; self.text = text; self.createdAt = createdAt
    }

    public var json: JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id), "note_id": .string(noteID), "order": .string(order), "type": .string(kind.rawValue),
            "attrs": .object(attrs), "text": text.json, "created_at": .string(ISO8601.format(createdAt)),
        ]
        if let parentID { fields["parent_id"] = .string(parentID) }
        return .object(fields)
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.string, let noteID = json["note_id"]?.string,
              let kind = json["type"]?.string.flatMap(Kind.init(rawValue:)) else { return nil }
        self.init(id: id, noteID: noteID, parentID: json["parent_id"]?.string, order: json["order"]?.string ?? "a0",
                  kind: kind, attrs: json["attrs"]?.object ?? [:], text: RichText(runs: json["text"]?.array ?? []),
                  createdAt: ISO8601.parse(json["created_at"]?.string) ?? .distantPast)
    }

    // 便利访问
    public var checked: Bool { attrs["checked"]?.bool ?? false }
    public var role: SectionRole? { attrs["role"]?.string.flatMap(SectionRole.init(rawValue:)) }
    public var carryFrom: String? { attrs["carry_from"]?.string }
    public var carriedTo: String? { attrs["carried_to"]?.string }
    public var carriedDays: Int { attrs["carried_days"]?.int ?? 0 }
    /// 被延续过来的任务删掉后，原块记为「放下了」，不再被带走。
    public var dropped: Bool { attrs["dropped"]?.bool ?? false }
    /// 这件事没做完时要不要带到明天：true / false 是单独选的，nil 跟随总开关（DailyBook.carryByDefault）。
    public var carry: Bool? { attrs["carry"]?.bool }
    /// 明日目标 → 次日今日目标：目标块记 `planned_to`，次日的任务记 `planned_from`。
    public var plannedTo: String? { attrs["planned_to"]?.string }
    public var plannedFrom: String? { attrs["planned_from"]?.string }
    public var progressID: String? { attrs["progress_id"]?.string }
    public var color: String { attrs["color"]?.string ?? "yellow" }
    public var indent: Int { attrs["indent"]?.int ?? 0 }
}

/// 长期进度（`电路 18 讲` → 电路，18，讲）。
public struct ProgressItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var unit: String
    public var current: Int
    public var target: Int?
    public var isPublic: Bool
    public var updatedDay: String?
    public var archived: Bool

    public init(id: String, name: String, unit: String, current: Int, target: Int? = nil, isPublic: Bool = false,
                updatedDay: String? = nil, archived: Bool = false) {
        self.id = id; self.name = name; self.unit = unit; self.current = current; self.target = target
        self.isPublic = isPublic; self.updatedDay = updatedDay; self.archived = archived
    }

    public var json: JSONValue {
        var fields: [String: JSONValue] = ["id": .string(id), "name": .string(name), "unit": .string(unit),
                                           "current": .number(Double(current)), "public": .bool(isPublic), "archived": .bool(archived)]
        if let target { fields["target"] = .number(Double(target)) }
        if let updatedDay { fields["updated_day"] = .string(updatedDay) }
        return .object(fields)
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.string, let name = json["name"]?.string else { return nil }
        self.init(id: id, name: name, unit: json["unit"]?.string ?? "", current: json["current"]?.int ?? 0,
                  target: json["target"]?.int, isPublic: json["public"]?.bool ?? false,
                  updatedDay: json["updated_day"]?.string, archived: json["archived"]?.bool ?? false)
    }

    public var fraction: Double? {
        guard let target, target > 0 else { return nil }
        return min(1, Double(current) / Double(target))
    }
}

public enum ISO8601 {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let lock = NSLock()

    public static func format(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(from: date)
    }

    public static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        lock.lock(); defer { lock.unlock() }
        return formatter.date(from: text)
    }
}

/// 记录 id：时间有序（UUIDv7 风格）、小写、只含 [0-9a-f-]。
public enum RecordID {
    public static func make(now: Date = Date()) -> String {
        let ms = UInt64(now.timeIntervalSince1970 * 1000)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * (5 - UInt64(i)))) & 0xFF) }
        for i in 6..<16 { bytes[i] = UInt8.random(in: 0...255) }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let chars = Array(hex)
        return "\(String(chars[0..<8]))-\(String(chars[8..<12]))-\(String(chars[12..<16]))-\(String(chars[16..<20]))-\(String(chars[20..<32]))"
    }
}

/// 分数索引：在两个顺序键之间生成一个新键（base-36 小写，字典序即顺序）。
public enum OrderKey {
    static let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    public static func between(_ a: String?, _ b: String?) -> String {
        let low = a ?? ""
        let high = b ?? ""
        var result = ""
        var i = 0
        while true {
            let lowDigit = i < low.count ? index(of: Array(low)[i]) : 0
            let highDigit = i < high.count ? index(of: Array(high)[i]) : digits.count
            if highDigit - lowDigit > 1 {
                result.append(digits[(lowDigit + highDigit) / 2])
                return result
            }
            result.append(digits[lowDigit])
            i += 1
            if i > 64 { return result + "i" }
        }
    }

    public static func after(_ a: String?) -> String { between(a, nil) }

    private static func index(of character: Character) -> Int { digits.firstIndex(of: character) ?? 0 }
}

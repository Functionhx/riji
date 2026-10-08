import Foundation

/// 按发布时区（默认北京时间，与网站一致）计算「今天」。
public struct DayClock: Sendable {
    public static let defaultTimeZone = "Asia/Shanghai"
    public var timeZone: TimeZone

    public init(timeZoneID: String = DayClock.defaultTimeZone) {
        timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 8 * 3600)!
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public func key(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public func date(for key: String) -> Date? {
        let numbers = key.split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: numbers[0], month: numbers[1], day: numbers[2]))
    }

    public func daysBetween(_ from: String, _ to: String) -> Int {
        guard let a = date(for: from), let b = date(for: to) else { return 0 }
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    public func adding(days: Int, to key: String) -> String {
        guard let date = date(for: key), let next = calendar.date(byAdding: .day, value: days, to: date) else { return key }
        return self.key(for: next)
    }

    /// 「10 月 8 日」
    public func title(for key: String) -> String {
        let numbers = key.split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3 else { return key }
        return "\(numbers[1]) 月 \(numbers[2]) 日"
    }

    /// 「星期四」
    public func weekday(for key: String) -> String {
        guard let date = date(for: key) else { return "" }
        let names = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        return names[calendar.component(.weekday, from: date) - 1]
    }

    /// 今天 06:00–24:00 过去了多少（墨线用），0…1。
    public func dayProgress(at now: Date) -> Double {
        let start = calendar.startOfDay(for: now).addingTimeInterval(6 * 3600)
        return min(1, max(0, now.timeIntervalSince(start) / (18 * 3600)))
    }

    /// 距离今天结束还有多少分钟。
    public func minutesLeft(at now: Date) -> Int {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return max(0, Int(end.timeIntervalSince(now) / 60))
    }
}

/// 识别「电路 18 讲」「马原 第 6 章」「英语单词 26 天」这类长期进度。
public enum ProgressParser {
    public struct Match: Equatable, Sendable {
        public var name: String
        public var value: Int
        public var unit: String
    }

    static let units = ["讲", "章", "节", "课", "集", "页", "题", "篇", "天", "周", "次", "单元", "小时", "关"]

    public static func parse(_ text: String) -> Match? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let unitPattern = units.joined(separator: "|")
        // 名字必须以非数字结尾，否则「18 讲」会被拆成「1」和 8。
        let pattern = "^(.*?\\D)\\s*第?\\s*(\\d{1,5})\\s*(\(unitPattern))$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let nameRange = Range(match.range(at: 1), in: trimmed),
              let valueRange = Range(match.range(at: 2), in: trimmed),
              let unitRange = Range(match.range(at: 3), in: trimmed),
              let value = Int(trimmed[valueRange])
        else { return nil }
        let name = trimmed[nameRange].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 24 else { return nil }
        return Match(name: name, value: value, unit: String(trimmed[unitRange]))
    }
}

/// 一天的统计（晚间总结、热力图、网站公开卡用的就是这些数字）。
public struct DayStats: Equatable, Sendable {
    public var total: Int
    public var done: Int
    public var carried: Int
    public var sparks: Int
    public var hasContent: Bool
}

/// 每日层的全部规则。所有写入都经过 RecordStore（一次用户动作 = 一批变更）。
public final class DailyBook: @unchecked Sendable {
    public let store: RecordStore
    public var clock: DayClock

    public init(store: RecordStore, clock: DayClock = DayClock()) {
        self.store = store
        self.clock = clock
    }

    // ---------------------------------------------------------------- 缓存
    //
    // 解析后的记录按 store.revision 缓存：任何写入后失效，下次读取时整体重建一次（O(记录数)）。
    // 不缓存的话，每次读取都要解析全部 JSON，几百条记录就会慢到秒级。

    private let cacheLock = NSLock()
    private var cachedRevision = -1
    private var cachedDays: [Day] = []
    private var cachedDayByDate: [String: Day] = [:]
    private var cachedBlocksByNote: [String: [Block]] = [:]
    private var cachedBlockByID: [String: Block] = [:]
    private var cachedProgresses: [ProgressItem] = []

    private func withCache<T>(_ read: () -> T) -> T {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if cachedRevision != store.revision {
            cachedDays = store.values(RecordType.day).compactMap(Day.init(json:)).sorted { $0.date > $1.date }
            cachedDayByDate = Dictionary(cachedDays.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
            let blocks = store.values(RecordType.block).compactMap(Block.init(json:))
            cachedBlockByID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            cachedBlocksByNote = Dictionary(grouping: blocks, by: \.noteID)
            cachedProgresses = store.values(RecordType.progress).compactMap(ProgressItem.init(json:))
            cachedRevision = store.revision
        }
        return read()
    }

    /// 本类自己的写入：缓存是新的，就把这批变更增量合进去，不必整体重建。
    @discardableResult
    private func commit(_ edits: [(type: String, id: String, value: JSONValue?)]) throws -> [Change] {
        cacheLock.lock()
        let wasFresh = cachedRevision == store.revision
        cacheLock.unlock()
        let changes = try store.write(edits)
        guard wasFresh else { return changes }
        cacheLock.lock(); defer { cacheLock.unlock() }
        var daysChanged = false
        for change in changes {
            switch change.type {
            case RecordType.day:
                cachedDayByDate[change.id] = change.deleted ? nil : change.value.flatMap(Day.init(json:))
                daysChanged = true
            case RecordType.block:
                if let old = cachedBlockByID[change.id] {
                    cachedBlocksByNote[old.noteID]?.removeAll { $0.id == change.id }
                }
                if !change.deleted, let block = change.value.flatMap(Block.init(json:)) {
                    cachedBlockByID[change.id] = block
                    cachedBlocksByNote[block.noteID, default: []].append(block)
                } else {
                    cachedBlockByID[change.id] = nil
                }
            case RecordType.progress:
                cachedProgresses.removeAll { $0.id == change.id }
                if !change.deleted, let progress = change.value.flatMap(ProgressItem.init(json:)) { cachedProgresses.append(progress) }
            default:
                break
            }
        }
        if daysChanged { cachedDays = cachedDayByDate.values.sorted { $0.date > $1.date } }
        cachedRevision = store.revision
        return changes
    }

    // ---------------------------------------------------------------- 读取

    public var days: [Day] { withCache { cachedDays } }

    public func day(_ date: String) -> Day? { withCache { cachedDayByDate[date] } }

    public func blocks(note noteID: String) -> [Block] { withCache { cachedBlocksByNote[noteID] ?? [] } }

    public func block(_ id: String) -> Block? { withCache { cachedBlockByID[id] } }

    public func section(_ role: Block.SectionRole, of day: Day) -> Block? {
        blocks(note: day.noteID).first { $0.kind == .section && $0.role == role }
    }

    public func children(of section: Block) -> [Block] {
        blocks(note: section.noteID).filter { $0.parentID == section.id }.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    public func items(_ role: Block.SectionRole, on date: String) -> [Block] {
        guard let day = day(date), let section = section(role, of: day) else { return [] }
        return children(of: section)
    }

    public var progresses: [ProgressItem] {
        withCache { cachedProgresses }.filter { !$0.archived }
            .sorted { ($0.updatedDay ?? "", $0.name) > ($1.updatedDay ?? "", $1.name) }
    }

    public func progress(_ id: String) -> ProgressItem? { withCache { cachedProgresses.first { $0.id == id } } }

    public func stats(on date: String) -> DayStats {
        let written = items(.todo, on: date)
        // 没做完、已被带到后面某天的任务不算在这一天的总数里（它在新的那天继续算）；但这一天仍然「写过东西」。
        let todos = written.filter { $0.carriedTo == nil || $0.checked }
        let sparks = items(.spark, on: date)
        let notes = items(.notes, on: date)
        return DayStats(
            total: todos.count, done: todos.filter(\.checked).count, carried: todos.filter { $0.carryFrom != nil }.count,
            sparks: sparks.count,
            hasContent: !written.isEmpty || !sparks.isEmpty || notes.contains { !$0.text.plain.isEmpty })
    }

    /// 热力图：日期 → 等级 0…4（按当天完成数）。
    public func heatmap() -> [String: Int] {
        var levels: [String: Int] = [:]
        for day in days {
            let stats = stats(on: day.date)
            guard stats.hasContent else { continue }
            levels[day.date] = stats.done == 0 ? 1 : stats.done <= 2 ? 2 : stats.done <= 4 ? 3 : 4
        }
        return levels
    }

    /// 连续记录天数：从今天（今天还没写就从昨天）往回数，有内容的日子连续多少天。
    public func streak(today: String) -> Int {
        let active = Set(heatmap().keys)
        var cursor = active.contains(today) ? today : clock.adding(days: -1, to: today)
        var count = 0
        while active.contains(cursor) {
            count += 1
            cursor = clock.adding(days: -1, to: cursor)
        }
        return count
    }

    // ---------------------------------------------------------------- 今天页

    /// 确保某天的页面存在（新的一天自动生成），并把之前没做完的 TODO 带过来。
    @discardableResult
    public func ensureDay(_ date: String, now: Date = Date()) throws -> Day {
        if let existing = day(date) {
            try carryOver(into: existing, now: now)
            return existing
        }
        let noteID = RecordID.make(now: now)
        let note = Note(id: noteID, kind: .day, title: clock.title(for: date), createdAt: now, updatedAt: now)
        let day = Day(date: date, timeZone: clock.timeZone.identifier, noteID: noteID)
        var edits: [(type: String, id: String, value: JSONValue?)] = [
            (RecordType.note, noteID, note.json), (RecordType.day, date, day.json),
        ]
        var order: String? = nil
        for (role, title) in [(Block.SectionRole.todo, "TODO"), (.spark, "SPARK"), (.notes, "随记")] {
            order = OrderKey.after(order)
            let section = Block(id: RecordID.make(now: now), noteID: noteID, parentID: nil, order: order!, kind: .section,
                                attrs: ["role": .string(role.rawValue), "title": .string(title)], createdAt: now)
            edits.append((RecordType.block, section.id, section.json))
        }
        try commit(edits)
        try carryOver(into: day, now: now)
        return day
    }

    /// 从最近的前一天，把没勾、也还没被带走的 TODO 带到这一天顶部。原块记下「已延续到」，历史不改写。
    public func carryOver(into day: Day, now: Date = Date()) throws {
        guard let previous = days.first(where: { $0.date < day.date }),
              let target = section(.todo, of: day), let source = section(.todo, of: previous) else { return }
        let pending = children(of: source).filter { $0.kind == .check && !$0.checked && $0.carriedTo == nil }
        guard !pending.isEmpty else { return }
        let gap = max(1, clock.daysBetween(previous.date, day.date))
        let existing = children(of: target)
        var order = existing.first.map { OrderKey.between(nil, $0.order) } ?? "a"
        var edits: [(type: String, id: String, value: JSONValue?)] = []
        var lastOrder: String? = nil
        for original in pending {
            order = lastOrder.map { OrderKey.between($0, existing.first?.order) } ?? order
            lastOrder = order
            var attrs = original.attrs
            attrs["carry_from"] = .string(original.id)
            attrs["carried_days"] = .number(Double(original.carriedDays + gap))
            attrs["carried_to"] = nil
            let copy = Block(id: RecordID.make(now: now), noteID: day.noteID, parentID: target.id, order: order,
                             kind: .check, attrs: attrs, text: original.text, createdAt: now)
            var updated = original
            updated.attrs["carried_to"] = .string(copy.id)
            edits.append((RecordType.block, copy.id, copy.json))
            edits.append((RecordType.block, updated.id, updated.json))
        }
        try commit(edits)
    }

    // ---------------------------------------------------------------- 编辑

    @discardableResult
    public func add(_ kind: Block.Kind, text: String, to role: Block.SectionRole, on date: String,
                    after: String? = nil, attrs: [String: JSONValue] = [:], now: Date = Date()) throws -> Block? {
        let day = try ensureDay(date, now: now)
        guard let section = section(role, of: day) else { return nil }
        let siblings = children(of: section)
        let order: String
        if let after, let index = siblings.firstIndex(where: { $0.id == after }) {
            order = OrderKey.between(siblings[index].order, index + 1 < siblings.count ? siblings[index + 1].order : nil)
        } else {
            order = OrderKey.after(siblings.last?.order)
        }
        var attrs = attrs
        if kind == .check { attrs["checked"] = attrs["checked"] ?? false }
        if kind == .spark { attrs["color"] = attrs["color"] ?? .string(nextSparkColor(on: date)) }
        var edits: [(type: String, id: String, value: JSONValue?)] = []
        if kind == .check, let match = ProgressParser.parse(text) {
            let progress = progressFor(match, date: date)
            attrs["progress_id"] = .string(progress.id)
            edits.append((RecordType.progress, progress.id, progress.json))
        }
        let block = Block(id: RecordID.make(now: now), noteID: day.noteID, parentID: section.id, order: order,
                          kind: kind, attrs: attrs, text: RichText(text), createdAt: now)
        edits.append((RecordType.block, block.id, block.json))
        try commit(edits)
        return block
    }

    public func setText(_ text: String, of blockID: String) throws {
        guard var block = block(blockID), block.text.plain != text else { return }
        block.text = RichText(text)
        var edits: [(type: String, id: String, value: JSONValue?)] = []
        if block.kind == .check {
            if let match = ProgressParser.parse(text) {
                let date = dayDate(of: block) ?? clock.key(for: Date())
                let progress = progressFor(match, date: date)
                block.attrs["progress_id"] = .string(progress.id)
                edits.append((RecordType.progress, progress.id, progress.json))
            } else {
                block.attrs["progress_id"] = nil
            }
        }
        edits.append((RecordType.block, block.id, block.json))
        try commit(edits)
    }

    public func setChecked(_ checked: Bool, of blockID: String) throws {
        guard var block = block(blockID), block.checked != checked else { return }
        block.attrs["checked"] = .bool(checked)
        var edits: [(type: String, id: String, value: JSONValue?)] = [(RecordType.block, block.id, block.json)]
        // 勾选带进度的任务：进度推进到任务里写的数（只进不退）。
        if checked, let progressID = block.progressID, var progress = progress(progressID),
           let match = ProgressParser.parse(block.text.plain), match.value > progress.current {
            progress.current = match.value
            progress.updatedDay = dayDate(of: block)
            edits.append((RecordType.progress, progress.id, progress.json))
        }
        try commit(edits)
    }

    public func setAttr(_ key: String, _ value: JSONValue?, of blockID: String) throws {
        guard var block = block(blockID) else { return }
        block.attrs[key] = value
        try commit([(RecordType.block, block.id, block.json)])
    }

    public func delete(_ blockID: String) throws {
        guard let block = block(blockID) else { return }
        var edits: [(type: String, id: String, value: JSONValue?)] = [(RecordType.block, blockID, nil)]
        // 删掉一个被带过来的任务：原来那天的记录恢复成「未延续」，免得它悬空。
        if let from = block.carryFrom, var original = self.block(from),
           original.carriedTo == blockID {
            original.attrs["carried_to"] = nil
            edits.append((RecordType.block, original.id, original.json))
        }
        try commit(edits)
    }

    /// Spark → 今天的 TODO。便利贴保留，标上「已升级」。
    @discardableResult
    public func promote(spark sparkID: String, on date: String, now: Date = Date()) throws -> Block? {
        guard let spark = block(sparkID), spark.kind == .spark else { return nil }
        let task = try add(.check, text: spark.text.plain, to: .todo, on: date, attrs: ["from_spark": .string(spark.id)], now: now)
        if let task { try setAttr("promoted_to", .string(task.id), of: spark.id) }
        return task
    }

    public func setNotes(_ text: String, on date: String, now: Date = Date()) throws {
        let day = try ensureDay(date, now: now)
        guard let section = section(.notes, of: day) else { return }
        if let paragraph = children(of: section).first(where: { $0.kind == .paragraph }) {
            try setText(text, of: paragraph.id)
        } else if !text.isEmpty {
            try add(.paragraph, text: text, to: .notes, on: date, now: now)
        }
    }

    public func notes(on date: String) -> String {
        items(.notes, on: date).first { $0.kind == .paragraph }?.text.plain ?? ""
    }

    public func setSummary(_ summary: String, on date: String) throws {
        guard var day = day(date) else { return }
        day.summary = summary
        try commit([(RecordType.day, date, day.json)])
    }

    public func updateProgress(_ progress: ProgressItem) throws {
        try commit([(RecordType.progress, progress.id, progress.json)])
    }

    // ---------------------------------------------------------------- 内部

    private func dayDate(of block: Block) -> String? { days.first { $0.noteID == block.noteID }?.date }

    private func progressFor(_ match: ProgressParser.Match, date: String) -> ProgressItem {
        if let existing = progresses.first(where: { $0.name == match.name }) {
            var progress = existing
            if progress.unit.isEmpty { progress.unit = match.unit }
            return progress
        }
        return ProgressItem(id: RecordID.make(), name: match.name, unit: match.unit, current: max(0, match.value - 1), updatedDay: date)
    }

    private func nextSparkColor(on date: String) -> String {
        let palette = ["yellow", "pink", "mint", "blue"]
        return palette[items(.spark, on: date).count % palette.count]
    }
}

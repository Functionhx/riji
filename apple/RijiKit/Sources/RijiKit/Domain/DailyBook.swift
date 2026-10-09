import Foundation

/// 按发布时区（默认北京时间，与网站一致）计算「今天」。
///
/// 一天在 `dayStart`（从零点起的分钟数）结束，而不是零点：分界线是凌晨 4 点时，02:30 写的总结仍算前一天。
/// 日期键仍是那一天的日历日期，跨天（延续、明日目标）也在分界线上发生。
public struct DayClock: Sendable {
    public static let defaultTimeZone = "Asia/Shanghai"
    /// 应用里的默认分界线（凌晨 4 点）。内核默认是零点，测试与旧行为不变。
    public static let suggestedDayStart = 4 * 60
    public var timeZone: TimeZone
    /// 一天的分界线：零点之后多少分钟（0…359）。
    public var dayStart: Int

    public init(timeZoneID: String = DayClock.defaultTimeZone, dayStart: Int = 0) {
        timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 8 * 3600)!
        self.dayStart = min(max(dayStart, 0), 359)
    }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public func key(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date.addingTimeInterval(-Double(dayStart * 60)))
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

    /// 某一天里「几点几分」对应的时刻；早于分界线的时刻属于这一天的深夜（日历上的第二天）。
    public func instant(minutes: Int, on key: String) -> Date? {
        guard let midnight = date(for: key) else { return nil }
        return midnight.addingTimeInterval(Double((minutes < dayStart ? minutes + 1440 : minutes) * 60))
    }

    // 显示上仍按零点：墨线画 06:00–24:00，「今天还剩」倒数到零点。分界线只决定内容记在哪一天。

    /// 某个时刻在墨线（06:00–24:00）上的位置，0…1；零点后的时刻停在终点。
    public func inkPosition(minutes: Int) -> Double {
        let offset = (minutes < dayStart ? minutes + 1440 : minutes) - 360
        return min(1, max(0, Double(offset) / 1080))
    }

    /// 今天 06:00–24:00 过去了多少（墨线用），0…1。
    public func dayProgress(at now: Date) -> Double {
        guard let start = instant(minutes: 360, on: key(for: now)) else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / (18 * 3600)))
    }

    /// 距离今天的零点还有多少分钟；零点后（分界线之前）是 0。
    public func minutesLeft(at now: Date) -> Int {
        guard let midnight = date(for: key(for: now)) else { return 0 }
        return max(0, Int(midnight.addingTimeInterval(86400).timeIntervalSince(now) / 60))
    }

    /// 已经过了零点、还没到分界线（仍算前一天的深夜）。
    public func isPastMidnight(at now: Date) -> Bool {
        guard let midnight = date(for: key(for: now)) else { return false }
        return now >= midnight.addingTimeInterval(86400)
    }

    /// 「04:00」
    public static func label(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
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
    /// 没做完的事默认是否带到明天（每件事可以单独选，见 Block.carry）。内核默认带，应用里由设置决定。
    public var carryByDefault = true

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
        // 没做完、已被带到后面某天（或放下了）的任务不算在这一天的总数里；但这一天仍然「写过东西」。
        let todos = written.filter { ($0.carriedTo == nil && !$0.dropped) || $0.checked }
        let sparks = items(.spark, on: date)
        let notes = items(.notes, on: date)
        let wroteEvening = !(day(date)?.summary.isEmpty ?? true) || !items(.tomorrow, on: date).isEmpty
        return DayStats(
            total: todos.count, done: todos.filter(\.checked).count, carried: todos.filter { $0.carryFrom != nil }.count,
            sparks: sparks.count,
            hasContent: !written.isEmpty || !sparks.isEmpty || notes.contains { !$0.text.plain.isEmpty } || wroteEvening)
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

    // ---------------------------------------------------------------- 延续的选择

    /// 这件事没做完时会不会带到明天。
    public func willCarry(_ block: Block) -> Bool { block.carry ?? carryByDefault }

    /// 单独选：带 / 不带（写成明确的 true / false，不再跟随总开关）。
    public func setCarry(_ carry: Bool, of blockID: String) throws {
        try setAttr("carry", .bool(carry), of: blockID)
    }

    // ---------------------------------------------------------------- 晚间

    /// 一天收尾的情况：今日总结写了没有、明日目标定了几条、还有几件没做完（会自动延续）。
    public func evening(on date: String) -> Evening {
        let plans = items(.tomorrow, on: date).filter { !Self.normalized($0.text.plain).isEmpty }
        let open = items(.todo, on: date).filter { $0.kind == .check && !$0.checked && $0.carriedTo == nil && !$0.dropped }
        let pending = open.filter(willCarry)
        return Evening(date: date, stats: stats(on: date),
                       hasSummary: !(day(date)?.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                       plans: plans.count, pending: pending.count, staying: open.count - pending.count)
    }

    /// 早上补写：昨天写过东西、却没写总结时返回昨天的日期。
    public func missedEvening(today: String) -> String? {
        let yesterday = clock.adding(days: -1, to: today)
        let evening = evening(on: yesterday)
        return day(yesterday) != nil && evening.stats.hasContent && !evening.hasSummary ? yesterday : nil
    }


    /// 确保某天的页面存在（新的一天自动生成），并把之前没做完的 TODO 带过来。
    @discardableResult
    public func ensureDay(_ date: String, now: Date = Date()) throws -> Day {
        if let existing = day(date) {
            try carryOver(into: existing, now: now)
            return existing
        }
        // 确定的 id：两台设备各自生成同一天时写的是同一组记录，同步后不会出现两页
        let noteID = Self.dayNoteID(date)
        let note = Note(id: noteID, kind: .day, title: clock.title(for: date), createdAt: now, updatedAt: now)
        let day = Day(date: date, timeZone: clock.timeZone.identifier, noteID: noteID)
        var edits: [(type: String, id: String, value: JSONValue?)] = [
            (RecordType.note, noteID, note.json), (RecordType.day, date, day.json),
        ]
        var order: String? = nil
        for (role, title) in [(Block.SectionRole.todo, "TODO"), (.spark, "SPARK"), (.notes, "随记"), (.tomorrow, "明日目标")] {
            order = OrderKey.after(order)
            let section = Block(id: "\(noteID)-\(role.rawValue)", noteID: noteID, parentID: nil, order: order!, kind: .section,
                                attrs: ["role": .string(role.rawValue), "title": .string(title)], createdAt: now)
            edits.append((RecordType.block, section.id, section.json))
        }
        try commit(edits)
        try carryOver(into: day, now: now)
        return day
    }

    /// 从最近的前一天，把两样东西带到这一天「今日目标」的顶部：先是那天定下的明日目标，再是没勾、也还没被带走的 TODO。
    /// 原块记下去向（`planned_to` / `carried_to`），历史不改写。明日目标只落到今天及以后的页面上
    /// （补写一周前的「明日目标」不会塞进早已过去的那天）；和延续过来的事、这一天已有的事重名的目标不重复添加。
    public func carryOver(into day: Day, now: Date = Date()) throws {
        guard let previous = days.first(where: { $0.date < day.date }), let target = section(.todo, of: day) else { return }
        let pending = section(.todo, of: previous).map(children(of:))?
            .filter { $0.kind == .check && !$0.checked && $0.carriedTo == nil && !$0.dropped && willCarry($0) } ?? []
        let plans = day.date < clock.key(for: now) ? [] : (section(.tomorrow, of: previous).map(children(of:)) ?? [])
            .filter { $0.kind == .check && $0.plannedTo == nil && !Self.normalized($0.text.plain).isEmpty }
        guard !pending.isEmpty || !plans.isEmpty else { return }

        let gap = max(1, clock.daysBetween(previous.date, day.date))
        let existing = children(of: target)
        // 插在顶部；这一天已经有排进来的目标（过了零点逐条补写）时，接在它们后面，保持书写顺序。
        let anchor = existing.lastIndex { $0.plannedFrom != nil && $0.carryFrom == nil }
        var lastOrder: String? = anchor.map { existing[$0].order }
        let upper = anchor.map { $0 + 1 < existing.count ? existing[$0 + 1].order : nil } ?? existing.first?.order
        func nextOrder() -> String {
            let order = lastOrder == nil && upper == nil ? "a" : OrderKey.between(lastOrder, upper)
            lastOrder = order
            return order
        }
        var edits: [(type: String, id: String, value: JSONValue?)] = []
        // 文字 → 这一天里已经有（或马上会有）的那条任务
        var landed: [String: String] = [:]
        for block in existing where landed[Self.normalized(block.text.plain)] == nil { landed[Self.normalized(block.text.plain)] = block.id }
        var carriedCopies: [(key: String, copy: Block, original: Block)] = []
        for original in pending {
            var attrs = original.attrs
            attrs["carry_from"] = .string(original.id)
            attrs["carried_days"] = .number(Double(original.carriedDays + gap))
            attrs["carried_to"] = nil
            attrs["planned_from"] = nil
            let copy = Block(id: "carry-\(original.id)-\(day.date)", noteID: day.noteID, parentID: target.id, order: "",
                             kind: .check, attrs: attrs, text: original.text, createdAt: now)
            carriedCopies.append((Self.normalized(original.text.plain), copy, original))
        }
        for copy in carriedCopies where landed[copy.key] == nil { landed[copy.key] = copy.copy.id }

        var planCopies: [Block] = []
        for plan in plans {
            let key = Self.normalized(plan.text.plain)
            var updated = plan
            if let existingID = landed[key] {
                updated.attrs["planned_to"] = .string(existingID)
            } else {
                var attrs: [String: JSONValue] = ["checked": false, "planned_from": .string(plan.id)]
                attrs["progress_id"] = plan.attrs["progress_id"]
                let copy = Block(id: "plan-\(plan.id)", noteID: day.noteID, parentID: target.id, order: nextOrder(),
                                 kind: .check, attrs: attrs, text: plan.text, createdAt: now)
                planCopies.append(copy)
                landed[key] = copy.id
                updated.attrs["planned_to"] = .string(copy.id)
            }
            edits.append((RecordType.block, updated.id, updated.json))
        }
        for copy in planCopies { edits.append((RecordType.block, copy.id, copy.json)) }
        for var item in carriedCopies {
            item.copy.order = nextOrder()
            var updated = item.original
            updated.attrs["carried_to"] = .string(item.copy.id)
            edits.append((RecordType.block, item.copy.id, item.copy.json))
            edits.append((RecordType.block, updated.id, updated.json))
        }
        try commit(edits)
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // ---------------------------------------------------------------- 编辑

    @discardableResult
    public func add(_ kind: Block.Kind, text: String, to role: Block.SectionRole, on date: String,
                    after: String? = nil, attrs: [String: JSONValue] = [:], now: Date = Date()) throws -> Block? {
        let day = try ensureDay(date, now: now)
        guard let section = try section(role, of: day) ?? createSection(role, of: day, now: now) else { return nil }
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
        // 第二天的页面已经在了（过了零点才写明日目标）：直接排进去。
        if role == .tomorrow, let next = days.last(where: { $0.date > date }) { try carryOver(into: next, now: now) }
        return block
    }

    /// 老页面没有的区块（比如「明日目标」是后来加的）在第一次写入时补上，排在最后。
    private func createSection(_ role: Block.SectionRole, of day: Day, now: Date) throws -> Block? {
        let titles: [Block.SectionRole: String] = [.todo: "TODO", .spark: "SPARK", .notes: "随记", .tomorrow: "明日目标"]
        let last = blocks(note: day.noteID).filter { $0.parentID == nil }.map(\.order).max()
        let section = Block(id: "\(day.noteID)-\(role.rawValue)", noteID: day.noteID, parentID: nil, order: OrderKey.after(last), kind: .section,
                            attrs: ["role": .string(role.rawValue), "title": .string(titles[role] ?? role.rawValue)], createdAt: now)
        try commit([(RecordType.block, section.id, section.json)])
        return section
    }

    public func setText(_ text: String, of blockID: String) throws {
        guard var block = block(blockID), block.text.plain != text else { return }
        let before = block.text.plain
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
        // 改写已排进第二天的明日目标：那边还没动过的话一起改。
        if let to = block.plannedTo, var copy = self.block(to), copy.plannedFrom == block.id, !copy.checked, copy.text.plain == before {
            copy.text = block.text
            copy.attrs["progress_id"] = block.attrs["progress_id"]
            edits.append((RecordType.block, copy.id, copy.json))
        }
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
        // 删掉一个被带过来的任务 = 不做了：原来那天的记录标成「放下了」，以后不会再被带回来。
        if let from = block.carryFrom, var original = self.block(from),
           original.carriedTo == blockID {
            original.attrs["carried_to"] = nil
            original.attrs["dropped"] = true
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

    // ---------------------------------------------------------------- 同步后的同日合并

    public static func dayNoteID(_ date: String) -> String { "day-\(date)" }

    /// 同步之前两台设备各自生成过同一天（旧版用随机 id）：合并后 Day 记录只剩一份，另一份笔记成了孤儿。
    /// 把孤儿笔记里的内容按区块角色挪进胜出的那一页，再删掉孤儿的区块与笔记。结果是确定的：
    /// 两台设备同时做这件事，写出的是同样的记录。返回是否改动了什么。
    @discardableResult
    public func reconcileDays(now: Date = Date()) throws -> Bool {
        let referenced = Set(days.map(\.noteID))
        let orphans = store.values(RecordType.note).compactMap(Note.init(json:))
            .filter { $0.kind == .day && !referenced.contains($0.id) }
        var changed = false
        for note in orphans {
            guard let date = dateOf(note), let target = day(date) else { continue }
            let blocks = blocks(note: note.id)
            let sections = Dictionary(blocks.filter { $0.kind == .section }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var edits: [(type: String, id: String, value: JSONValue?)] = []
            for block in blocks where block.kind != .section {
                let role = block.parentID.flatMap { sections[$0] }?.role ?? .notes
                guard let section = try section(role, of: target) ?? createSection(role, of: target, now: now) else { continue }
                var moved = block
                moved.noteID = target.noteID
                moved.parentID = section.id
                edits.append((RecordType.block, moved.id, moved.json))
            }
            for section in sections.values { edits.append((RecordType.block, section.id, nil)) }
            edits.append((RecordType.note, note.id, nil))
            try commit(edits)
            changed = true
        }
        return changed
    }

    /// 孤儿笔记是哪一天的：新版 id 里就有日期；旧版从标题「10 月 9 日」和创建时间推出年份。
    private func dateOf(_ note: Note) -> String? {
        if note.id.hasPrefix("day-") { return String(note.id.dropFirst(4)) }
        let numbers = note.title.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 2 else { return nil }
        let created = clock.calendar.dateComponents([.year], from: note.createdAt).year ?? 2026
        let candidates = [created - 1, created, created + 1].map { String(format: "%04d-%02d-%02d", $0, numbers[0], numbers[1]) }
        return candidates.min { abs(clock.date(for: $0)?.timeIntervalSince(note.createdAt) ?? .infinity)
            < abs(clock.date(for: $1)?.timeIntervalSince(note.createdAt) ?? .infinity) }
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

/// 一天的收尾：晚间提醒据此决定提不提醒、提醒什么。
public struct Evening: Equatable, Sendable {
    public var date: String
    public var stats: DayStats
    public var hasSummary: Bool
    /// 明日目标的条数
    public var plans: Int
    /// 没做完、明天会自动延续的件数
    public var pending: Int
    /// 没做完、留在今天不带走的件数
    public var staying: Int = 0

    public var isComplete: Bool { hasSummary && plans > 0 }

    /// 还差什么（界面上的「还差：…」）。
    public var missing: [String] {
        (hasSummary ? [] : ["今日总结"]) + (plans > 0 ? [] : ["明日目标"])
    }

    /// 晚间通知的文字；都写好了就是 nil（不提醒）。
    public var nudge: Nudge? {
        let done = stats.total > 0 ? "今天完成 \(stats.done)/\(stats.total)。" : ""
        let carry = pending > 0 ? "没做完的 \(pending) 件会自动延续，不用再抄一遍。" : ""
        switch (hasSummary, plans > 0) {
        case (true, true):
            return nil
        case (false, false):
            return Nudge(title: "今晚总结", body: done + "用一句话记下今天，再定下明天要做的事。" + carry)
        case (false, true):
            return Nudge(title: "今日总结还没写", body: done + "明天的目标定好了，再用一句话记下今天。")
        case (true, false):
            return Nudge(title: "明天做什么？", body: "总结写好了。定一两件明天的事，明早会出现在今日目标里。" + carry)
        }
    }

    public struct Nudge: Equatable, Sendable {
        public var title: String
        public var body: String
    }
}

extension Evening {
    /// 还没到的那几天先排的通用提醒（当天的内容要到那天才知道）。
    public static let genericNudge: Nudge? = Nudge(title: "今晚总结", body: "用一句话记下今天，再定下明天要做的事。")
}

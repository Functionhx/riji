import Foundation
import Observation
import RijiKit

/// 界面的唯一状态源。所有修改经过 DailyBook（→ RecordStore → 本机变更日志），然后 `revision` 加一，
/// 观察它的视图重新读取。读取都很便宜（全部记录在内存里）。
@MainActor
@Observable
public final class RijiModel {
    public let book: DailyBook
    public private(set) var revision = 0
    public private(set) var today: String
    public var selectedDate: String
    public var route: Route = .day
    public var lastError: String?
    private let now: () -> Date

    public enum Route: Hashable {
        case day
        case timeline
        case progress
    }

    public init(book: DailyBook, now: @escaping () -> Date = Date.init) {
        self.book = book
        self.now = now
        let today = book.clock.key(for: now())
        self.today = today
        self.selectedDate = today
        perform { try book.ensureDay(today, now: now()) }
    }

    /// 打开本机数据：应用容器里的 `Riji/changes.jsonl`；设备 id 第一次生成后保存在偏好设置里。
    public static func openDefault(defaults: UserDefaults = .standard) throws -> RijiModel {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Riji", isDirectory: true)
        let device: String
        if let saved = defaults.string(forKey: "riji.device") {
            device = saved
        } else {
            #if os(macOS)
            let prefix = "mac"
            #else
            let prefix = "ios"
            #endif
            device = "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())"
            defaults.set(device, forKey: "riji.device")
        }
        let store = try RecordStore(log: ChangeLog(url: folder.appendingPathComponent("changes.jsonl")), device: device)
        return RijiModel(book: DailyBook(store: store))
    }

    /// 只在内存里的模型（预览、截图、测试）。
    public static func preview(seed: Bool = true, now: Date = Date()) -> RijiModel {
        let store = try! RecordStore(log: nil, device: "preview")
        let book = DailyBook(store: store)
        if seed { DemoData.seed(book, today: book.clock.key(for: now), now: now) }
        return RijiModel(book: book, now: { now })
    }

    public var currentDate: Date { now() }

    /// 跨过零点时生成新的一天（视图每分钟调用一次）。
    public func refreshDay() {
        let key = book.clock.key(for: now())
        guard key != today else { return }
        let wasOnToday = selectedDate == today
        today = key
        if wasOnToday { selectedDate = key }
        perform { try book.ensureDay(key, now: now()) }
    }

    public func open(_ date: String) {
        selectedDate = date
        route = .day
        perform { try book.ensureDay(date, now: now()) }
    }

    /// 包一层：写入失败时记下错误（界面显示），成功则触发刷新。
    public func perform(_ action: () throws -> Void) {
        do {
            try action()
            lastError = nil
        } catch {
            lastError = "没能保存：\(error.localizedDescription)"
        }
        revision += 1
    }

    // 读取（视图里先读 revision 建立依赖）
    public func items(_ role: Block.SectionRole, on date: String) -> [Block] {
        _ = revision
        return book.items(role, on: date)
    }

    public func stats(on date: String) -> DayStats {
        _ = revision
        return book.stats(on: date)
    }

    public var days: [Day] {
        _ = revision
        return book.days
    }

    public var progresses: [ProgressItem] {
        _ = revision
        return book.progresses
    }

    public func progress(_ id: String?) -> ProgressItem? {
        _ = revision
        return id.flatMap(book.progress)
    }

    public var heatmap: [String: Int] {
        _ = revision
        return book.heatmap()
    }

    public var streak: Int {
        _ = revision
        return book.streak(today: today)
    }

    public func notes(on date: String) -> String {
        _ = revision
        return book.notes(on: date)
    }

    public func evening(on date: String) -> Evening {
        _ = revision
        return book.evening(on: date)
    }

    /// 昨天写过东西却没写总结：返回昨天的日期（今天页顶部的「补写」）。
    public var missedEvening: String? {
        _ = revision
        return book.missedEvening(today: today)
    }
}

/// 第一次打开时的示例内容（只用于预览与截图，真实数据从空白开始）。
public enum DemoData {
    public static func seed(_ book: DailyBook, today: String, now: Date) {
        let clock = book.clock
        let yesterday = clock.adding(days: -1, to: today)
        do {
            // 过去几个月的热力图
            for offset in stride(from: 120, through: 2, by: -1) where offset % 3 != 0 || offset % 7 == 1 {
                let date = clock.adding(days: -offset, to: today)
                let count = (offset * 7) % 5
                for i in 0...count {
                    let task = try book.add(.check, text: "第 \(i + 1) 件事", to: .todo, on: date, now: now)
                    if let task, i < count { try book.setChecked(true, of: task.id) }
                }
                if let leftover = book.items(.todo, on: date).last(where: { !$0.checked }) { try book.setChecked(true, of: leftover.id) }
            }
            // 昨天：1007
            let english = try book.add(.check, text: "英语单词", to: .todo, on: yesterday, now: now)
            _ = english
            for text in ["徐涛马原", "高数 17 讲"] {
                if let task = try book.add(.check, text: text, to: .todo, on: yesterday, now: now) { try book.setChecked(true, of: task.id) }
            }
            for text in ["sony 继续", "文章便利贴功能", "参考文献必填"] {
                try book.add(.spark, text: text, to: .spark, on: yesterday, now: now)
            }
            try book.setNotes("感觉黑夜模式下更好看？", on: yesterday, now: now)
            try book.setSummary("马原过完一轮，高数推进到 17 讲。", on: yesterday)
            for text in ["高数 18 讲", "sony 继续"] {
                try book.add(.check, text: text, to: .tomorrow, on: yesterday, now: now)
            }
            // 今天：1008
            try book.ensureDay(today, now: now)
            if let english = book.items(.todo, on: today).first(where: { $0.carryFrom != nil }) {
                try book.setAttr("carried_days", .number(2), of: english.id)
            }
            if let task = try book.add(.check, text: "徐涛马原", to: .todo, on: today, now: now) { try book.setChecked(true, of: task.id) }
            if let task = book.items(.todo, on: today).first(where: { $0.text.plain == "高数 18 讲" }) { try book.setChecked(true, of: task.id) }
            let spark = try book.add(.spark, text: "每日日志提醒功能", to: .spark, on: today, now: now)
            if let spark { try book.promote(spark: spark.id, on: today, now: now) }
            try book.add(.check, text: "高数 19 讲", to: .tomorrow, on: today, now: now)
            for text in ["微信文件传输助手分析历史", "参考文献必填", "继续浏览·全部文章？"] {
                try book.add(.spark, text: text, to: .spark, on: today, now: now)
            }
            if var math = book.progresses.first(where: { $0.name == "高数" }) {
                math.target = 40
                try book.updateProgress(math)
            }
            try book.updateProgress(ProgressItem(id: "demo-english", name: "英语单词", unit: "天", current: 26, target: 60, updatedDay: today))
            try book.updateProgress(ProgressItem(id: "demo-marx", name: "马原", unit: "章", current: 6, target: 8, updatedDay: yesterday))
            try book.setNotes("", on: today, now: now)
        } catch {
            assertionFailure("demo seed failed: \(error)")
        }
    }
}

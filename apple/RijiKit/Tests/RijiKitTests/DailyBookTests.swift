import Foundation
import Testing
@testable import RijiKit

private final class FakeWall: @unchecked Sendable {
    var ms: Int64 = 1_759_889_000_000
}

private func makeBook(log: ChangeLog? = nil, wall: FakeWall = FakeWall()) throws -> DailyBook {
    try DailyBook(store: RecordStore(log: log, device: "mac-test", wall: { wall.ms += 1; return wall.ms }))
}

private let monday = Date(timeIntervalSince1970: 1_759_889_000)  // 2025-10-08 10:03 北京时间

@Suite("daily rules")
struct DailyBookTests {
    @Test func dayClockUsesBeijingTime() {
        let clock = DayClock()
        // 2025-10-07 18:30 UTC = 2025-10-08 02:30 北京时间
        #expect(clock.key(for: Date(timeIntervalSince1970: 1_759_861_800)) == "2025-10-08")
        #expect(clock.title(for: "2026-10-08") == "10 月 8 日")
        #expect(clock.weekday(for: "2026-10-08") == "星期四")
        #expect(clock.adding(days: 1, to: "2026-10-31") == "2026-11-01")
        #expect(clock.daysBetween("2026-10-05", "2026-10-08") == 3)
    }

    @Test func progressParser() {
        #expect(ProgressParser.parse("电路 18 讲") == .init(name: "电路", value: 18, unit: "讲"))
        #expect(ProgressParser.parse("马原 第 6 章") == .init(name: "马原", value: 6, unit: "章"))
        #expect(ProgressParser.parse("英语单词26天") == .init(name: "英语单词", value: 26, unit: "天"))
        #expect(ProgressParser.parse("徐涛马原") == nil)
        #expect(ProgressParser.parse("每日日志提醒功能") == nil)
        #expect(ProgressParser.parse("18 讲") == nil)
    }

    @Test func orderKeys() {
        var keys: [String] = []
        var last: String? = nil
        for _ in 0..<60 {
            last = OrderKey.after(last)
            keys.append(last!)
        }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
        let middle = OrderKey.between("a", "b")
        #expect("a" < middle && middle < "b")
        let front = OrderKey.between(nil, "a")
        #expect(front < "a")
    }

    @Test func newDayHasThreeSections() throws {
        let book = try makeBook()
        let day = try book.ensureDay("2026-10-08", now: monday)
        #expect(book.section(.todo, of: day) != nil)
        #expect(book.section(.spark, of: day) != nil)
        #expect(book.section(.notes, of: day) != nil)
        // 再次调用不重复创建
        _ = try book.ensureDay("2026-10-08", now: monday)
        #expect(book.days.count == 1)
        #expect(book.blocks(note: day.noteID).filter { $0.kind == .section }.count == 3)
    }

    @Test func unfinishedTasksCarryOverWithoutRewritingHistory() throws {
        let book = try makeBook()
        let english = try book.add(.check, text: "英语单词", to: .todo, on: "2026-10-07", now: monday)!
        let marx = try book.add(.check, text: "徐涛马原", to: .todo, on: "2026-10-07", now: monday)!
        try book.setChecked(true, of: marx.id)

        try book.ensureDay("2026-10-08", now: monday)
        let today = book.items(.todo, on: "2026-10-08")
        #expect(today.map(\.text.plain) == ["英语单词"])
        #expect(today[0].carryFrom == english.id)
        #expect(today[0].carriedDays == 1)
        // 昨天的那条还在，记着「已延续到」
        let yesterday = book.items(.todo, on: "2026-10-07")
        #expect(yesterday.first { $0.id == english.id }?.carriedTo == today[0].id)
        // 再打开一次今天不会重复带
        try book.ensureDay("2026-10-08", now: monday)
        #expect(book.items(.todo, on: "2026-10-08").count == 1)

        // 隔两天才打开：天数累加
        try book.ensureDay("2026-10-10", now: monday)
        let later = book.items(.todo, on: "2026-10-10")
        #expect(later.count == 1 && later[0].carriedDays == 3)

        // 昨天的统计：被带走的未完成项不再算在昨天的总数里
        #expect(book.stats(on: "2026-10-07") == DayStats(total: 1, done: 1, carried: 0, sparks: 0, hasContent: true))
    }

    @Test func deletingACarriedTaskReleasesTheOriginal() throws {
        let book = try makeBook()
        let original = try book.add(.check, text: "sony 继续", to: .todo, on: "2026-10-07", now: monday)!
        try book.ensureDay("2026-10-08", now: monday)
        let carried = book.items(.todo, on: "2026-10-08")[0]
        try book.delete(carried.id)
        #expect(book.items(.todo, on: "2026-10-07").first { $0.id == original.id }?.carriedTo == nil)
    }

    @Test func progressIsRecognisedAndAdvancedOnCheck() throws {
        let book = try makeBook()
        let task = try book.add(.check, text: "电路 18 讲", to: .todo, on: "2026-10-08", now: monday)!
        let progress = try #require(book.progresses.first)
        #expect(progress.name == "电路" && progress.unit == "讲" && progress.current == 17)
        #expect(task.progressID == progress.id)
        try book.setChecked(true, of: task.id)
        #expect(book.progress(progress.id)?.current == 18)
        // 第二天写「电路 19 讲」挂到同一个进度上
        let next = try book.add(.check, text: "电路 19 讲", to: .todo, on: "2026-10-09", now: monday)!
        #expect(next.progressID == progress.id)
        #expect(book.progresses.count == 1)
    }

    @Test func sparksPromoteToTasks() throws {
        let book = try makeBook()
        let spark = try book.add(.spark, text: "每日日志提醒功能", to: .spark, on: "2026-10-08", now: monday)!
        let task = try #require(try book.promote(spark: spark.id, on: "2026-10-08", now: monday))
        #expect(book.items(.todo, on: "2026-10-08").map(\.id) == [task.id])
        #expect(book.store.value(RecordType.block, spark.id).flatMap(Block.init(json:))?.attrs["promoted_to"]?.string == task.id)
    }

    @Test func heatmapAndStreak() throws {
        let book = try makeBook()
        for (date, done) in [("2026-10-05", 1), ("2026-10-06", 3), ("2026-10-07", 0), ("2026-10-08", 5)] {
            for i in 0..<max(done, 1) {
                let task = try book.add(.check, text: "任务 \(i)", to: .todo, on: date, now: monday)!
                if i < done { try book.setChecked(true, of: task.id) }
            }
        }
        let levels = book.heatmap()
        #expect(levels["2026-10-08"] == 4 && levels["2026-10-06"] == 3 && levels["2026-10-05"] == 2)
        #expect(book.streak(today: "2026-10-08") == 4)
        #expect(book.streak(today: "2026-10-09") == 4)  // 今天还没写，从昨天数起
        #expect(book.streak(today: "2026-10-11") == 0)
    }

    @Test func everythingSurvivesARestart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("riji-\(UUID().uuidString)/changes.jsonl")
        let wall = FakeWall()
        do {
            let book = try makeBook(log: ChangeLog(url: url), wall: wall)
            let task = try book.add(.check, text: "电路 18 讲", to: .todo, on: "2026-10-08", now: monday)!
            try book.setChecked(true, of: task.id)
            try book.add(.spark, text: "参考文献必填", to: .spark, on: "2026-10-08", now: monday)
            try book.setNotes("感觉黑夜模式下更好看？", on: "2026-10-08", now: monday)
        }
        let reopened = try makeBook(log: ChangeLog(url: url), wall: wall)
        #expect(reopened.items(.todo, on: "2026-10-08").map(\.checked) == [true])
        #expect(reopened.items(.spark, on: "2026-10-08").map(\.text.plain) == ["参考文献必填"])
        #expect(reopened.notes(on: "2026-10-08") == "感觉黑夜模式下更好看？")
        #expect(reopened.progresses.first?.current == 18)
        // 新的写入时钟晚于日志里最新的一条
        let before = reopened.store.state.values.map(\.hlc).max()!
        try reopened.add(.check, text: "英语单词", to: .todo, on: "2026-10-08", now: monday)
        #expect(reopened.store.state.values.map(\.hlc).max()! > before)
    }
}

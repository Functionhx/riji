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

    @Test func dayEndsAtTheBoundaryNotMidnight() {
        let clock = DayClock(dayStart: 240)
        let night = Date(timeIntervalSince1970: 1_791_484_200)  // 2026-10-09 02:30 北京时间
        #expect(DayClock().key(for: night) == "2026-10-09")
        #expect(clock.key(for: night) == "2026-10-08")             // 凌晨 4 点前还是 8 号
        #expect(clock.key(for: night.addingTimeInterval(90 * 60)) == "2026-10-09")  // 04:00 翻页
        // 显示仍按零点：零点已过，「今天还剩」是 0，墨线走到头
        #expect(clock.minutesLeft(at: night) == 0 && clock.isPastMidnight(at: night))
        #expect(clock.dayProgress(at: night) == 1)
        let evening = night.addingTimeInterval(-4 * 3600)  // 8 号 22:30
        #expect(clock.minutesLeft(at: evening) == 90 && !clock.isPastMidnight(at: evening))
        // 00:30 的提醒属于 8 号的深夜；22:30 在墨线上的位置
        #expect(clock.instant(minutes: 30, on: "2026-10-08") == Date(timeIntervalSince1970: 1_791_477_000))
        #expect(clock.instant(minutes: 22 * 60 + 30, on: "2026-10-08") == Date(timeIntervalSince1970: 1_791_469_800))
        #expect(abs(clock.inkPosition(minutes: 22 * 60 + 30) - 990.0 / 1080.0) < 1e-9)
        #expect(clock.inkPosition(minutes: 30) == 1)
        #expect(abs(DayClock().inkPosition(minutes: 22 * 60 + 30) - 990.0 / 1080.0) < 1e-9)
    }

    @Test func carryOverHappensAtTheBoundary() throws {
        let book = try makeBook()
        book.clock = DayClock(dayStart: 240)
        let night = Date(timeIntervalSince1970: 1_791_484_200)  // 9 号 02:30
        try book.add(.check, text: "写周报", to: .tomorrow, on: "2026-10-08", now: night)
        // 还没到 4 点：今天仍是 8 号，不生成 9 号
        #expect(book.clock.key(for: night) == "2026-10-08")
        try book.ensureDay(book.clock.key(for: night), now: night)
        #expect(book.day("2026-10-09") == nil)
        let morning = night.addingTimeInterval(5 * 3600)  // 07:30
        try book.ensureDay(book.clock.key(for: morning), now: morning)
        #expect(book.items(.todo, on: "2026-10-09").map(\.text.plain) == ["写周报"])
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

    @Test func newDayHasFourSections() throws {
        let book = try makeBook()
        let day = try book.ensureDay("2026-10-08", now: monday)
        #expect(book.section(.todo, of: day) != nil)
        #expect(book.section(.spark, of: day) != nil)
        #expect(book.section(.notes, of: day) != nil)
        #expect(book.section(.tomorrow, of: day) != nil)
        // 再次调用不重复创建
        _ = try book.ensureDay("2026-10-08", now: monday)
        #expect(book.days.count == 1)
        #expect(book.blocks(note: day.noteID).filter { $0.kind == .section }.count == 4)
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

    @Test func deletingACarriedTaskDropsItForGood() throws {
        let book = try makeBook()
        let original = try book.add(.check, text: "sony 继续", to: .todo, on: "2026-10-07", now: monday)!
        try book.ensureDay("2026-10-08", now: monday)
        let carried = book.items(.todo, on: "2026-10-08")[0]
        try book.delete(carried.id)
        let released = try #require(book.items(.todo, on: "2026-10-07").first { $0.id == original.id })
        #expect(released.carriedTo == nil && released.dropped)
        // 再打开今天（回到今天、点热力图）不会把它又带回来
        try book.ensureDay("2026-10-08", now: monday)
        #expect(book.items(.todo, on: "2026-10-08").isEmpty)
        // 放下的事不算在原来那天的总数里
        #expect(book.stats(on: "2026-10-07").total == 0)
    }

    @Test func tomorrowGoalsBecomeNextDaysGoals() throws {
        let book = try makeBook()
        try book.add(.check, text: "sony 继续", to: .todo, on: "2026-10-07", now: monday)
        let circuit = try book.add(.check, text: "电路 20 讲", to: .tomorrow, on: "2026-10-07", now: monday)!
        let report = try book.add(.check, text: "写周报", to: .tomorrow, on: "2026-10-07", now: monday)!
        let same = try book.add(.check, text: "Sony 继续 ", to: .tomorrow, on: "2026-10-07", now: monday)!
        try book.add(.check, text: "  ", to: .tomorrow, on: "2026-10-07", now: monday)
        // 写明日目标不会提前生成第二天
        #expect(book.day("2026-10-08") == nil)

        try book.ensureDay("2026-10-08", now: monday)
        let today = book.items(.todo, on: "2026-10-08")
        // 先是昨天定下的目标，再是延续的事；重名的只留一条，空白的不带
        #expect(today.map(\.text.plain) == ["电路 20 讲", "写周报", "sony 继续"])
        #expect(today[0].plannedFrom == circuit.id && today[0].progressID == circuit.progressID && !today[0].checked)
        #expect(today[2].carryFrom != nil && today[2].plannedFrom == nil)
        let plans = Dictionary(uniqueKeysWithValues: book.items(.tomorrow, on: "2026-10-07").map { ($0.id, $0) })
        #expect(plans[circuit.id]?.plannedTo == today[0].id)
        #expect(plans[report.id]?.plannedTo == today[1].id)
        #expect(plans[same.id]?.plannedTo == today[2].id)
        // 再打开一次不重复
        try book.ensureDay("2026-10-08", now: monday)
        #expect(book.items(.todo, on: "2026-10-08").count == 3)

        // 目标没做完，第三天照常延续，但不再标「昨日定」
        try book.ensureDay("2026-10-09", now: monday)
        let third = book.items(.todo, on: "2026-10-09")
        #expect(third.map(\.text.plain) == ["电路 20 讲", "写周报", "sony 继续"])
        #expect(third.allSatisfy { $0.plannedFrom == nil && $0.carryFrom != nil })
    }

    @Test func goalsWrittenAfterMidnightLandOnTheNewDay() throws {
        let book = try makeBook()
        try book.add(.check, text: "背单词", to: .todo, on: "2026-10-07", now: monday)
        try book.ensureDay("2026-10-08", now: monday)  // 过了零点，今天的页面已经生成
        let goal = try book.add(.check, text: "整理笔记", to: .tomorrow, on: "2026-10-07", now: monday)!
        try book.add(.check, text: "跑步", to: .tomorrow, on: "2026-10-07", now: monday)
        let today = book.items(.todo, on: "2026-10-08")
        #expect(today.map(\.text.plain) == ["整理笔记", "跑步", "背单词"])
        #expect(book.block(goal.id)?.plannedTo == today[0].id)
        // 今天已经手写过的事，补写同名目标不重复
        try book.add(.check, text: "背单词", to: .tomorrow, on: "2026-10-07", now: monday)
        #expect(book.items(.todo, on: "2026-10-08").count == 3)
    }

    @Test func goalsNeverLandOnPastDays() throws {
        let book = try makeBook()
        try book.ensureDay("2026-10-07", now: monday)
        try book.ensureDay("2026-10-08", now: monday)
        let later = Date(timeIntervalSince1970: 1_791_857_000)  // 2026-10-13
        let goal = try book.add(.check, text: "补的目标", to: .tomorrow, on: "2026-10-07", now: later)!
        #expect(book.items(.todo, on: "2026-10-08").isEmpty)
        #expect(book.block(goal.id)?.plannedTo == nil)
    }

    @Test func editingAGoalFollowsItUntilTouched() throws {
        let book = try makeBook()
        let goal = try book.add(.check, text: "电路 20 讲", to: .tomorrow, on: "2026-10-07", now: monday)!
        try book.ensureDay("2026-10-08", now: monday)
        let copyID = try #require(book.block(goal.id)?.plannedTo)
        try book.setText("电路 21 讲", of: goal.id)
        #expect(book.block(copyID)?.text.plain == "电路 21 讲")
        try book.setChecked(true, of: copyID)
        try book.setText("电路 22 讲", of: goal.id)
        #expect(book.block(copyID)?.text.plain == "电路 21 讲")
    }

    @Test func oldPagesGetTheTomorrowSectionOnFirstWrite() throws {
        let book = try makeBook()
        let day = try book.ensureDay("2026-10-07", now: monday)
        let section = try #require(book.section(.tomorrow, of: day))
        try book.store.write([(RecordType.block, section.id, nil)])  // 模拟加这个区块之前的老页面
        #expect(book.section(.tomorrow, of: day) == nil)
        try book.add(.check, text: "写周报", to: .tomorrow, on: "2026-10-07", now: monday)
        #expect(book.items(.tomorrow, on: "2026-10-07").map(\.text.plain) == ["写周报"])
        let roles = book.blocks(note: day.noteID).filter { $0.kind == .section }.sorted { $0.order < $1.order }.compactMap(\.role)
        #expect(roles == [.todo, .spark, .notes, .tomorrow])
    }

    @Test func eveningNudgeOnlyAsksForWhatIsMissing() throws {
        let book = try makeBook()
        let date = "2026-10-08"
        let done = try book.add(.check, text: "徐涛马原", to: .todo, on: date, now: monday)!
        try book.setChecked(true, of: done.id)
        try book.add(.check, text: "sony 继续", to: .todo, on: date, now: monday)

        var evening = book.evening(on: date)
        #expect(evening.missing == ["今日总结", "明日目标"])
        #expect(evening.nudge?.title == "今晚总结")
        #expect(evening.nudge?.body.contains("今天完成 1/2") == true)
        #expect(evening.nudge?.body.contains("没做完的 1 件会自动延续") == true)

        try book.add(.check, text: "写周报", to: .tomorrow, on: date, now: monday)
        evening = book.evening(on: date)
        #expect(evening.missing == ["今日总结"] && evening.nudge?.title == "今日总结还没写")

        try book.setSummary("马原过完一轮。", on: date)
        evening = book.evening(on: date)
        #expect(evening.isComplete && evening.nudge == nil)

        // 只写了总结
        try book.ensureDay("2026-10-09", now: monday)
        try book.setSummary("休息日", on: "2026-10-09")
        #expect(book.evening(on: "2026-10-09").nudge?.title == "明天做什么？")
    }

    @Test func morningAsksToBackfillYesterday() throws {
        let book = try makeBook()
        #expect(book.missedEvening(today: "2026-10-08") == nil)  // 昨天没有页面
        try book.ensureDay("2026-10-07", now: monday)
        #expect(book.missedEvening(today: "2026-10-08") == nil)  // 空白的一天不催
        try book.add(.spark, text: "参考文献必填", to: .spark, on: "2026-10-07", now: monday)
        #expect(book.missedEvening(today: "2026-10-08") == "2026-10-07")
        try book.setSummary("写了一点", on: "2026-10-07")
        #expect(book.missedEvening(today: "2026-10-08") == nil)
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

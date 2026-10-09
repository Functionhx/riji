import Foundation
import Testing
@testable import RijiKit

/// 内存里的副本：和 riji-sync 一样只接受「接在最后一段后面、prev 吻合」的段。
private actor FakeReplica: SyncTransport {
    var logs: [String: [Segment]] = [:]
    var rejected = 0

    func heads() async throws -> [String: SegmentHead] {
        logs.mapValues { SegmentHead(seq: $0.last!.seq, hash: $0.last!.chainHash) }
    }

    func fetch(device: String, from seq: Int, limit: Int) async throws -> [Segment] {
        Array((logs[device] ?? []).filter { $0.seq >= seq }.prefix(limit))
    }

    func push(_ segments: [Segment]) async throws {
        for segment in segments {
            let log = logs[segment.device] ?? []
            let head = log.last.map { SegmentHead(seq: $0.seq, hash: $0.chainHash) } ?? .empty
            if segment.seq <= head.seq, log.first(where: { $0.seq == segment.seq })?.ct == segment.ct { continue }
            guard segment.seq == head.seq + 1, segment.prev == head.hash else { rejected += 1; continue }
            logs[segment.device, default: []].append(segment)
        }
    }
}

private final class Wall: @unchecked Sendable {
    var ms: Int64
    init(_ ms: Int64) { self.ms = ms }
}

/// 一台设备：本机日志 + 远端日志 + 同步进度都在临时目录里，可以「重启」。
private struct Device {
    let folder: URL
    let name: String
    let wall: Wall
    let book: DailyBook
    let engine: SyncEngine

    static func make(_ name: String, folder: URL, key: SyncKey, replica: FakeReplica, wall: Wall) throws -> Device {
        let store = try RecordStore(log: ChangeLog(url: folder.appendingPathComponent("changes.jsonl")),
                                    remoteLog: ChangeLog(url: folder.appendingPathComponent("remote-changes.jsonl")),
                                    device: name, wall: { wall.ms += 1; return wall.ms })
        let engine = try SyncEngine(store: store, key: key, transport: replica, folder: folder.appendingPathComponent("sync"))
        return Device(folder: folder, name: name, wall: wall, book: DailyBook(store: store), engine: engine)
    }

    func restarted(key: SyncKey, replica: FakeReplica) throws -> Device {
        try Device.make(name, folder: folder, key: key, replica: replica, wall: wall)
    }
}

private func tempFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("riji-sync-\(UUID().uuidString)")
}

private let morning = Date(timeIntervalSince1970: 1_791_425_000)  // 2026-10-08 10:03 北京时间

@Suite("sync")
struct SyncTests {
    @Test func twoDevicesConverge() async throws {
        let key = SyncKey.generate()
        let replica = FakeReplica()
        let mac = try Device.make("mac-1", folder: tempFolder(), key: key, replica: replica, wall: Wall(1_791_425_000_000))
        let phone = try Device.make("android-1", folder: tempFolder(), key: key, replica: replica, wall: Wall(1_791_425_100_000))

        let task = try mac.book.add(.check, text: "高数 18 讲", to: .todo, on: "2026-10-08", now: morning)!
        try mac.book.add(.spark, text: "同桌理论", to: .spark, on: "2026-10-08", now: morning)
        let first = try await mac.engine.sync()
        #expect(first.sealed == 1 && first.pushed == 1 && first.pulled == 0)

        let pulled = try await phone.engine.sync()
        #expect(pulled.pulled == 1 && pulled.absorbed > 0)
        #expect(phone.book.items(.todo, on: "2026-10-08").map(\.text.plain) == ["高数 18 讲"])
        #expect(phone.book.items(.spark, on: "2026-10-08").map(\.text.plain) == ["同桌理论"])

        // 手机勾掉、写总结；Mac 拉回
        try phone.book.setChecked(true, of: task.id)
        try phone.book.setSummary("高数过完 18 讲", on: "2026-10-08")
        try await phone.engine.sync()
        try await mac.engine.sync()
        #expect(mac.book.items(.todo, on: "2026-10-08").first?.checked == true)
        #expect(mac.book.day("2026-10-08")?.summary == "高数过完 18 讲")
        #expect(mac.book.progresses.first?.current == 18)

        // 两边状态完全一致
        #expect(mac.book.store.state == phone.book.store.state)
        #expect(await replica.rejected == 0)
    }

    @Test func nothingIsSentTwiceAndRestartsResume() async throws {
        let key = SyncKey.generate()
        let replica = FakeReplica()
        let folder = tempFolder()
        var mac = try Device.make("mac-1", folder: folder, key: key, replica: replica, wall: Wall(1_791_425_000_000))
        let phone = try Device.make("android-1", folder: tempFolder(), key: key, replica: replica, wall: Wall(1_791_425_100_000))
        try mac.book.add(.check, text: "英语单词", to: .todo, on: "2026-10-08", now: morning)
        try await mac.engine.sync()
        let again = try await mac.engine.sync()
        #expect(again.sealed == 0 && again.pushed == 0)

        try phone.book.add(.spark, text: "参考文献必填", to: .spark, on: "2026-10-08", now: morning)
        try await phone.engine.sync()
        try await mac.engine.sync()

        // 重启：远端变更从 remote-changes.jsonl 回来，进度也在；再同步不会重复拉、重复封装
        mac = try mac.restarted(key: key, replica: replica)
        #expect(mac.book.items(.spark, on: "2026-10-08").map(\.text.plain) == ["参考文献必填"])
        let resumed = try await mac.engine.sync()
        #expect(resumed.sealed == 0 && resumed.pushed == 0 && resumed.pulled == 0)
        try mac.book.add(.check, text: "背 50 个单词", to: .todo, on: "2026-10-08", now: morning)
        let next = try await mac.engine.sync()
        #expect(next.sealed == 1 && next.pushed == 1)
        #expect(await replica.logs["mac-1"]?.map(\.seq) == [1, 2])
    }

    @Test func sameDayOnBothDevicesIsDeterministic() async throws {
        let key = SyncKey.generate()
        let replica = FakeReplica()
        let mac = try Device.make("mac-1", folder: tempFolder(), key: key, replica: replica, wall: Wall(1_791_425_000_000))
        let phone = try Device.make("android-1", folder: tempFolder(), key: key, replica: replica, wall: Wall(1_791_425_100_000))
        // 两边都离线写了同一天：新版的页面与区块 id 是确定的，同步后是同一页
        try mac.book.add(.check, text: "Mac 上的事", to: .todo, on: "2026-10-09", now: morning)
        try phone.book.add(.check, text: "手机上的事", to: .todo, on: "2026-10-09", now: morning)
        try await mac.engine.sync(); try await phone.engine.sync(); try await mac.engine.sync()
        for device in [mac, phone] {
            #expect(Set(device.book.items(.todo, on: "2026-10-09").map(\.text.plain)) == ["Mac 上的事", "手机上的事"])
            #expect(try device.book.reconcileDays() == false)
        }
        #expect(mac.book.store.state == phone.book.store.state)
    }

    @Test func legacyDuplicateDaysAreMerged() async throws {
        let key = SyncKey.generate()
        let replica = FakeReplica()
        let mac = try Device.make("mac-1", folder: tempFolder(), key: key, replica: replica, wall: Wall(1_791_425_000_000))
        let phone = try Device.make("android-1", folder: tempFolder(), key: key, replica: replica, wall: Wall(1_791_425_100_000))
        // 模拟旧版：各自用随机 id 生成了 10 月 9 日
        for (device, text) in [(mac, "sony 继续"), (phone, "背单词")] {
            let noteID = RecordID.make(now: morning)
            let sectionID = RecordID.make(now: morning)
            let note = Note(id: noteID, kind: .day, title: "10 月 9 日", createdAt: morning, updatedAt: morning)
            let section = Block(id: sectionID, noteID: noteID, parentID: nil, order: "a", kind: .section,
                                attrs: ["role": "todo", "title": "TODO"], createdAt: morning)
            let task = Block(id: RecordID.make(now: morning), noteID: noteID, parentID: sectionID, order: "a", kind: .check,
                             attrs: ["checked": false], text: RichText(text), createdAt: morning)
            try device.book.store.write([(RecordType.note, noteID, note.json),
                                         (RecordType.day, "2026-10-09", Day(date: "2026-10-09", timeZone: "Asia/Shanghai", noteID: noteID).json),
                                         (RecordType.block, sectionID, section.json), (RecordType.block, task.id, task.json)])
        }
        try await mac.engine.sync(); try await phone.engine.sync(); try await mac.engine.sync()
        // 合并前：只看得到胜出那一页的内容
        #expect(mac.book.items(.todo, on: "2026-10-09").count == 1)
        // 两边各自合并（同时做也一样），再同步一轮
        #expect(try mac.book.reconcileDays())
        #expect(try phone.book.reconcileDays())
        try await mac.engine.sync(); try await phone.engine.sync(); try await mac.engine.sync()
        for device in [mac, phone] {
            #expect(Set(device.book.items(.todo, on: "2026-10-09").map(\.text.plain)) == ["sony 继续", "背单词"])
            #expect(device.book.store.values(RecordType.note).count == 1)
        }
        #expect(mac.book.store.state == phone.book.store.state)
    }

    @Test func wrongKeyIsDetected() async throws {
        let replica = FakeReplica()
        let mac = try Device.make("mac-1", folder: tempFolder(), key: .generate(), replica: replica, wall: Wall(1_791_425_000_000))
        let stranger = try Device.make("android-9", folder: tempFolder(), key: .generate(), replica: replica, wall: Wall(1_791_425_100_000))
        try mac.book.add(.check, text: "秘密", to: .todo, on: "2026-10-08", now: morning)
        try await mac.engine.sync()
        let report = try await stranger.engine.sync()
        #expect(report.absorbed == 0 && report.problems.count == 1)
        #expect(stranger.book.items(.todo, on: "2026-10-08").isEmpty)
    }
}

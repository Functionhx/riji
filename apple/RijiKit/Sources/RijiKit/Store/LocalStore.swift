import Foundation

/// 本机的变更日志：每次修改追加一行规范 JSON（JSON Lines），启动时按 HLC 合并出状态。
/// 这就是同步协议里「本设备的日志」的明文形态：配对之后，未封装的变更会被加密成段推送出去。
/// 文件在系统保护的应用容器里（macOS 沙盒 / iOS 数据保护），离开设备的数据才做端到端加密。
public final class ChangeLog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    public func readAll() throws -> [Change] {
        lock.lock(); defer { lock.unlock() }
        let data = try Data(contentsOf: url)
        var changes: [Change] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            // 半行（写入时断电）跳过；其余行损坏会让整条日志不可信，直接报错。
            guard let change = try? Change(json: JSONValue(jsonData: Data(line))) else {
                if line.last != UInt8(ascii: "}") { continue }
                throw StoreError.corruptLog
            }
            changes.append(change)
        }
        return changes
    }

    public func append(_ changes: [Change]) throws {
        guard !changes.isEmpty else { return }
        var data = Data()
        for change in changes {
            data.append(try change.json.canonicalData())
            data.append(UInt8(ascii: "\n"))
        }
        lock.lock(); defer { lock.unlock() }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}

public enum StoreError: Error, Equatable {
    case corruptLog
}

/// 合并后的全部记录，加上写入接口。界面通过 `RijiRepository`（RijiUI）观察它。
public final class RecordStore: @unchecked Sendable {
    public private(set) var state: [String: RecordState] = [:]
    public let clock: HLCClock
    private let log: ChangeLog?
    private let lock = NSLock()

    /// `log == nil` 时只在内存里（预览与测试）。
    public init(log: ChangeLog?, device: String, wall: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        self.log = log
        var state: [String: RecordState] = [:]
        var latest: HLC?
        if let log {
            let changes = try log.readAll()
            Merge.apply(changes, to: &state)
            latest = changes.map(\.hlc).max()
        }
        self.state = state
        self.clock = HLCClock(device: device, last: latest, wall: wall)
    }

    public func value(_ type: String, _ id: String) -> JSONValue? {
        lock.lock(); defer { lock.unlock() }
        guard let record = state["\(type):\(id)"], !record.deleted else { return nil }
        return record.value
    }

    public func values(_ type: String) -> [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        let prefix = "\(type):"
        return state.compactMap { key, record in key.hasPrefix(prefix) && !record.deleted ? record.value : nil }
    }

    /// 一次写入多条（一个用户动作 = 一批），全部带上递增的 HLC。
    @discardableResult
    public func write(_ edits: [(type: String, id: String, value: JSONValue?)]) throws -> [Change] {
        let changes = edits.map { edit in
            Change(type: edit.type, id: edit.id, hlc: clock.now(), deleted: edit.value == nil, value: edit.value)
        }
        try log?.append(changes)
        lock.lock()
        Merge.apply(changes, to: &state)
        lock.unlock()
        return changes
    }

    /// 合并来自其他设备的变更（同步拉回时用）。
    public func absorb(_ changes: [Change]) {
        lock.lock()
        Merge.apply(changes, to: &state)
        lock.unlock()
        if let newest = changes.map(\.hlc).max() { clock.observe(newest) }
    }
}

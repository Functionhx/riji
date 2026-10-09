import CryptoKit
import Foundation

// 同步一轮（docs/DESIGN.md §8.3）：把本机新写的变更封装成本设备的段 → 推给副本 → 从副本拉回其他设备的新段，
// 校验序号与哈希链、解密、按 HLC 合并。副本（腾讯云 riji-sync）只存密文段。

/// 一台设备在副本上的最新段。
public struct SegmentHead: Codable, Equatable, Sendable {
    public var seq: Int
    public var hash: String

    public init(seq: Int, hash: String) { self.seq = seq; self.hash = hash }
    public static let empty = SegmentHead(seq: 0, hash: RijiCrypto.genesisPrev)
}

/// 副本的访问方式（真实的是 HTTP；测试用内存实现）。
public protocol SyncTransport: Sendable {
    func heads() async throws -> [String: SegmentHead]
    func fetch(device: String, from seq: Int, limit: Int) async throws -> [Segment]
    func push(_ segments: [Segment]) async throws
}

/// 同步用的密钥：第一台设备随机生成，配对时封装给新设备；服务器永远看不到。
public struct SyncKey: Equatable, Sendable {
    public var key: Data
    public var epoch: Int

    public init(key: Data, epoch: Int = 0) { self.key = key; self.epoch = epoch }
    public static func generate() -> SyncKey { SyncKey(key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }) }

    public var json: JSONValue { ["key": .string(Base64URL.encode(key)), "epoch": .number(Double(epoch))] }

    public init?(json: JSONValue) {
        guard let text = json["key"]?.string, let key = Base64URL.decode(text), key.count == 32 else { return nil }
        self.init(key: key, epoch: json["epoch"]?.int ?? 0)
    }
}

/// 本机的同步进度（文件 sync-state.json）。
public struct SyncState: Codable, Equatable, Sendable {
    /// 本机日志里已经封装进段的变更条数
    public var sealed = 0
    /// 本设备最新一段
    public var own = SegmentHead.empty
    /// 其他设备：已收到的最新一段（版本向量）
    public var vector: [String: SegmentHead] = [:]
    public var lastSync: Date?

    public init() {}
}

public struct SyncReport: Equatable, Sendable {
    public var sealed = 0
    public var pushed = 0
    public var pulled = 0
    /// 拉回的变更条数（> 0 时界面需要刷新、做一次同日合并）
    public var absorbed = 0
    public var problems: [String] = []
    /// 副本上有几台设备（含本机）
    public var devices = 0
}

public enum SyncError: Error, Equatable {
    case ownLogAhead(server: Int, local: Int)
}

/// 同步引擎。文件都在 `folder` 里：sync-state.json（进度）、own-segments.jsonl（本设备的段，也是一份副本）。
public final class SyncEngine: @unchecked Sendable {
    public static let changesPerSegment = 400

    public let device: String
    private let store: RecordStore
    private let key: SyncKey
    private let transport: SyncTransport
    private let stateURL: URL
    private let ownURL: URL
    public private(set) var state: SyncState
    private let gate = NSLock()
    private var running = false

    public init(store: RecordStore, key: SyncKey, transport: SyncTransport, folder: URL) throws {
        self.store = store
        self.device = store.clock.device
        self.key = key
        self.transport = transport
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        stateURL = folder.appendingPathComponent("sync-state.json")
        ownURL = folder.appendingPathComponent("own-segments.jsonl")
        if let data = try? Data(contentsOf: stateURL) {
            state = try JSONDecoder.iso.decode(SyncState.self, from: data)
        } else {
            state = SyncState()
        }
    }

    private var rijiKey: SymmetricKey { SymmetricKey(data: key.key) }

    /// 同步一轮。同时只跑一轮（重复调用直接返回空报告）。
    @discardableResult
    public func sync() async throws -> SyncReport {
        let started: Bool = gate.withLock {
            if running { return false }
            running = true
            return true
        }
        guard started else { return SyncReport() }
        defer { gate.withLock { running = false } }

        var report = SyncReport()
        report.sealed = try sealPending()
        let heads = try await transport.heads()
        report.devices = Set(heads.keys).union([device]).count
        report.pushed = try await pushOwn(serverHead: heads[device] ?? .empty)
        for (other, head) in heads.sorted(by: { $0.key < $1.key }) where other != device {
            let (segments, changes, problem) = try await pull(device: other, head: head)
            report.pulled += segments
            report.absorbed += changes
            if let problem { report.problems.append(problem) }
        }
        state.lastSync = Date()
        try saveState()
        return report
    }

    // ---------------------------------------------------------------- 封装

    /// 本机日志里还没封装的变更 → 新段（先落盘，再改进度）。
    func sealPending() throws -> Int {
        guard let log = store.log else { return 0 }
        let all = try log.readAll()
        guard all.count > state.sealed else { return 0 }
        var pending = Array(all[state.sealed...])
        var count = 0
        while !pending.isEmpty {
            let chunk = Array(pending.prefix(Self.changesPerSegment))
            pending.removeFirst(chunk.count)
            let segment = try Segment.seal(rijiKey: rijiKey, device: device, seq: state.own.seq + 1, prev: state.own.hash,
                                           epoch: key.epoch, changes: chunk)
            try appendOwn(segment)
            state.own = SegmentHead(seq: segment.seq, hash: segment.chainHash)
            state.sealed += chunk.count
            try saveState()
            count += 1
        }
        return count
    }

    private func appendOwn(_ segment: Segment) throws {
        var data = try JSONEncoder.canonical.encode(segment)
        data.append(UInt8(ascii: "\n"))
        if !FileManager.default.fileExists(atPath: ownURL.path) { FileManager.default.createFile(atPath: ownURL.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: ownURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func ownSegments(after seq: Int) throws -> [Segment] {
        guard let data = try? Data(contentsOf: ownURL) else { return [] }
        return try data.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }
            .map { try JSONDecoder().decode(Segment.self, from: Data($0)) }
            .filter { $0.seq > seq }
            .sorted { $0.seq < $1.seq }
    }

    // ---------------------------------------------------------------- 推送 / 拉取

    private func pushOwn(serverHead: SegmentHead) async throws -> Int {
        if serverHead.seq > state.own.seq { throw SyncError.ownLogAhead(server: serverHead.seq, local: state.own.seq) }
        let missing = try ownSegments(after: serverHead.seq)
        var pushed = 0
        var batch: [Segment] = []
        for segment in missing {
            batch.append(segment)
            if batch.count == 50 {
                try await transport.push(batch); pushed += batch.count; batch = []
            }
        }
        if !batch.isEmpty { try await transport.push(batch); pushed += batch.count }
        return pushed
    }

    /// 拉取一台设备的新段：序号必须接上、prev 必须吻合、必须能解开；出问题就停在这台设备的这里。
    private func pull(device other: String, head: SegmentHead) async throws -> (Int, Int, String?) {
        var known = state.vector[other] ?? .empty
        guard head.seq > known.seq else { return (0, 0, nil) }
        var segments = 0
        var absorbed = 0
        while known.seq < head.seq {
            let page = try await transport.fetch(device: other, from: known.seq + 1, limit: 200)
            if page.isEmpty { break }
            var changes: [Change] = []
            var problem: String?
            for segment in page.sorted(by: { $0.seq < $1.seq }) {
                guard segment.device == other, segment.seq == known.seq + 1 else { problem = "\(other)：缺第 \(known.seq + 1) 段"; break }
                guard segment.prev == known.hash else { problem = "\(other)：第 \(segment.seq) 段的哈希链对不上"; break }
                guard let opened = try? segment.open(rijiKey: rijiKey) else { problem = "\(other)：第 \(segment.seq) 段解不开（密钥不对或被篡改）"; break }
                changes += opened
                known = SegmentHead(seq: segment.seq, hash: segment.chainHash)
                segments += 1
            }
            if !changes.isEmpty {
                try store.absorb(changes)
                absorbed += changes.count
            }
            state.vector[other] = known
            try saveState()
            if let problem { return (segments, absorbed, problem) }
        }
        return (segments, absorbed, nil)
    }

    private func saveState() throws {
        try JSONEncoder.canonical.encode(state).write(to: stateURL, options: .atomic)
    }
}

extension JSONEncoder {
    static var canonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

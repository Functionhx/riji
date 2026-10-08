import Foundation

/// 混合逻辑时钟。文本形式 `1759889000000.0000.mac-1`：13 位毫秒、4 位十六进制计数、设备 id。
/// 固定宽度，字符串字典序就是时钟顺序；设备 id 是最后的平局裁决。规格见 spec/SYNC 与 hlc.json 向量。
public struct HLC: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let ms: Int64
    public let counter: Int
    public let device: String

    public init(ms: Int64, counter: Int, device: String) throws {
        guard ms >= 0, ms <= 9_999_999_999_999 else { throw HLCError.outOfRange }
        guard counter >= 0, counter <= 0xFFFF else { throw HLCError.outOfRange }
        guard HLC.isValidDevice(device) else { throw HLCError.invalidDevice }
        self.ms = ms
        self.counter = counter
        self.device = device
    }

    public init(parsing text: String) throws {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 13, parts[1].count == 4,
              parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              parts[1].allSatisfy({ "0123456789abcdef".contains($0) }),
              let ms = Int64(parts[0]), let counter = Int(parts[1], radix: 16)
        else { throw HLCError.invalidText(text) }
        try self.init(ms: ms, counter: counter, device: String(parts[2]))
    }

    public var description: String {
        let msText = String(ms)
        let counterText = String(counter, radix: 16)
        return String(repeating: "0", count: 13 - msText.count) + msText + "."
            + String(repeating: "0", count: 4 - counterText.count) + counterText + "." + device
    }

    public static func < (lhs: HLC, rhs: HLC) -> Bool { lhs.description < rhs.description }

    static func isValidDevice(_ device: String) -> Bool {
        (1...36).contains(device.count) && device.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }

    /// 本地事件：max(墙钟, 上次)；同一毫秒计数 +1。
    public static func tick(last: HLC?, wallMs: Int64, device: String) throws -> HLC {
        let previousMs = last?.ms ?? 0
        if wallMs > previousMs { return try HLC(ms: wallMs, counter: 0, device: device) }
        return try HLC(ms: previousMs, counter: (last?.counter ?? 0) + 1, device: device)
    }

    /// 收到远端时钟：新时钟晚于本地上次与远端两者。
    public static func receive(last: HLC?, remote: HLC, wallMs: Int64, device: String) throws -> HLC {
        let localMs = last?.ms ?? 0
        let localCounter = last?.counter ?? 0
        let ms = max(wallMs, localMs, remote.ms)
        let counter: Int
        if ms == localMs && ms == remote.ms {
            counter = max(localCounter, remote.counter) + 1
        } else if ms == localMs {
            counter = localCounter + 1
        } else if ms == remote.ms {
            counter = remote.counter + 1
        } else {
            counter = 0
        }
        return try HLC(ms: ms, counter: counter, device: device)
    }
}

public enum HLCError: Error, Equatable {
    case outOfRange
    case invalidDevice
    case invalidText(String)
}

/// 线程安全的本机时钟：每次 `now()` 都严格递增。
public final class HLCClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: HLC?
    public let device: String
    private let wall: @Sendable () -> Int64

    public init(device: String, last: HLC? = nil, wall: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.device = device
        self.last = last
        self.wall = wall
    }

    public func now() -> HLC {
        lock.lock()
        defer { lock.unlock() }
        let next = (try? HLC.tick(last: last, wallMs: wall(), device: device))!
        last = next
        return next
    }

    public func observe(_ remote: HLC) {
        lock.lock()
        defer { lock.unlock() }
        if let next = try? HLC.receive(last: last, remote: remote, wallMs: wall(), device: device) { last = next }
    }
}

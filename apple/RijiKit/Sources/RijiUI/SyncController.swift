import CryptoKit
import Foundation
import Observation
import RijiKit

/// 腾讯云 riji-server 同步接口的 HTTP 访问（server/riji-server）。连接码与邮件提醒共用。
struct HTTPSyncTransport: SyncTransport {
    static let endpoint = URL(string: "https://fanyuchen.com.cn/riji/sync/")!
    static let apiEndpoint = URL(string: "https://fanyuchen.com.cn/riji/api/")!
    let token: String
    var base: URL = HTTPSyncTransport.endpoint

    struct Failure: Error, LocalizedError {
        var status: Int
        var code: String?
        var errorDescription: String? {
            switch (status, code) {
            case (401, _): "连接码不对"
            case (404, "not_found"): "配对码不存在或已过期"
            case (409, "taken"): "这个配对码已经被另一台设备用了"
            case (404, "invite_invalid"): "邀请码不对、已经用过或已过期"
            case (403, "admin_space"): "站长空间不能删除"
            case (413, _): "空间满了（100 MB）"
            case (429, _): "试得太频繁了，过几分钟再来"
            default: "同步服务返回 \(status)\(code.map { "（\($0)）" } ?? "")"
            }
        }
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Any? = nil, auth: Bool = true) async throws -> (Int, [String: Any]) {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = method
        if auth, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    private func ok(_ result: (Int, [String: Any])) throws -> [String: Any] {
        guard result.0 == 200 else { throw Failure(status: result.0, code: result.1["error"] as? String) }
        return result.1
    }

    func heads() async throws -> [String: SegmentHead] {
        let json = try ok(await request("GET", "heads"))
        let devices = json["devices"] as? [String: [String: Any]] ?? [:]
        return devices.compactMapValues { head in
            guard let seq = head["seq"] as? Int, let hash = head["hash"] as? String else { return nil }
            return SegmentHead(seq: seq, hash: hash)
        }
    }

    func fetch(device: String, from seq: Int, limit: Int) async throws -> [Segment] {
        let json = try ok(await request("GET", "segments", query: [
            URLQueryItem(name: "device", value: device), URLQueryItem(name: "from", value: String(seq)), URLQueryItem(name: "limit", value: String(limit)),
        ]))
        let list = json["segments"] as? [Any] ?? []
        return try list.map { try JSONDecoder().decode(Segment.self, from: JSONSerialization.data(withJSONObject: $0)) }
    }

    func push(_ segments: [Segment]) async throws {
        let body = try segments.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        _ = try ok(await request("POST", "segments", body: ["segments": body]))
    }
}

/// 同步的总控：密钥、引擎、状态与配对（这台 Mac 是发起端）。
///
/// 文件都在应用容器 `Application Support/Riji/` 里：sync-key（日迹密钥，0600）、sync/（进度与本设备的段）、
/// remote-changes.jsonl（拉回的变更，由 RecordStore 读写）。
@MainActor
@Observable
public final class SyncController {
    public enum Pairing: Equatable {
        case idle
        case starting
        case waiting(code: String)
        case confirm(code: String, sas: String)
        case sending
        case done
        case failed(String)
    }

    public private(set) var enabled = false
    public private(set) var syncing = false
    public private(set) var status = ""
    public private(set) var devices = 0
    public private(set) var lastSync: Date?
    public private(set) var pairing: Pairing = .idle

    /// 这台设备加入别人发起的配对（加入端）
    public enum Joining: Equatable {
        case idle
        case working
        case confirm(sas: String)
        case failed(String)
    }
    public private(set) var joining: Joining = .idle

    /// 服务器上的这个空间：是不是站长、用了多少
    public struct Space: Equatable, Sendable {
        public var admin: Bool
        public var bytes: Int
        public var quota: Int
    }
    public private(set) var space: Space?
    public private(set) var invite: String?
    public private(set) var notice: String?
    private var joinTask: Task<Void, Never>?

    private let model: RijiModel
    private let folder: URL
    private var engine: SyncEngine?
    private var pairingTask: Task<Void, Never>?
    private var pairingSecret: (code: String, key: SymmetricKey)?

    public init(model: RijiModel) {
        self.model = model
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Riji")
        if let key = loadKey() { start(with: key) }
    }

    private var keyURL: URL { folder.appendingPathComponent("sync-key") }

    private func loadKey() -> SyncKey? {
        guard let data = try? Data(contentsOf: keyURL), let json = try? JSONValue(jsonData: data) else { return nil }
        return SyncKey(json: json)
    }

    private func start(with key: SyncKey) {
        let token = MailReminder.shared.token
        guard !token.isEmpty else { status = "先在「邮件提醒」里填连接码"; return }
        do {
            engine = try SyncEngine(store: model.book.store, key: key, transport: HTTPSyncTransport(token: token),
                                    folder: folder.appendingPathComponent("sync"))
            enabled = true
            lastSync = engine?.state.lastSync
            publishSettings()
            status = lastSync == nil ? "已开启" : "已同步"
            Task { await refreshSpace() }
        } catch {
            status = "同步没能启动：\(error.localizedDescription)"
        }
    }

    /// 第一台设备：生成日迹密钥并开启同步。
    public func enable() {
        guard !enabled else { return }
        let key = SyncKey.generate()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: keyURL.path, contents: try key.json.canonicalData(), attributes: [.posixPermissions: 0o600])
        } catch {
            status = "没能保存密钥：\(error.localizedDescription)"
            return
        }
        start(with: key)
        Task { await sync() }
    }

    /// 同步一轮；拉回了东西就合并同一天的重复页、刷新界面。
    public func sync() async {
        guard let engine, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let report = try await engine.sync()
            devices = report.devices
            lastSync = engine.state.lastSync
            if report.absorbed > 0 {
                adoptSettings()
                model.perform { try model.book.reconcileDays(now: model.currentDate) }
                model.refreshDay()
            }
            status = report.problems.first ?? "已同步"
        } catch {
            status = "同步失败：\(error.localizedDescription)"
        }
    }

    // ---------------------------------------------------------------- 空间：邀请、加入、删除

    private var api: HTTPSyncTransport { HTTPSyncTransport(token: MailReminder.shared.token, base: HTTPSyncTransport.apiEndpoint) }

    private func ok(_ result: (Int, [String: Any])) throws -> [String: Any] {
        guard result.0 == 200 else { throw HTTPSyncTransport.Failure(status: result.0, code: result.1["error"] as? String) }
        return result.1
    }

    public func refreshSpace() async {
        guard let json = try? ok(await api.request("GET", "spaces/me")) else { return }
        space = Space(admin: json["admin"] as? Bool ?? false, bytes: json["bytes"] as? Int ?? 0, quota: json["quota"] as? Int ?? 0)
    }

    /// 朋友：用站长给的邀请码建自己的空间，拿到连接码，这台设备生成自己的日迹密钥、开启同步。
    public func joinWithInvite(_ code: String) async {
        notice = nil
        do {
            let json = try ok(await HTTPSyncTransport(token: "", base: HTTPSyncTransport.apiEndpoint)
                .request("POST", "spaces", body: ["invite": code], auth: false))
            guard let token = json["token"] as? String else { throw HTTPSyncTransport.Failure(status: 500, code: nil) }
            MailReminder.shared.token = token
            enable()
            notice = "已加入：这是你自己的空间，内容只有你的设备解得开"
        } catch {
            notice = error.localizedDescription
        }
    }

    /// 站长：生成一次性邀请码（7 天有效）。
    public func createInvite() async {
        notice = nil
        do {
            invite = try ok(await api.request("POST", "invites", body: [:]))["invite"] as? String
        } catch {
            notice = error.localizedDescription
        }
    }

    /// 删除服务器上的这个空间（日志段、提醒、连接码）。本机的笔记保留。
    public func deleteSpace() async {
        notice = nil
        do {
            _ = try ok(await api.request("DELETE", "spaces/me"))
            engine = nil
            enabled = false
            space = nil
            try? FileManager.default.removeItem(at: keyURL)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("sync"))
            MailReminder.shared.token = ""
            status = ""
            notice = "服务器上的空间已删除；这台设备上的笔记还在"
        } catch {
            notice = error.localizedDescription
        }
    }

    // ---------------------------------------------------------------- 配对（加入端）

    /// 输入另一台设备显示的 8 位配对码：两边显示比对码，对方确认后取回信封（日迹密钥、连接码、设置）。
    public func joinPairing(_ code: String) {
        let digits = code.filter(\.isNumber)
        guard digits.count == 8 else { joining = .failed("配对码是 8 位数字"); return }
        joinTask?.cancel()
        joining = .working
        let transport = HTTPSyncTransport(token: "")
        joinTask = Task { [weak self] in
            let own = RijiKit.Pairing.KeyPair()
            do {
                let joined = try await transport.request("POST", "pair/join", body: ["code": digits, "pub": own.publicKey], auth: false)
                guard joined.0 == 200, let initiator = joined.1["pub"] as? String else {
                    throw HTTPSyncTransport.Failure(status: joined.0, code: joined.1["error"] as? String)
                }
                let keys = RijiKit.Pairing.keys(shared: try RijiKit.Pairing.shared(own, peer: initiator),
                                                transcript: RijiKit.Pairing.transcript(code: digits, initiator: initiator, joiner: own.publicKey))
                self?.joining = .confirm(sas: keys.sas)
                let deadline = Date().addingTimeInterval(600)
                while Date() < deadline, !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1.5))
                    let fetched = try await transport.request("POST", "pair/fetch", body: ["code": digits, "pub": own.publicKey], auth: false)
                    if fetched.0 == 202 { continue }
                    guard fetched.0 == 200, let sealed = fetched.1["sealed"] as? String else {
                        throw HTTPSyncTransport.Failure(status: fetched.0, code: fetched.1["error"] as? String)
                    }
                    self?.adoptPairing(try RijiKit.Pairing.open(key: keys.key, code: digits, sealed: sealed))
                    return
                }
                if !Task.isCancelled { self?.joining = .failed("等太久了，配对码已过期") }
            } catch is CancellationError {
            } catch {
                self?.joining = .failed(error.localizedDescription)
            }
        }
    }

    public func cancelJoining() {
        joinTask?.cancel()
        joining = .idle
    }

    private func adoptPairing(_ payload: JSONValue) {
        guard let text = payload["key"]?.string, let raw = Base64URL.decode(text), raw.count == 32 else {
            joining = .failed("信封里没有密钥"); return
        }
        let key = SyncKey(key: raw, epoch: payload["epoch"]?.int ?? 0)
        if let token = payload["token"]?.string { MailReminder.shared.token = token }
        if let settings = payload["settings"] { MailReminder.shared.adoptSynced(settings, force: true) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: keyURL.path, contents: try key.json.canonicalData(), attributes: [.posixPermissions: 0o600])
        } catch {
            joining = .failed("没能保存密钥：\(error.localizedDescription)"); return
        }
        joining = .idle
        start(with: key)
        Task { await sync() }
    }

    // ---------------------------------------------------------------- 设置也同步

    /// 所有设置作为一条加密记录（settings:shared）随内容一起同步，以最后一次修改（updated_at）为准。
    static let settingsID = "shared"

    private var sharedSettings: JSONValue? { model.book.store.value(RecordType.settings, Self.settingsID) }

    /// 本机设置比同步记录新（或还没有记录）：写进记录，下一轮同步带给其他设备。
    public func publishSettings() {
        guard enabled else { return }
        let local = MailReminder.shared.syncedSettings
        let localUpdated = local["updated_at"]?.int ?? 0
        if let shared = sharedSettings, (shared["updated_at"]?.int ?? 0) >= localUpdated, shared == local { return }
        if let shared = sharedSettings, (shared["updated_at"]?.int ?? 0) > localUpdated { return }
        model.perform { try model.book.store.write([(RecordType.settings, Self.settingsID, local)]) }
    }

    /// 同步记录比本机新：照着改本机设置。
    func adoptSettings() {
        guard let shared = sharedSettings else { return }
        MailReminder.shared.adoptSynced(shared)
    }

    // ---------------------------------------------------------------- 配对（发起端）

    public func startPairing() {
        guard enabled else { return }
        cancelPairing()
        pairing = .starting
        let transport = HTTPSyncTransport(token: MailReminder.shared.token)
        pairingTask = Task { [weak self] in
            let own = RijiKit.Pairing.KeyPair()
            do {
                let started = try await transport.request("POST", "pair/start", body: ["pub": own.publicKey])
                guard started.0 == 200, let code = started.1["code"] as? String else {
                    throw HTTPSyncTransport.Failure(status: started.0, code: started.1["error"] as? String)
                }
                self?.pairing = .waiting(code: code)
                let deadline = Date().addingTimeInterval(600)
                while Date() < deadline, !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1.5))
                    let polled = try await transport.request("GET", "pair/status", query: [URLQueryItem(name: "code", value: code)])
                    if polled.0 == 404 { throw HTTPSyncTransport.Failure(status: 404, code: "not_found") }
                    if let joiner = polled.1["pub_b"] as? String {
                        let shared = try RijiKit.Pairing.shared(own, peer: joiner)
                        let keys = RijiKit.Pairing.keys(shared: shared, transcript: RijiKit.Pairing.transcript(code: code, initiator: own.publicKey, joiner: joiner))
                        self?.pairingSecret = (code, keys.key)
                        self?.pairing = .confirm(code: code, sas: keys.sas)
                        return
                    }
                }
                if !Task.isCancelled { self?.pairing = .failed("配对码已过期") }
            } catch is CancellationError {
            } catch {
                self?.pairing = .failed(error.localizedDescription)
            }
        }
    }

    /// 站长确认两边的比对码一致：把日迹密钥、连接码与提醒设置封进信封。
    public func confirmPairing() {
        guard case .confirm = pairing, let secret = pairingSecret, let key = loadKey() else { return }
        pairing = .sending
        let payload: JSONValue = [
            "key": .string(Base64URL.encode(key.key)), "epoch": .number(Double(key.epoch)),
            "token": .string(MailReminder.shared.token),
            "settings": MailReminder.shared.settingsJSON,
        ]
        let transport = HTTPSyncTransport(token: MailReminder.shared.token)
        pairingTask = Task { [weak self] in
            do {
                let sealed = try RijiKit.Pairing.seal(key: secret.key, code: secret.code, payload: payload)
                let result = try await transport.request("POST", "pair/seal", body: ["code": secret.code, "sealed": sealed])
                guard result.0 == 200 else { throw HTTPSyncTransport.Failure(status: result.0, code: result.1["error"] as? String) }
                self?.pairingSecret = nil
                self?.pairing = .done
            } catch {
                self?.pairing = .failed(error.localizedDescription)
            }
        }
    }

    public func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairingSecret = nil
        pairing = .idle
    }
}

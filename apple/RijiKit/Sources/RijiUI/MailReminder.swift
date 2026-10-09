import Foundation
import Observation
import RijiKit

/// 邮件提醒（兜底）：通知之后仍没写，由腾讯云上的 riji-server 发信（见仓库 server/riji-server）。
///
/// 设备只上报今天的几个数字和邮件设置，不上报任何笔记内容。设置以最近一次修改为准：服务器返回最新的一份，
/// 别的设备上改过的话这里照着更新。连接码存在应用沙盒里的一个文件中（见 `tokenURL`）。
@MainActor
@Observable
public final class MailReminder {
    public static let shared = MailReminder()
    public static let endpoint = URL(string: "https://fanyuchen.com.cn/riji/api/")!

    public static let emailKey = "riji.mail.enabled"
    public static let recipientsKey = "riji.mail.recipients"
    public static let delayKey = "riji.mail.delay"
    public static let updatedKey = "riji.settings.updated"
    public static let delays = [30, 60, 90, 120]
    public static let maxRecipients = 5

    /// 最近一次和服务器打交道的结果（设置窗口里显示）。
    public private(set) var status: String = ""
    public private(set) var serverReady: Bool?
    /// 设置或连接码每改一次加一：应用据此立即重新上报（不必等到内容变化）。
    public private(set) var version = 0

    private let defaults = UserDefaults.standard

    // ---------------------------------------------------------------- 设置

    /// 连接码不放钥匙串：应用没有开发者签名，每次更新签名都变，钥匙串会反复弹授权框、还会卡住界面。
    /// 沙盒容器里的文件只有本应用能读（别的应用访问需要用户同意）；连接码泄露的后果也只是能改提醒设置。
    public static var tokenURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Riji/reminder-token")
    }

    public var token: String {
        get { ((try? String(contentsOf: Self.tokenURL, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                try? FileManager.default.removeItem(at: Self.tokenURL)
            } else {
                try? FileManager.default.createDirectory(at: Self.tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: Self.tokenURL.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600])
            }
            version += 1
        }
    }

    /// 任何一项提醒设置被用户改动时调用：记下时间，它就成了「最新的一份」。
    public static func touch() {
        UserDefaults.standard.set(Int(Date().timeIntervalSince1970 * 1000), forKey: updatedKey)
        shared.version += 1
    }

    public static func parse(_ text: String) -> (valid: [String], invalid: [String]) {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ",，;；、 \n\t")).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        var valid: [String] = []
        var invalid: [String] = []
        for part in parts where seen.insert(part.lowercased()).inserted {
            if part.range(of: #"^[A-Za-z0-9._%+\-]{1,64}@[A-Za-z0-9.\-]{1,190}\.[A-Za-z]{2,24}$"#, options: .regularExpression) != nil {
                valid.append(part)
            } else {
                invalid.append(part)
            }
        }
        return (valid, invalid)
    }

    private var settingsPayload: [String: Any] {
        [
            "email": defaults.bool(forKey: Self.emailKey),
            "reminder": ReminderSettings.enabled,
            "recipients": Array(Self.parse(defaults.string(forKey: Self.recipientsKey) ?? "").valid.prefix(Self.maxRecipients)),
            "minutes": ReminderSettings.minutes,
            "delay": defaults.object(forKey: Self.delayKey) as? Int ?? 60,
            "day_start": ReminderSettings.dayStart,
            "carry": ReminderSettings.carryByDefault,
            "updated_at": defaults.integer(forKey: Self.updatedKey),
        ]
    }

    /// 随内容一起加密同步的全部设置（含连接码）。
    public var syncedSettings: JSONValue {
        var json = settingsJSON
        if case var .object(fields) = json {
            fields["token"] = .string(token)
            json = .object(fields)
        }
        return json
    }

    /// 同步记录比本机新：照着改（提醒、分界线、邮件、连接码）。不改修改时间以外的东西，所以不会再回写。
    public func adoptSynced(_ shared: JSONValue, force: Bool = false) {
        guard let updated = shared["updated_at"]?.int, force || updated > defaults.integer(forKey: Self.updatedKey) else { return }
        if let value = shared["reminder"]?.bool { defaults.set(value, forKey: ReminderSettings.enabledKey) }
        if let value = shared["minutes"]?.int { defaults.set(value, forKey: ReminderSettings.minutesKey) }
        if let value = shared["day_start"]?.int { defaults.set(value, forKey: ReminderSettings.dayStartKey) }
        if let value = shared["carry"]?.bool { defaults.set(value, forKey: ReminderSettings.carryKey) }
        if let value = shared["email"]?.bool { defaults.set(value, forKey: Self.emailKey) }
        if let value = shared["recipients"]?.array { defaults.set(value.compactMap(\.string).joined(separator: ", "), forKey: Self.recipientsKey) }
        if let value = shared["delay"]?.int { defaults.set(value, forKey: Self.delayKey) }
        if let value = shared["token"]?.string, !value.isEmpty, value != token { token = value }
        defaults.set(updated, forKey: Self.updatedKey)
        version += 1
    }

    /// 配对时一并交给新设备的提醒设置（与上报的格式相同）。
    public var settingsJSON: JSONValue {
        guard let data = try? JSONSerialization.data(withJSONObject: settingsPayload), let json = try? JSONValue(jsonData: data) else { return [:] }
        return json
    }

    private func adopt(_ server: [String: Any]) {
        guard let updated = server["updated_at"] as? Int, updated > defaults.integer(forKey: Self.updatedKey) else { return }
        if let email = server["email"] as? Bool { defaults.set(email, forKey: Self.emailKey) }
        if let reminder = server["reminder"] as? Bool { defaults.set(reminder, forKey: ReminderSettings.enabledKey) }
        if let recipients = server["recipients"] as? [String] { defaults.set(recipients.joined(separator: ", "), forKey: Self.recipientsKey) }
        if let minutes = server["minutes"] as? Int { defaults.set(minutes, forKey: ReminderSettings.minutesKey) }
        if let delay = server["delay"] as? Int { defaults.set(delay, forKey: Self.delayKey) }
        if let dayStart = server["day_start"] as? Int { defaults.set(dayStart, forKey: ReminderSettings.dayStartKey) }
        defaults.set(updated, forKey: Self.updatedKey)
    }

    // ---------------------------------------------------------------- 上报

    /// 上报今天的数字与设置。没填连接码就什么都不做。
    public func report(book: DailyBook, today: String, device: String) async {
        guard !token.isEmpty else { return }
        let evening = book.evening(on: today)
        let body: [String: Any] = [
            "device": device, "date": today, "settings": settingsPayload,
            "evening": ["has_summary": evening.hasSummary, "plans": evening.plans, "done": evening.stats.done,
                        "total": evening.stats.total, "pending": evening.pending],
        ]
        guard let reply = await post("status", body) else { return }
        if let settings = reply["settings"] as? [String: Any] { adopt(settings) }
        serverReady = reply["smtp"] as? Bool
        status = serverReady == true ? "已连接 · \(Self.clock())" : "已连接，但服务器上还没设置发信邮箱"
    }

    public func sendTest() async {
        guard !token.isEmpty else { status = "先填连接码"; return }
        status = "正在发送…"
        guard let reply = await post("test", ["settings": settingsPayload]) else { return }
        if let count = reply["sent_to"] as? Int { status = "已发出，去 \(count) 个邮箱里看看（也看看垃圾箱）" }
    }

    private func post(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
        var request = URLRequest(url: Self.endpoint.appendingPathComponent(path), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                status = Self.message(for: json["error"] as? String, code: code)
                return nil
            }
            return json
        } catch {
            status = "连不上服务器：\(error.localizedDescription)"
            return nil
        }
    }

    static func message(for error: String?, code: Int) -> String {
        switch error {
        case "unauthorized": return "连接码不对"
        case "invalid": return "有邮箱地址格式不对"
        case "rate_limited": return "今天的测试邮件发得太多了，明天再试"
        case "smtp_not_configured": return "服务器上还没设置发信邮箱"
        case "no_recipients": return "先填收件邮箱"
        case "send_failed": return "发信失败：检查服务器上的发信邮箱授权码"
        default: return "服务器返回 \(code)"
        }
    }

    private static func clock() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }
}

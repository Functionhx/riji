import RijiKit
import SwiftUI
import UserNotifications

/// 晚间提醒的设置（偏好设置里两项；界面用同样的键读 @AppStorage）。
public enum ReminderSettings {
    public static let enabledKey = "riji.reminder.enabled"
    public static let minutesKey = "riji.reminder.minutes"
    public static let defaultEnabled = true
    public static let defaultMinutes = 22 * 60 + 30
    /// 一天的分界线（零点后的分钟数）：默认凌晨 4 点，零点后写的总结仍算前一天。
    public static let dayStartKey = "riji.day.start"
    public static let defaultDayStart = DayClock.suggestedDayStart
    public static let dayStarts = [0, 120, 180, 240, 300]
    /// 没做完的事默认是否带到明天（每件事可以单独选）。默认不带。
    public static let carryKey = "riji.carry.default"
    public static var carryByDefault: Bool { UserDefaults.standard.object(forKey: carryKey) as? Bool ?? false }

    public static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    public static var minutes: Int {
        UserDefaults.standard.object(forKey: minutesKey) as? Int ?? defaultMinutes
    }

    public static var dayStart: Int {
        UserDefaults.standard.object(forKey: dayStartKey) as? Int ?? defaultDayStart
    }

    public static func dayStartLabel(_ minutes: Int) -> String { minutes == 0 ? "零点" : "凌晨 \(minutes / 60) 点" }

    public static func label(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

/// 晚间通知：只在日迹开着时弹（不预先排系统通知，也不需要后台运行）。到了提醒时间、今日总结或明日目标
/// 还空着，就弹一次，只提缺的那一样；一天最多一次。日迹没开着时由服务器按兜底时间发邮件（MailReminder）。
@MainActor
public enum EveningReminder {
    static let prefix = "riji.evening."
    static let notifiedKey = "riji.notified"

    public static func requestAuthorization() async {
        guard ReminderSettings.enabled else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// 应用开着时每分钟、以及内容变化后调用。
    public static func notifyIfDue(book: DailyBook, today: String, now: Date) async {
        let center = UNUserNotificationCenter.current()
        // 旧版预先排好的通知一次清掉（日迹没开着时不该再弹）
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) || $0 == "riji.evening" }
        if !old.isEmpty { center.removePendingNotificationRequests(withIdentifiers: old) }
        guard ReminderSettings.enabled, UserDefaults.standard.string(forKey: notifiedKey) != today,
              let fire = book.clock.instant(minutes: ReminderSettings.minutes, on: today), now >= fire,
              let nudge = book.evening(on: today).nudge else { return }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = nudge.title
        content.body = nudge.body
        content.sound = .default
        content.threadIdentifier = "evening"
        try? await center.add(UNNotificationRequest(identifier: "riji.now.\(today)", content: content, trigger: nil))
        UserDefaults.standard.set(today, forKey: notifiedKey)
    }
}

/// 设置窗口（macOS ⌘,）。改动经过下面的绑定时记下修改时间（MailReminder.touch），多设备以最新的一份为准。
public struct ReminderSettingsView: View {
    @AppStorage(ReminderSettings.enabledKey) private var enabled = ReminderSettings.defaultEnabled
    @AppStorage(ReminderSettings.minutesKey) private var minutes = ReminderSettings.defaultMinutes
    @AppStorage(MailReminder.emailKey) private var email = false
    @AppStorage(MailReminder.recipientsKey) private var recipients = ""
    @AppStorage(MailReminder.delayKey) private var delay = 60
    @AppStorage(ReminderSettings.dayStartKey) private var dayStart = ReminderSettings.defaultDayStart
    @AppStorage(ReminderSettings.carryKey) private var carryDefault = false
    @State private var token = ""
    @Environment(SyncController.self) private var sync: SyncController?
    private let mail = MailReminder.shared

    public init() {}

    public var body: some View {
        let parsed = MailReminder.parse(recipients)
        Form {
            if let sync { SyncSection(sync: sync, hasToken: !token.isEmpty) }
            Section {
                Picker("一天结束于", selection: touched($dayStart)) {
                    ForEach(ReminderSettings.dayStarts, id: \.self) { Text(ReminderSettings.dayStartLabel($0)) }
                }
                Toggle("没做完的事自动带到明天", isOn: touched($carryDefault))
            } header: {
                Text("一天")
            } footer: {
                Text("分界线之前仍算前一天：零点后写的总结记在当天，明日目标与没做完的事也在分界线上才带到新的一天。"
                     + "每件事右边的「→ 明天」可以单独选带不带，优先于这个开关；明日目标总会排进明天。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("到点弹通知（日迹开着时）", isOn: touched($enabled))
                DatePicker("提醒时间", selection: time, displayedComponents: .hourAndMinute)
                    .disabled(!enabled)
            } header: {
                Text("晚间提醒")
            } footer: {
                Text("日迹开着时，到了提醒时间还缺东西就弹一次通知，只提缺的那一样；日迹没开着就交给下面的邮件。第二天早上如果昨天还没写总结，今天页顶部会出现「补写」。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("通知之后仍没写，发邮件提醒", isOn: touched($email))
                TextField("收件邮箱", text: touched($recipients), prompt: Text("可填多个，用逗号或换行隔开"), axis: .vertical)
                    .lineLimit(1...4)
                if !parsed.invalid.isEmpty {
                    Text("格式不对：" + parsed.invalid.joined(separator: "、")).font(.caption).foregroundStyle(.red)
                } else if parsed.valid.count > MailReminder.maxRecipients {
                    Text("最多 \(MailReminder.maxRecipients) 个，多出的不会收到").font(.caption).foregroundStyle(.red)
                }
                Picker("兜底时间", selection: touched($delay)) {
                    ForEach(MailReminder.delays, id: \.self) { minutes in
                        Text(Self.delayLabel(minutes))
                    }
                }
                SecureField("连接码", text: $token, prompt: Text("riji-…"))
                    .onSubmit { mail.token = token }
                    .onChange(of: token) { _, new in mail.token = new }
                HStack {
                    Button("发一封测试邮件") { Task { await mail.sendTest() } }
                        .disabled(token.isEmpty || parsed.valid.isEmpty)
                    Text(mail.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } header: {
                Text("邮件提醒（兜底）")
            } footer: {
                Text("到「提醒时间 + 兜底时间」时，今日总结或明日目标仍然空着、或者今天还没打开日迹，就由腾讯云上的服务发一封邮件，一天最多一封。"
                     + "只上传今天的几个数字（总结写没写、目标几条、完成几件），不上传笔记内容。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { token = mail.token }
        .onChange(of: enabled) { _, on in if on { Task { await EveningReminder.requestAuthorization() } } }
    }

    static func delayLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "通知后 \(minutes) 分钟" }
        return minutes % 60 == 0 ? "通知后 \(minutes / 60) 小时" : "通知后 \(minutes / 60).5 小时"
    }

    /// 用户改动 → 记下修改时间。
    private func touched<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; MailReminder.touch() })
    }

    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes = (parts.hour ?? 22) * 60 + (parts.minute ?? 30)
            MailReminder.touch()
        }
    }
}

/// 设置里的「同步」：开启、状态、立即同步、添加手机（这台 Mac 是配对的发起端）。
struct SyncSection: View {
    let sync: SyncController
    let hasToken: Bool

    var body: some View {
        Section {
            if !sync.enabled {
                Button("在这台 Mac 上开启同步") { sync.enable() }
                    .disabled(!hasToken)
                if !hasToken { Text("先在下面「邮件提醒」里填连接码。").font(.caption).foregroundStyle(.secondary) }
            } else {
                HStack {
                    Text(statusLine)
                    Spacer()
                    Button(sync.syncing ? "同步中…" : "立即同步") { Task { await sync.sync() } }.disabled(sync.syncing)
                }
                pairingView
            }
        } header: {
            Text("同步")
        } footer: {
            Text("手机与 Mac 的内容端到端加密同步：密钥只在你的设备上，腾讯云只存密文。打开应用、内容变化后与每分钟会自动同步。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusLine: String {
        var parts = [sync.status]
        if let last = sync.lastSync { parts.append(last.formatted(date: .omitted, time: .shortened)) }
        if sync.devices > 0 { parts.append("\(sync.devices) 台设备") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var pairingView: some View {
        switch sync.pairing {
        case .idle:
            Button("添加手机…") { sync.startPairing() }
        case .starting:
            Text("正在生成配对码…").foregroundStyle(.secondary)
        case let .waiting(code):
            VStack(alignment: .leading, spacing: 6) {
                Text("在手机「我 → 同步」里输入这串数字（10 分钟内有效）").font(.callout)
                Text(String(code.prefix(4)) + " " + String(code.suffix(4)))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Button("取消") { sync.cancelPairing() }
            }
        case let .confirm(_, sas):
            VStack(alignment: .leading, spacing: 8) {
                Text("手机上显示的比对码是这个吗？").font(.callout)
                Text(String(sas.prefix(3)) + " " + String(sas.suffix(3)))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                Text("一致才点「一致，发送」：不一致说明有人在中间冒充，取消即可。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("一致，发送") { sync.confirmPairing() }.keyboardShortcut(.defaultAction)
                    Button("不一致，取消") { sync.cancelPairing() }
                }
            }
        case .sending:
            Text("正在发送…").foregroundStyle(.secondary)
        case .done:
            HStack {
                Text("已发送，手机正在同步")
                Spacer()
                Button("完成") { sync.cancelPairing() }
            }
        case let .failed(message):
            HStack {
                Text(message).foregroundStyle(.red)
                Spacer()
                Button("重试") { sync.startPairing() }
            }
        }
    }
}

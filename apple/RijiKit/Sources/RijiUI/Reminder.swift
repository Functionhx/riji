import RijiKit
import SwiftUI
import UserNotifications

/// 晚间提醒的设置（偏好设置里两项；界面用同样的键读 @AppStorage）。
public enum ReminderSettings {
    public static let enabledKey = "riji.reminder.enabled"
    public static let minutesKey = "riji.reminder.minutes"
    public static let defaultEnabled = true
    public static let defaultMinutes = 22 * 60 + 30

    public static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    public static var minutes: Int {
        UserDefaults.standard.object(forKey: minutesKey) as? Int ?? defaultMinutes
    }

    public static func label(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

/// 晚间提醒：只在今日总结或明日目标还空着时提醒，并且只提缺的那一样。
///
/// 系统通知是预先排好的（应用没开着也会到点弹出），所以每次内容变化后重排：今天这一条按此刻的情况写
/// 或干脆不排；之后 13 天各排一条通用的，免得几天不开应用就再也收不到。全部在本机，不经过任何服务器。
@MainActor
public enum EveningReminder {
    static let prefix = "riji.evening."
    static let days = 14

    public static func requestAuthorization() async {
        guard ReminderSettings.enabled else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    public static func reschedule(book: DailyBook, today: String, now: Date) async {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0.hasPrefix(prefix) || $0 == "riji.evening" }  // 后者是旧版每天重复的那条
        center.removePendingNotificationRequests(withIdentifiers: old)
        guard ReminderSettings.enabled else { return }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let clock = book.clock
        let minutes = ReminderSettings.minutes
        for offset in 0..<days {
            let date = clock.adding(days: offset, to: today)
            guard let start = clock.date(for: date) else { continue }
            let fire = start.addingTimeInterval(TimeInterval(minutes * 60))
            guard fire > now, let nudge = offset == 0 ? book.evening(on: date).nudge : Evening.genericNudge else { continue }
            let content = UNMutableNotificationContent()
            content.title = nudge.title
            content.body = nudge.body
            content.sound = .default
            content.threadIdentifier = "evening"
            let parts = clock.calendar.dateComponents([.timeZone, .year, .month, .day, .hour, .minute], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: prefix + date, content: content, trigger: trigger))
        }
    }
}

/// 设置窗口（macOS ⌘,）。
public struct ReminderSettingsView: View {
    @AppStorage(ReminderSettings.enabledKey) private var enabled = ReminderSettings.defaultEnabled
    @AppStorage(ReminderSettings.minutesKey) private var minutes = ReminderSettings.defaultMinutes

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle("每晚提醒写今日总结和明日目标", isOn: $enabled)
                DatePicker("提醒时间", selection: time, displayedComponents: .hourAndMinute)
                    .disabled(!enabled)
            } footer: {
                Text("都写好了就不提醒；只差一样，就只提那一样。第二天早上如果昨天还没写总结，今天页顶部会出现「补写」。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onChange(of: enabled) { _, on in if on { Task { await EveningReminder.requestAuthorization() } } }
    }

    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes = (parts.hour ?? 22) * 60 + (parts.minute ?? 30)
        }
    }
}

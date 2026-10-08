import RijiKit
import RijiUI
import SwiftUI
import UserNotifications

@main
struct RijiApp: App {
    @State private var model = AppBootstrap.makeModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if AppBootstrap.flatLayout { FlatSnapshotLayout() } else { RootView() }
            }
                .environment(model)
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 600)
                #endif
                .task {
                    #if os(macOS)
                    Snapshotter.runIfRequested()
                    #endif
                    if !AppBootstrap.isDemo { await EveningReminder.schedule() }
                }
                .overlay(alignment: .bottom) {
                    if let error = model.lastError ?? AppBootstrap.openError {
                        Text(error)
                            .font(.system(size: 12))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.red.opacity(0.12), in: Capsule())
                            .padding(16)
                    }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("回到今天") { model.open(model.today) }.keyboardShortcut("t", modifiers: .command)
                Button("时间线") { model.route = .timeline }.keyboardShortcut("1", modifiers: .command)
                Button("进度") { model.route = .progress }.keyboardShortcut("2", modifiers: .command)
            }
        }
        #endif
    }
}

@MainActor
enum AppBootstrap {
    static var isDemo: Bool { ProcessInfo.processInfo.environment["RIJI_DEMO"] == "1" }
    /// 开发截图：RIJI_LAYOUT=flat 用不透明的平铺三栏；RIJI_ROUTE=timeline|progress 打开对应页面。
    static var flatLayout: Bool { ProcessInfo.processInfo.environment["RIJI_LAYOUT"] == "flat" }
    static var openError: String?

    static func makeModel() -> RijiModel {
        #if os(macOS)
        if let appearance = ProcessInfo.processInfo.environment["RIJI_APPEARANCE"] {
            NSApplication.shared.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        #endif
        if isDemo {
            let model = RijiModel.preview()
            switch ProcessInfo.processInfo.environment["RIJI_ROUTE"] {
            case "timeline": model.route = .timeline
            case "progress": model.route = .progress
            default: break
            }
            return model
        }
        do {
            return try RijiModel.openDefault()
        } catch {
            openError = "打不开本机数据（\(error.localizedDescription)），现在的修改不会被保存。"
            return .preview(seed: false)
        }
    }
}

/// 每晚 22:30 的本地提醒（不经过任何服务器，荣耀手机那边同理用本地闹钟）。
enum EveningReminder {
    static let identifier = "riji.evening"

    static func schedule(hour: Int = 22, minute: Int = 30) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "今晚总结"
        content.body = "今天过得怎么样？花一分钟勾掉做完的事，写一句话。"
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: minute), repeats: true)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}

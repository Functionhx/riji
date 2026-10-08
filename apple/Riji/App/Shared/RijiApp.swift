import RijiKit
import RijiUI
import SwiftUI

@main
struct RijiApp: App {
    @State private var model = AppBootstrap.makeModel()
    @AppStorage(ReminderSettings.enabledKey) private var reminderOn = ReminderSettings.defaultEnabled
    @AppStorage(ReminderSettings.minutesKey) private var reminderMinutes = ReminderSettings.defaultMinutes

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
                    if !AppBootstrap.isDemo { await EveningReminder.requestAuthorization() }
                }
                // 内容或提醒设置一变就重排晚间提醒（task(id:) 会取消上一次，相当于防抖）
                .task(id: ReminderKey(revision: model.revision, enabled: reminderOn, minutes: reminderMinutes)) {
                    guard !AppBootstrap.isDemo else { return }
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    await MailReminder.shared.report(book: model.book, today: model.today,
                                                     device: UserDefaults.standard.string(forKey: "riji.device") ?? "mac")
                    await EveningReminder.reschedule(book: model.book, today: model.today, now: model.currentDate)
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
        #if os(macOS)
        Settings {
            ReminderSettingsView().frame(width: 480)
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

private struct ReminderKey: Hashable {
    var revision: Int
    var enabled: Bool
    var minutes: Int
}

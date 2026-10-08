import RijiKit
import RijiUI
import SwiftUI

@main
struct RijiApp: App {
    @State private var model: RijiModel
    private let coordinator: ReminderCoordinator?

    init() {
        let model = AppBootstrap.makeModel()
        _model = State(initialValue: model)
        coordinator = AppBootstrap.isDemo ? nil : ReminderCoordinator(model: model)
    }

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
            // RIJI_NOW=2026-10-08T15:20:00+08:00：截图用的固定时刻
            let now = ProcessInfo.processInfo.environment["RIJI_NOW"].flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
            let model = RijiModel.preview(now: now)
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

/// 晚间提醒与邮件上报的总管：跟窗口无关（窗口关了、应用还在程序坞里时照常工作）。
/// 内容、提醒设置或连接码一变，一秒后上报今天并重排通知（连续变化只做最后一次）；每分钟检查一次是否跨过了分界线。
@MainActor
final class ReminderCoordinator {
    private let model: RijiModel
    private var pending: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?

    init(model: RijiModel) {
        self.model = model
        observe()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.model.refreshDay()
            }
        }
        schedule()
    }

    private func observe() {
        withObservationTracking {
            _ = model.revision
            _ = MailReminder.shared.version
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.schedule()
                self?.observe()
            }
        }
    }

    private var lastSettings: [Int] = []

    private func settingsChanged() {
        let settings = [ReminderSettings.enabled ? 1 : 0, ReminderSettings.minutes, ReminderSettings.dayStart]
        guard settings != lastSettings else { return }
        lastSettings = settings
        model.setDayStart(ReminderSettings.dayStart)
        schedule()
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [model] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await MailReminder.shared.report(book: model.book, today: model.today,
                                             device: UserDefaults.standard.string(forKey: "riji.device") ?? "mac")
            await EveningReminder.reschedule(book: model.book, today: model.today, now: model.currentDate)
        }
    }
}

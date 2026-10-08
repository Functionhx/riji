import AppKit

/// 开发用：`RIJI_SNAPSHOT=/tmp/x.png RIJI_DEMO=1 日迹.app/Contents/MacOS/日迹`
/// 窗口布局完成后把内容视图渲染成 PNG 然后退出。用的是视图自己的绘制（cacheDisplay），
/// 不需要屏幕录制权限，输入框等 AppKit 控件也会画出来。
@MainActor
enum Snapshotter {
    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["RIJI_SNAPSHOT"] else { return }
        FileHandle.standardError.write(Data("snapshot requested: \(path)\n".utf8))
        let size = environment["RIJI_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap { Double($0) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            FileHandle.standardError.write(Data("windows: \(NSApplication.shared.windows.count)\n".utf8))
            guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }) ?? NSApplication.shared.windows.first else { exit(2) }
            if let size, size.count == 2 { window.setContentSize(NSSize(width: size[0], height: size[1])) }
            try? await Task.sleep(for: .milliseconds(1200))
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(3) }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { exit(4) }
            // 沙盒里写不了任意路径时，退回应用容器的临时目录，并把实际路径打到标准错误。
            var target = URL(fileURLWithPath: path)
            do { try png.write(to: target) } catch {
                target = FileManager.default.temporaryDirectory.appendingPathComponent(target.lastPathComponent)
                try? png.write(to: target)
            }
            FileHandle.standardError.write(Data("snapshot written: \(target.path)\n".utf8))
            exit(0)
        }
    }
}

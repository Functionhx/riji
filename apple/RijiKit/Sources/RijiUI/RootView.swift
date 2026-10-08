import RijiKit
import SwiftUI

/// 主窗口：侧栏（今天 / 时间线 / 进行中 / 月份）· 正文 · 右栏（热力图 / 进度 / 网站）。
public struct RootView: View {
    @Environment(RijiModel.self) private var model
    @State private var showRail = true

    public init() {}

    public var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch model.route {
                case .day: DayPageView(date: model.selectedDate).id(model.selectedDate)
                case .timeline: TimelineView()
                case .progress: ProgressBoard()
                }
            }
            .inspector(isPresented: $showRail) {
                Rail().inspectorColumnWidth(min: 240, ideal: 270, max: 320)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showRail.toggle() } label: { Image(systemName: "sidebar.right") }
                        .help(showRail ? "收起右栏" : "展开右栏")
                }
            }
        }
        .tint(Ink.ink)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                model.refreshDay()
            }
        }
    }
}

/// 截图用的平铺布局：三栏都画成不透明（系统玻璃侧栏用视图自绘截不到）。只在开发截图时使用。
public struct FlatSnapshotLayout: View {
    @Environment(RijiModel.self) private var model
    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            Sidebar().frame(width: 220)
            Rectangle().fill(Ink.line).frame(width: 1)
            Group {
                switch model.route {
                case .day: DayPageView(date: model.selectedDate)
                case .timeline: TimelineView()
                case .progress: ProgressBoard()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Ink.line).frame(width: 1)
            Rail().frame(width: 270)
        }
        .background(Ink.paper)
    }
}

// ---------------------------------------------------------------- 侧栏

struct Sidebar: View {
    @Environment(RijiModel.self) private var model

    var body: some View {
        let todayStats = model.stats(on: model.today)
        List {
            Section {
                row("今天", detail: "\(todayStats.done)/\(todayStats.total)", selected: model.route == .day && model.selectedDate == model.today) {
                    model.open(model.today)
                }
                row("时间线", detail: "\(model.days.count)", selected: model.route == .timeline) { model.route = .timeline }
                row("进度", detail: "\(model.progresses.count)", selected: model.route == .progress) { model.route = .progress }
            } header: {
                HStack(spacing: 4) {
                    Text("ƒ").font(Typeface.serif(18)).italic().foregroundStyle(Ink.ochre)
                    Text("日迹").font(Typeface.serif(18)).foregroundStyle(Ink.ink)
                }
                .padding(.bottom, 6)
            }
            if !model.progresses.isEmpty {
                Section {
                    ForEach(model.progresses.prefix(6)) { progress in
                        row(progress.name, detail: progress.target.map { "\(progress.current)/\($0)" } ?? "\(progress.current) \(progress.unit)",
                            selected: false) { model.route = .progress }
                    }
                } header: { Eyebrow(text: "进行中", size: 10.5) }
            }
            Section {
                ForEach(months, id: \.key) { month in
                    row(month.title, detail: "\(month.count)", selected: false) {
                        if let first = month.firstDate { model.open(first) }
                    }
                }
            } header: { Eyebrow(text: "月份", size: 10.5) }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Ink.paper2)
    }

    private struct Month { var key: String; var title: String; var count: Int; var firstDate: String? }

    private var months: [Month] {
        let groups = Dictionary(grouping: model.days.filter { model.stats(on: $0.date).hasContent || $0.date == model.today }) { String($0.date.prefix(7)) }
        return groups.keys.sorted(by: >).map { key in
            let parts = key.split(separator: "-")
            return Month(key: key, title: "\(parts[0]) · \(parts[1])", count: groups[key]!.count, firstDate: groups[key]!.map(\.date).max())
        }
    }

    private func row(_ title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(Typeface.body(13.5, weight: selected ? .semibold : .regular)).foregroundStyle(selected ? Ink.ink : Ink.ink2)
                Spacer()
                Text(detail).font(Typeface.mono(11)).foregroundStyle(Ink.ink3)
            }
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(selected ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
    }
}

// ---------------------------------------------------------------- 右栏

struct Rail: View {
    @Environment(RijiModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Eyebrow(text: "今年")
                        Spacer()
                        Text("连续 \(model.streak) 天").font(Typeface.mono(11)).foregroundStyle(Ink.ink2)
                    }
                    Heatmap(levels: model.heatmap, today: model.today, clock: model.book.clock, weeks: 22) { date in model.open(date) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "进度")
                    if model.progresses.isEmpty {
                        Text("写「电路 18 讲」这样的任务，就会自动出现在这里。").font(Typeface.body(12.5)).foregroundStyle(Ink.ink3)
                    }
                    ForEach(model.progresses.prefix(5)) { progress in ProgressLine(progress: progress) }
                }
                SiteCard()
            }
            .padding(22)
        }
        .background(Ink.paper)
    }
}

struct ProgressLine: View {
    let progress: ProgressItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(progress.name).font(Typeface.body(13)).foregroundStyle(Ink.ink)
                Spacer()
                Text(progress.target.map { "\(progress.current)/\($0) \(progress.unit)" } ?? "\(progress.current) \(progress.unit)")
                    .font(Typeface.mono(11)).foregroundStyle(Ink.ink3)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.line)
                    Capsule().fill(Ink.ink).frame(width: proxy.size.width * (progress.fraction ?? 0))
                }
            }
            .frame(height: 3)
        }
    }
}

struct SiteCard: View {
    @Environment(RijiModel.self) private var model

    var body: some View {
        let stats = model.stats(on: model.today)
        VStack(alignment: .leading, spacing: 6) {
            Text("网站上公开").font(Typeface.body(12.5, weight: .semibold)).foregroundStyle(Ink.ink)
            Text("今日 \(stats.done)/\(stats.total) · 连续 \(model.streak) 天" + (publicProgress.map { " · \($0)" } ?? ""))
                .font(Typeface.body(12.5)).foregroundStyle(Ink.ink2)
            Text("内容不公开，只公开这几个数字。一键同步在下一阶段开放。").font(Typeface.body(11.5)).foregroundStyle(Ink.ink3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private var publicProgress: String? {
        model.progresses.first(where: \.isPublic).map { p in p.target.map { "\(p.name) \(p.current)/\($0)" } ?? "\(p.name) \(p.current)" }
    }
}

/// 一年的格子：每列一周，今天描赭色边；点一格打开那一天。
struct Heatmap: View {
    let levels: [String: Int]
    let today: String
    let clock: DayClock
    var weeks: Int = 22
    var cell: CGFloat = 9
    var open: (String) -> Void = { _ in }

    var body: some View {
        let start = startDate
        HStack(alignment: .top, spacing: 2.5) {
            ForEach(0..<weeks, id: \.self) { week in
                VStack(spacing: 2.5) {
                    ForEach(0..<7, id: \.self) { weekday in
                        let date = clock.adding(days: week * 7 + weekday, to: start)
                        if date > today {
                            Color.clear.frame(width: cell, height: cell)
                        } else {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Ink.heat(levels[date] ?? 0))
                                .frame(width: cell, height: cell)
                                .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(date == today ? Ink.ochre : .clear, lineWidth: 1.5).padding(-1.5))
                                .help("\(clock.title(for: date))")
                                .onTapGesture { open(date) }
                        }
                    }
                }
            }
        }
    }

    /// 从 (weeks-1) 周前的星期一开始，让今天落在最后一列。
    private var startDate: String {
        let weekdayIndex = ["星期一": 0, "星期二": 1, "星期三": 2, "星期四": 3, "星期五": 4, "星期六": 5, "星期日": 6][clock.weekday(for: today)] ?? 0
        return clock.adding(days: -(weeks - 1) * 7 - weekdayIndex, to: today)
    }
}

// ---------------------------------------------------------------- 时间线与进度页

struct TimelineView: View {
    @Environment(RijiModel.self) private var model

    var body: some View {
        let days = model.days.filter { model.stats(on: $0.date).hasContent || $0.date == model.today }
        List {
            ForEach(Dictionary(grouping: days) { String($0.date.prefix(7)) }.sorted { $0.key > $1.key }, id: \.key) { month, items in
                Section {
                    ForEach(items.sorted { $0.date > $1.date }) { day in
                        Button { model.open(day.date) } label: { TimelineRow(day: day) }.buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 0, leading: 44, bottom: 0, trailing: 44))
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text(month.replacingOccurrences(of: "-", with: " · ")).font(Typeface.serif(20)).foregroundStyle(Ink.ink)
                        .padding(.top, 10).padding(.leading, 30)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Ink.paper)
    }
}

struct TimelineRow: View {
    @Environment(RijiModel.self) private var model
    let day: Day

    var body: some View {
        let clock = model.book.clock
        let stats = model.stats(on: day.date)
        let preview = (model.items(.spark, on: day.date).first?.text.plain).map { "Spark · \($0)" }
            ?? model.items(.todo, on: day.date).first?.text.plain ?? model.notes(on: day.date)
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(day.date.suffix(5).replacingOccurrences(of: "-", with: "")).font(Typeface.serif(20)).foregroundStyle(Ink.ink).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(day.date == model.today ? "今天" : clock.weekday(for: day.date)).font(Typeface.body(13, weight: .medium)).foregroundStyle(Ink.ink2)
                Text(preview).font(Typeface.body(13)).foregroundStyle(Ink.ink3).lineLimit(1)
            }
            Spacer()
            Text("\(stats.done)/\(stats.total)").font(Typeface.mono(11)).foregroundStyle(Ink.ink3)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

struct ProgressBoard: View {
    @Environment(RijiModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("进度").font(Typeface.serif(32)).foregroundStyle(Ink.ink)
                Text("写「电路 18 讲」「马原 第 6 章」这样的任务会自动归到这里；勾选时进度推进。").font(Typeface.body(13)).foregroundStyle(Ink.ink3)
                ForEach(model.progresses) { progress in ProgressEditor(progress: progress) }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(44)
            .frame(maxWidth: .infinity)
        }
        .background(Ink.paper)
    }
}

struct ProgressEditor: View {
    @Environment(RijiModel.self) private var model
    let progress: ProgressItem
    @State private var target = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressLine(progress: progress)
            HStack(spacing: 14) {
                Stepper("当前 \(progress.current) \(progress.unit)", value: Binding(
                    get: { progress.current },
                    set: { value in var p = progress; p.current = max(0, value); model.perform { try model.book.updateProgress(p) } }))
                    .font(Typeface.body(12.5))
                HStack(spacing: 4) {
                    Text("目标").font(Typeface.body(12.5)).foregroundStyle(Ink.ink2)
                    TextField("—", text: $target).frame(width: 52).textFieldStyle(.roundedBorder)
                        .onSubmit { var p = progress; p.target = Int(target); model.perform { try model.book.updateProgress(p) } }
                }
                Toggle("公开到网站", isOn: Binding(
                    get: { progress.isPublic },
                    set: { value in var p = progress; p.isPublic = value; model.perform { try model.book.updateProgress(p) } }))
                    .font(Typeface.body(12.5))
                Spacer()
                Button("归档") { var p = progress; p.archived = true; model.perform { try model.book.updateProgress(p) } }
                    .buttonStyle(.plain).font(Typeface.body(12.5)).foregroundStyle(Ink.ink3)
            }
        }
        .padding(16)
        .background(Ink.paper2, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { target = progress.target.map(String.init) ?? "" }
    }
}

import RijiKit
import SwiftUI

/// 今天页（也是任意一天的页面）：日期、墨线、今日目标、Spark、随记，最后是今日总结与明日目标。
public struct DayPageView: View {
    @Environment(RijiModel.self) private var model
    @AppStorage("riji.backfill.dismissed") private var dismissedBackfill = ""
    @AppStorage(ReminderSettings.enabledKey) private var reminderOn = ReminderSettings.defaultEnabled
    @AppStorage(ReminderSettings.minutesKey) private var reminderMinutes = ReminderSettings.defaultMinutes
    let date: String

    public init(date: String) { self.date = date }

    public var body: some View {
        let clock = model.book.clock
        let isToday = date == model.today
        let stats = model.stats(on: date)
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(clock: clock, isToday: isToday, stats: stats)
                if isToday {
                    if let missed = model.missedEvening, missed != dismissedBackfill {
                        BackfillBanner(date: missed) { dismissedBackfill = missed }.padding(.top, 16)
                    }
                    InkLine(progress: clock.dayProgress(at: model.currentDate), now: model.currentDate, timeZone: clock.timeZone,
                            reminder: reminderOn ? reminderMinutes : nil)
                        .padding(.top, 18)
                }
                TodoSection(date: date, isToday: isToday, stats: stats).padding(.top, 30)
                SparkSection(date: date).padding(.top, 30)
                NotesSection(date: date).padding(.top, 30)
                EveningCard(date: date, isToday: isToday).padding(.top, 34).id("evening")
                Spacer(minLength: 60)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 44)
            .padding(.top, 34)
            .frame(maxWidth: .infinity)
        }
        .background(Ink.paper)
        .scrollContentBackground(.hidden)
        .onAppear {
            // 开发截图：RIJI_SCROLL=evening 直接滚到晚间卡
            if ProcessInfo.processInfo.environment["RIJI_SCROLL"] == "evening" { reader.scrollTo("evening", anchor: .bottom) }
        }
        }
    }

    @ViewBuilder
    private func header(clock: DayClock, isToday: Bool, stats: DayStats) -> some View {
        let streak = model.streak
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: date.replacingOccurrences(of: "-", with: " · ") + " · " + weekdayCode(clock.weekday(for: date))
                    + (isToday && streak > 1 ? " · 连续 \(streak) 天" : ""))
            Text(clock.title(for: date))
                .font(Typeface.serif(40))
                .foregroundStyle(Ink.ink)
            Text(subtitle(clock: clock, isToday: isToday))
                .font(Typeface.body(14))
                .foregroundStyle(Ink.ink2)
        }
    }

    private func subtitle(clock: DayClock, isToday: Bool) -> String {
        let weekday = clock.weekday(for: date)
        guard isToday else {
            let gap = clock.daysBetween(date, model.today)
            return gap > 0 ? "\(weekday) · \(gap) 天前" : weekday
        }
        let minutes = clock.minutesLeft(at: model.currentDate)
        return "\(weekday) · 今天还剩 \(minutes / 60) 小时 \(minutes % 60) 分"
    }

    private func weekdayCode(_ weekday: String) -> String {
        ["星期日": "SUN", "星期一": "MON", "星期二": "TUE", "星期三": "WED", "星期四": "THU", "星期五": "FRI", "星期六": "SAT"][weekday] ?? ""
    }
}

/// 墨线：06:00–24:00 的进度，赭色圆点是「现在」。
struct InkLine: View {
    var progress: Double
    var now: Date
    var timeZone: TimeZone
    /// 晚间提醒的时刻（分钟），在墨线上画一道赭色短刻度。
    var reminder: Int? = nil

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let x = proxy.size.width * progress
                ZStack(alignment: .leading) {
                    Rectangle().fill(Ink.line).frame(height: 2)
                    Rectangle().fill(Ink.ink).frame(width: x, height: 2)
                    if let reminder, reminder >= 6 * 60 {
                        Rectangle().fill(Ink.ochreSoft).frame(width: 2, height: 10)
                            .offset(x: proxy.size.width * Double(reminder - 6 * 60) / (18 * 60) - 1)
                            .help("\(ReminderSettings.label(reminder)) 晚间提醒")
                    }
                    Circle().fill(Ink.ochre).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Ink.paper, lineWidth: 3))
                        .offset(x: x - 5)
                }
                .frame(height: 10)
            }
            .frame(height: 10)
            HStack {
                Text("06:00")
                Spacer()
                Text("现在 \(timeText)")
                Spacer()
                Text("24:00")
            }
            .font(Typeface.mono(10.5))
            .foregroundStyle(Ink.ink3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今天已过去 \(Int(progress * 100))%")
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: now)
    }
}

/// 区块标题：等宽小标签 + 右侧计数 + 一条细线。
struct SectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: title)
                Spacer()
                trailing
            }
            Rectangle().fill(Ink.line).frame(height: 1)
        }
    }
}

// ---------------------------------------------------------------- TODO

struct TodoSection: View {
    @Environment(RijiModel.self) private var model
    let date: String
    let isToday: Bool
    let stats: DayStats
    @State private var draft = ""
    @FocusState private var focused: String?

    var body: some View {
        let items = model.items(.todo, on: date)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: isToday ? "今日目标" : "当天目标") {
                Text("\(stats.done) / \(stats.total)").font(Typeface.mono(11)).foregroundStyle(Ink.ink2)
            }
            ForEach(items) { item in
                TaskRow(item: item, date: date, focused: $focused)
            }
            HStack(spacing: 12) {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.ink3)
                    .frame(width: 20, height: 20)
                TextField("", text: $draft, prompt: Text("添加一件事，回车继续").foregroundStyle(Ink.ink3))
                    .textFieldStyle(.plain)
                    .font(Typeface.body(15))
                    .foregroundStyle(Ink.ink)
                    .focused($focused, equals: "new-\(date)")
                    .onSubmit(addDraft)
            }
            .padding(.vertical, 9)
        }
    }

    private func addDraft() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        model.perform { try model.book.add(.check, text: text, to: .todo, on: date, now: model.currentDate) }
        draft = ""
        focused = "new-\(date)"
    }
}

struct TaskRow: View {
    @Environment(RijiModel.self) private var model
    let item: Block
    let date: String
    var focused: FocusState<String?>.Binding
    @State private var text = ""

    var body: some View {
        let carriedAway = (item.carriedTo != nil || item.dropped) && !item.checked
        HStack(spacing: 12) {
            CheckCircle(checked: item.checked) {
                model.perform { try model.book.setChecked(!item.checked, of: item.id) }
            }
            .disabled(carriedAway)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Typeface.body(15))
                .foregroundStyle(item.checked || carriedAway ? Ink.ink3 : Ink.ink)
                .strikethrough(item.checked, color: Ink.line)
                .focused(focused, equals: item.id)
                .onSubmit(commit)
                .onChange(of: focused.wrappedValue) { old, _ in if old == item.id { commit() } }
            if carriedAway {
                Text(item.dropped ? "已放下" : "已延续 →").font(Typeface.mono(10.5)).foregroundStyle(Ink.ink3)
            }
            if item.plannedFrom != nil, item.carryFrom == nil {
                Text("昨日定")
                    .font(Typeface.mono(10.5))
                    .foregroundStyle(Ink.ink2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Ink.paper2, in: RoundedRectangle(cornerRadius: 4))
                    .help("前一天晚上写在「明日目标」里的")
            }
            if item.carryFrom != nil, item.carriedDays > 0 {
                Text("↻ \(item.carriedDays) 天")
                    .font(Typeface.mono(11))
                    .foregroundStyle(Ink.ochre)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Ink.ochreSoft))
                    .help("从前面的日子带过来的")
            }
            if let progress = model.progress(item.progressID) {
                HStack(spacing: 6) {
                    if let fraction = progress.fraction { GlyphMeter(fraction: fraction) }
                    Text(progress.target.map { "\(progress.current)/\($0)" } ?? "\(progress.current) \(progress.unit)")
                        .font(Typeface.mono(11)).foregroundStyle(Ink.ink2)
                }
            }
            if item.attrs["from_spark"] != nil {
                Text("← Spark").font(Typeface.mono(10.5)).foregroundStyle(Ink.ink3)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onAppear { text = item.text.plain }
        .onChange(of: item.text.plain) { _, new in if focused.wrappedValue != item.id { text = new } }
        .contextMenu {
            Button(item.checked ? "标为未完成" : "标为完成") { model.perform { try model.book.setChecked(!item.checked, of: item.id) } }
            Divider()
            Button(item.carryFrom != nil ? "不做了（不再延续）" : "删除", role: .destructive) { model.perform { try model.book.delete(item.id) } }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            model.perform { try model.book.delete(item.id) }
        } else if trimmed != item.text.plain {
            model.perform { try model.book.setText(trimmed, of: item.id) }
        }
    }
}

/// 圆形勾选：未完成是描边，完成是墨色实心加白勾。
struct CheckCircle: View {
    var checked: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(checked ? Ink.ink : Ink.ink3, lineWidth: 1.5)
                if checked {
                    Circle().fill(Ink.ink)
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.paper)
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(checked ? "已完成" : "未完成")
        .animation(.easeOut(duration: 0.12), value: checked)
    }
}

// ---------------------------------------------------------------- 随记

struct NotesSection: View {
    @Environment(RijiModel.self) private var model
    let date: String
    @State private var text = ""
    @State private var loadedFor = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "随记") { EmptyView() }
            TextEditor(text: $text)
                .font(Typeface.serif(16, weight: .regular))
                .foregroundStyle(Ink.ink2)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(minHeight: 80)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("今天想到的、看到的，随手写下来")
                            .font(Typeface.serif(16, weight: .regular)).foregroundStyle(Ink.ink3)
                            .padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .onChange(of: text) { _, new in
                    guard loadedFor == date, new != model.book.notes(on: date) else { return }
                    model.perform { try model.book.setNotes(new, on: date, now: model.currentDate) }
                }
        }
        .onAppear(perform: load)
        .onChange(of: date) { _, _ in load() }
    }

    private func load() {
        loadedFor = ""
        text = model.notes(on: date)
        loadedFor = date
    }
}

// ---------------------------------------------------------------- 今日总结 · 明日目标

/// 一天的收尾：一句总结，加上明天要做的事。明日目标在第二天自动成为那天的今日目标。
/// 过去的日子也显示，方便补写。
struct EveningCard: View {
    @Environment(RijiModel.self) private var model
    @AppStorage(ReminderSettings.enabledKey) private var reminderOn = ReminderSettings.defaultEnabled
    @AppStorage(ReminderSettings.minutesKey) private var reminderMinutes = ReminderSettings.defaultMinutes
    let date: String
    let isToday: Bool
    @State private var summary = ""
    @State private var loadedFor = ""
    @State private var draft = ""
    @FocusState private var focused: String?

    var body: some View {
        let evening = model.evening(on: date)
        let stats = evening.stats
        let clock = model.book.clock
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: isToday ? "今日总结" : "当天总结")
                Spacer()
                Text("完成 \(stats.done) · 延续 \(stats.carried) · Spark \(stats.sparks)")
                    .font(Typeface.mono(11)).foregroundStyle(Ink.ink2)
            }
            TextField("", text: $summary, prompt: Text(isToday ? "用一句话记下今天" : "补一句那天的总结").foregroundStyle(Ink.ink3), axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typeface.serif(16, weight: .regular))
                .foregroundStyle(Ink.ink)
                .focused($focused, equals: "summary")
                .padding(.top, 10)
                .onChange(of: summary) { _, new in
                    guard loadedFor == date, new != model.book.day(date)?.summary else { return }
                    model.perform { try model.book.setSummary(new, on: date) }
                }

            DashedRule().padding(.vertical, 16)

            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: isToday ? "明日目标" : "次日目标")
                Spacer()
                Text(isToday ? "明早出现在今日目标里" : "排进 \(clock.title(for: clock.adding(days: 1, to: date)))")
                    .font(Typeface.mono(10.5)).foregroundStyle(Ink.ink3)
            }
            .padding(.bottom, 4)
            ForEach(model.items(.tomorrow, on: date)) { item in
                PlanRow(item: item, focused: $focused)
            }
            HStack(spacing: 12) {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.ink3)
                    .frame(width: 20, height: 20)
                TextField("", text: $draft, prompt: Text("明天想做的事，回车继续").foregroundStyle(Ink.ink3))
                    .textFieldStyle(.plain)
                    .font(Typeface.body(15))
                    .foregroundStyle(Ink.ink)
                    .focused($focused, equals: "new-plan")
                    .onSubmit(addDraft)
            }
            .padding(.vertical, 8)
            if isToday, evening.pending > 0 {
                Text("另有 \(evening.pending) 件没做完，会自动延续，不用再写一遍。")
                    .font(Typeface.body(12)).foregroundStyle(Ink.ink3)
                    .padding(.top, 2)
            }

            if isToday {
                HStack(spacing: 10) {
                    if !evening.missing.isEmpty {
                        Text("还差：" + evening.missing.joined(separator: " · "))
                            .foregroundStyle(Ink.ochre)
                    } else {
                        Text("今天收好了").foregroundStyle(Ink.ink2)
                    }
                    Spacer()
                    reminderLabel
                }
                .font(Typeface.mono(11))
                .padding(.top, 14)
                HStack(spacing: 6) {
                    Image(systemName: "globe").font(.system(size: 11))
                    Text("网站上将公开：今日 \(stats.done)/\(stats.total) · 连续 \(model.streak) 天（同步上线后可发布）")
                }
                .font(Typeface.body(12)).foregroundStyle(Ink.ink3)
                .padding(.top, 8)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .onAppear(perform: load)
        .onChange(of: date) { _, _ in load() }
    }

    @ViewBuilder
    private var reminderLabel: some View {
        let label = Label(reminderOn ? "\(ReminderSettings.label(reminderMinutes)) 提醒" : "提醒已关", systemImage: "bell")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Ink.ink3)
        #if os(macOS)
        SettingsLink { label }.buttonStyle(.plain).help("更改提醒时间")
        #else
        label
        #endif
    }

    private func load() {
        loadedFor = ""
        summary = model.book.day(date)?.summary ?? ""
        loadedFor = date
    }

    private func addDraft() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        model.perform { try model.book.add(.check, text: text, to: .tomorrow, on: date, now: model.currentDate) }
        draft = ""
        focused = "new-plan"
    }
}

/// 一条明日目标：左边是箭头（它还不是任务，明天才是）；排进第二天后标「已排进」。
struct PlanRow: View {
    @Environment(RijiModel.self) private var model
    let item: Block
    var focused: FocusState<String?>.Binding
    @State private var text = ""

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Ink.ochre)
                .frame(width: 20, height: 20)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Typeface.body(15))
                .foregroundStyle(Ink.ink)
                .focused(focused, equals: item.id)
                .onSubmit(commit)
                .onChange(of: focused.wrappedValue) { old, _ in if old == item.id { commit() } }
            if item.plannedTo != nil {
                Text("已排进 →").font(Typeface.mono(10.5)).foregroundStyle(Ink.ink3)
                    .help("已经出现在第二天的目标里")
            }
            if let progress = model.progress(item.progressID) {
                Text(progress.target.map { "\(progress.current)/\($0)" } ?? "\(progress.current) \(progress.unit)")
                    .font(Typeface.mono(11)).foregroundStyle(Ink.ink2)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onAppear { text = item.text.plain }
        .onChange(of: item.text.plain) { _, new in if focused.wrappedValue != item.id { text = new } }
        .contextMenu {
            Button("删除", role: .destructive) { model.perform { try model.book.delete(item.id) } }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            model.perform { try model.book.delete(item.id) }
        } else if trimmed != item.text.plain {
            model.perform { try model.book.setText(trimmed, of: item.id) }
        }
    }
}

/// 卡片里的虚线分隔。
struct DashedRule: View {
    var body: some View {
        Line().stroke(Ink.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])).frame(height: 1)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { $0.move(to: CGPoint(x: 0, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
        }
    }
}

/// 早上：昨天写过东西却没写总结时，今天页顶部的一条细横幅。
struct BackfillBanner: View {
    @Environment(RijiModel.self) private var model
    let date: String
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Ink.ochre).frame(width: 6, height: 6)
            Text("\(model.book.clock.title(for: date))的总结还没写")
                .font(Typeface.body(13)).foregroundStyle(Ink.ink2)
            Button("补写 →") { model.open(date) }
                .buttonStyle(.plain)
                .font(Typeface.body(13, weight: .medium)).foregroundStyle(Ink.ochre)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Ink.ink3)
                .help("今天不再提示")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Ink.paper2, in: RoundedRectangle(cornerRadius: 8))
    }
}

import RijiKit
import SwiftUI

/// 今天页（也是任意一天的页面）：日期、墨线、TODO、Spark、随记、晚间总结。
public struct DayPageView: View {
    @Environment(RijiModel.self) private var model
    let date: String

    public init(date: String) { self.date = date }

    public var body: some View {
        let clock = model.book.clock
        let isToday = date == model.today
        let stats = model.stats(on: date)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(clock: clock, isToday: isToday, stats: stats)
                if isToday {
                    InkLine(progress: clock.dayProgress(at: model.currentDate), now: model.currentDate, timeZone: clock.timeZone)
                        .padding(.top, 18)
                }
                TodoSection(date: date, stats: stats).padding(.top, 30)
                SparkSection(date: date).padding(.top, 30)
                NotesSection(date: date).padding(.top, 30)
                if isToday { EveningCard(date: date, stats: stats).padding(.top, 34) }
                Spacer(minLength: 60)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 44)
            .padding(.top, 34)
            .frame(maxWidth: .infinity)
        }
        .background(Ink.paper)
        .scrollContentBackground(.hidden)
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

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let x = proxy.size.width * progress
                ZStack(alignment: .leading) {
                    Rectangle().fill(Ink.line).frame(height: 2)
                    Rectangle().fill(Ink.ink).frame(width: x, height: 2)
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
    let stats: DayStats
    @State private var draft = ""
    @FocusState private var focused: String?

    var body: some View {
        let items = model.items(.todo, on: date)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "TODO") {
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
        let carriedAway = item.carriedTo != nil && !item.checked
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
                Text("已延续 →").font(Typeface.mono(10.5)).foregroundStyle(Ink.ink3)
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

// ---------------------------------------------------------------- 晚间总结

struct EveningCard: View {
    @Environment(RijiModel.self) private var model
    let date: String
    let stats: DayStats
    @State private var summary = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "今晚总结")
            Text("完成 \(stats.done) · 延续 \(stats.carried) · Spark \(stats.sparks)")
                .font(Typeface.mono(12)).foregroundStyle(Ink.ink2)
            TextField("", text: $summary, prompt: Text("用一句话记下今天").foregroundStyle(Ink.ink3), axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typeface.serif(16, weight: .regular))
                .foregroundStyle(Ink.ink)
                .onSubmit { model.perform { try model.book.setSummary(summary, on: date) } }
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.system(size: 11))
                Text("网站上将公开：今日 \(stats.done)/\(stats.total) · 连续 \(model.streak) 天（同步上线后可发布）")
            }
            .font(Typeface.body(12)).foregroundStyle(Ink.ink3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .onAppear { summary = model.book.day(date)?.summary ?? "" }
    }
}

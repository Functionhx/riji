import RijiKit
import SwiftUI

/// Spark：一条一张便利贴，手写体、轻微倾斜、顶部一截胶带——和网站文章的便利贴同一种纸。
struct SparkSection: View {
    @Environment(RijiModel.self) private var model
    let date: String
    @State private var draft = ""
    @State private var adding = false
    @FocusState private var draftFocused: Bool

    var body: some View {
        let sparks = model.items(.spark, on: date)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "SPARK") {
                Text("\(sparks.count) 张").font(Typeface.mono(11)).foregroundStyle(Ink.ink2)
            }
            FlowLayout(spacing: 14) {
                ForEach(sparks) { spark in
                    StickyNote(spark: spark, date: date)
                }
                if adding {
                    StickyPaper(color: nextColor(sparks.count), tilt: 0.8) {
                        TextField("", text: $draft, prompt: Text("写下一个灵感").foregroundStyle(Ink.stickyInk.opacity(0.5)), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(Typeface.hand(15))
                            .foregroundStyle(Ink.stickyInk)
                            .focused($draftFocused)
                            .onSubmit(commitDraft)
                            .onChange(of: draftFocused) { _, focused in if !focused { commitDraft() } }
                    }
                } else {
                    Button {
                        adding = true
                        draftFocused = true
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 14))
                            Text("贴一张").font(Typeface.body(12))
                        }
                        .foregroundStyle(Ink.ink3)
                        .frame(width: 128, height: 96)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Ink.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
    }

    private func nextColor(_ count: Int) -> String { ["yellow", "pink", "mint", "blue"][count % 4] }

    private func commitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        adding = false
        draft = ""
        guard !text.isEmpty else { return }
        model.perform { try model.book.add(.spark, text: text, to: .spark, on: date, now: model.currentDate) }
    }
}

struct StickyNote: View {
    @Environment(RijiModel.self) private var model
    let spark: Block
    let date: String
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        StickyPaper(color: spark.color, tilt: tilt) {
            VStack(alignment: .leading, spacing: 8) {
                if editing {
                    TextField("", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Typeface.hand(15))
                        .foregroundStyle(Ink.stickyInk)
                        .focused($focused)
                        .onSubmit(commit)
                        .onChange(of: focused) { _, now in if !now { commit() } }
                } else {
                    Text(spark.text.plain)
                        .font(Typeface.hand(15))
                        .foregroundStyle(Ink.stickyInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text(timeLabel)
                    if spark.attrs["promoted_to"] != nil { Text("· 已转 TODO") }
                }
                .font(Typeface.mono(10))
                .foregroundStyle(Ink.stickyInk.opacity(0.55))
            }
        }
        .onTapGesture(count: 2) {
            text = spark.text.plain
            editing = true
            focused = true
        }
        .contextMenu {
            if spark.attrs["promoted_to"] == nil {
                Button("变成今天的 TODO") { model.perform { try model.book.promote(spark: spark.id, on: model.today, now: model.currentDate) } }
            }
            Button("改写") {
                text = spark.text.plain
                editing = true
                focused = true
            }
            Menu("换颜色") {
                ForEach([("yellow", "黄"), ("pink", "粉"), ("mint", "薄荷"), ("blue", "雾蓝")], id: \.0) { color in
                    Button(color.1) { model.perform { try model.book.setAttr("color", .string(color.0), of: spark.id) } }
                }
            }
            Divider()
            Button("撕掉", role: .destructive) { model.perform { try model.book.delete(spark.id) } }
        }
        .help("双击改写，右键变成 TODO 或换颜色")
    }

    /// 由 id 决定的轻微倾斜（±1.5°），同一张便利贴每次都一样。
    private var tilt: Double {
        let hash = spark.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Double(hash % 31 - 15) / 10
    }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.timeZone = model.book.clock.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: spark.createdAt)
    }

    private func commit() {
        editing = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            model.perform { try model.book.delete(spark.id) }
        } else if trimmed != spark.text.plain {
            model.perform { try model.book.setText(trimmed, of: spark.id) }
        }
    }
}

/// 便利贴的纸：颜色、阴影、胶带、倾斜。
struct StickyPaper<Content: View>: View {
    var color: String
    var tilt: Double
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 13).padding(.top, 16).padding(.bottom, 10)
            .frame(width: 136, alignment: .topLeading)
            .frame(minHeight: 96, alignment: .topLeading)
            .background(Ink.sticky(color))
            .shadow(color: .black.opacity(0.16), radius: 9, x: 0, y: 8)
            .overlay(alignment: .top) {
                Rectangle().fill(Ink.tape).frame(width: 46, height: 14).rotationEffect(.degrees(2)).offset(y: -7)
            }
            .rotationEffect(.degrees(tilt))
    }
}

/// 自动换行的横向排列（便利贴墙）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

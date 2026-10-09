package com.functionhx.riji

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.functionhx.riji.core.Block
import com.functionhx.riji.core.SectionRole
import kotlinx.coroutines.delay
import java.time.Instant
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter

@Composable
fun RijiApp(model: RijiViewModel) {
    val ink = LocalInk.current
    LaunchedEffect(Unit) { while (true) { delay(60_000); model.refreshDay() } }
    Column(Modifier.fillMaxSize().background(ink.paper)) {
        Box(Modifier.weight(1f)) {
            when (model.tab) {
                Tab.TODAY -> TodayScreen(model, model.selectedDate)
                Tab.TIMELINE -> TimelineScreen(model)
                Tab.PROGRESS -> ProgressScreen(model)
                Tab.ME -> MeScreen(model)
            }
        }
        model.error?.let { Text(it, style = body(12.sp, Color(0xFFB5443A)), modifier = Modifier.padding(12.dp)) }
        TabBar(model)
    }
}

@Composable
private fun TabBar(model: RijiViewModel) {
    val ink = LocalInk.current
    Column(Modifier.fillMaxWidth().background(ink.paper).navigationBarsPadding()) {
        Box(Modifier.fillMaxWidth().height(1.dp).background(ink.line))
        Row(Modifier.fillMaxWidth().height(60.dp), horizontalArrangement = Arrangement.SpaceAround, verticalAlignment = Alignment.CenterVertically) {
            for (tab in Tab.entries) {
                val on = model.tab == tab
                Column(
                    Modifier.clickable {
                        if (tab == Tab.TODAY) model.open(model.today) else model.tab = tab
                    }.padding(horizontal = 18.dp, vertical = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Box(Modifier.width(18.dp).height(3.dp).background(if (on) ink.ink else Color.Transparent, RoundedCornerShape(2.dp)))
                    Spacer(Modifier.height(5.dp))
                    Text(tab.title, style = body(12.sp, if (on) ink.ink else ink.ink3, if (on) FontWeight.SemiBold else FontWeight.Normal))
                }
            }
        }
    }
}

// ---------------------------------------------------------------- 今天

@Composable
fun TodayScreen(model: RijiViewModel, date: String) {
    val ink = LocalInk.current
    val clock = model.book.clock
    val isToday = date == model.today
    val stats = model.stats(date)
    val todos = model.items(SectionRole.TODO, date)
    val sparks = model.items(SectionRole.SPARK, date)
    var captureAsSpark by remember { mutableStateOf(false) }
    var dismissedBackfill by remember { mutableStateOf("") }
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        LazyColumn(Modifier.weight(1f).padding(horizontal = 24.dp)) {
            item {
                Spacer(Modifier.height(18.dp))
                val streak = model.streak()
                Eyebrow(date.replace("-", " · ") + (if (isToday && streak > 1) " · 连续 $streak 天" else ""))
                Spacer(Modifier.height(6.dp))
                Text(clock.title(date), style = serif(40.sp, ink.ink))
                val now = Instant.now()
                val subtitle = if (isToday && clock.isPastMidnight(now)) {
                    "${clock.weekday(date)} · 已过零点，${com.functionhx.riji.core.DayClock.label(clock.dayStart)} 前写的仍记在今天"
                } else if (isToday) {
                    val minutes = clock.minutesLeft(now)
                    "${clock.weekday(date)} · 今天还剩 ${minutes / 60} 小时 ${minutes % 60} 分"
                } else clock.weekday(date)
                Text(subtitle, style = body(14.sp, ink.ink2))
                if (isToday) {
                    model.missedEvening()?.takeIf { it != dismissedBackfill }?.let { missed ->
                        BackfillBanner(clock.title(missed), onOpen = { model.open(missed) }, onDismiss = { dismissedBackfill = missed })
                    }
                    InkLine(clock.dayProgress(now), ZonedDateTime.now(clock.zone).format(DateTimeFormatter.ofPattern("HH:mm")),
                        if (model.reminderOn) clock.inkPosition(model.reminderMinutes) else null)
                }
            }
            item { SectionHeader(if (isToday) "今日目标" else "当天目标", "${stats.done} / ${stats.total}") }
            items(todos, key = { it.id }) { TaskRow(model, it) }
            item { SectionHeader("SPARK", "${sparks.size} 张") }
            item { SparkWall(model, sparks) }
            item { NotesBlock(model, date) }
            item { EveningCard(model, date, isToday) }
            item { Spacer(Modifier.height(24.dp)) }
        }
        CaptureBar(asSpark = captureAsSpark, onToggle = { captureAsSpark = !captureAsSpark }) { text ->
            if (captureAsSpark) model.addSpark(text, date) else model.addTask(text, date)
        }
    }
}

@Composable
private fun InkLine(progress: Double, now: String, reminder: Double?) {
    val ink = LocalInk.current
    Column(Modifier.padding(top = 16.dp)) {
        Canvas(Modifier.fillMaxWidth().height(10.dp)) {
            val y = size.height / 2
            val x = size.width * progress.toFloat()
            drawLine(ink.line, Offset(0f, y), Offset(size.width, y), strokeWidth = 2.dp.toPx())
            drawLine(ink.ink, Offset(0f, y), Offset(x, y), strokeWidth = 2.dp.toPx())
            // 晚间提醒的时刻：一道赭色短刻度
            if (reminder != null && reminder > 0) {
                val rx = size.width * reminder.toFloat()
                drawLine(ink.ochreSoft, Offset(rx, 0f), Offset(rx, size.height), strokeWidth = 2.dp.toPx())
            }
            drawCircle(ink.paper, radius = 6.5.dp.toPx(), center = Offset(x, y))
            drawCircle(ink.ochre, radius = 5.dp.toPx(), center = Offset(x, y))
        }
        Row(Modifier.fillMaxWidth().padding(top = 6.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("06:00", style = mono(10.5.sp, ink.ink3)); Text("现在 $now", style = mono(10.5.sp, ink.ink3)); Text("24:00", style = mono(10.5.sp, ink.ink3))
        }
    }
}

@Composable
private fun SectionHeader(title: String, trailing: String) {
    val ink = LocalInk.current
    Column(Modifier.padding(top = 26.dp, bottom = 4.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Eyebrow(title)
            Text(trailing, style = mono(11.sp, ink.ink2))
        }
        Spacer(Modifier.height(6.dp))
        Box(Modifier.fillMaxWidth().height(1.dp).background(ink.line))
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TaskRow(model: RijiViewModel, item: Block) {
    val ink = LocalInk.current
    var editing by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    val carriedAway = (item.carriedTo != null || item.dropped) && !item.checked
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp)
            .combinedClickable(onClick = { if (!carriedAway) model.toggle(item.id, !item.checked) }, onLongClick = { menu = true }),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CheckCircle(item.checked)
        Spacer(Modifier.width(12.dp))
        Text(
            item.text, modifier = Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis,
            style = body(15.sp, if (item.checked || carriedAway) ink.ink3 else ink.ink)
                .copy(textDecoration = if (item.checked) TextDecoration.LineThrough else null),
        )
        if (carriedAway) Text(if (item.dropped) "已放下" else "已延续 →", style = mono(10.5.sp, ink.ink3))
        if (item.plannedFrom != null && item.carryFrom == null) {
            Text("昨日定", style = mono(10.5.sp, ink.ink2),
                modifier = Modifier.padding(start = 6.dp).background(ink.paper2, RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 1.dp))
        }
        if (item.carryFrom != null && item.carriedDays > 0) {
            Text("↻ ${item.carriedDays} 天", style = mono(11.sp, ink.ochre),
                modifier = Modifier.border(1.dp, ink.ochreSoft, RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 1.dp))
        }
        model.progress(item.progressId)?.let { progress ->
            Spacer(Modifier.width(8.dp))
            progress.fraction?.let { GlyphMeter(it) }
            Text(progress.target?.let { " ${progress.current}/$it" } ?: " ${progress.current} ${progress.unit}", style = mono(11.sp, ink.ink2))
        }
        if (item.attrs["from_spark"] != null) Text(" ← Spark", style = mono(10.5.sp, ink.ink3))
        if (!item.checked && !carriedAway) {
            val carry = model.willCarry(item)
            Text(if (carry) "→ 明天" else "→", style = mono(11.sp, if (carry) ink.ochre else ink.ink3.copy(alpha = 0.6f)),
                modifier = Modifier.padding(start = 6.dp)
                    .background(if (carry) ink.ochreSoft.copy(alpha = 0.35f) else Color.Transparent, RoundedCornerShape(4.dp))
                    .clickable { model.setCarry(item.id, !carry) }.padding(horizontal = 8.dp, vertical = 6.dp))
        }
        DropdownMenu(menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("改写") }, onClick = { menu = false; editing = true })
            if (!item.checked && !carriedAway) {
                val carry = model.willCarry(item)
                DropdownMenuItem(text = { Text(if (carry) "不带到明天" else "没做完就带到明天") }, onClick = { menu = false; model.setCarry(item.id, !carry) })
            }
            DropdownMenuItem(text = { Text(if (item.carryFrom != null) "不做了（不再延续）" else "删除") }, onClick = { menu = false; model.delete(item.id) })
        }
    }
    if (editing) EditDialog("改写", item.text, onDismiss = { editing = false }) { model.rename(item.id, it) }
}

/** 一条明日目标：箭头（它明天才是任务）；排进第二天后标「已排进」。轻点改写。 */
@Composable
private fun PlanRow(model: RijiViewModel, item: Block) {
    val ink = LocalInk.current
    var editing by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable { editing = true }, verticalAlignment = Alignment.CenterVertically) {
        Text("↳", style = body(15.sp, ink.ochre, FontWeight.Bold), modifier = Modifier.width(22.dp))
        Spacer(Modifier.width(12.dp))
        Text(item.text, modifier = Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis, style = body(15.sp, ink.ink))
        if (item.plannedTo != null) Text("已排进 →", style = mono(10.5.sp, ink.ink3))
        model.progress(item.progressId)?.let { progress ->
            Text(progress.target?.let { " ${progress.current}/$it" } ?: " ${progress.current} ${progress.unit}", style = mono(11.sp, ink.ink2))
        }
    }
    if (editing) EditDialog("改写（清空即删除）", item.text, onDismiss = { editing = false }) { model.rename(item.id, it) }
}

/** 早上：昨天写过东西却没写总结时，今天页顶部的一条细横幅。 */
@Composable
private fun BackfillBanner(title: String, onOpen: () -> Unit, onDismiss: () -> Unit) {
    val ink = LocalInk.current
    Row(
        Modifier.padding(top = 14.dp).fillMaxWidth().background(ink.paper2, RoundedCornerShape(8.dp)).clickable(onClick = onOpen)
            .padding(start = 14.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(6.dp).background(ink.ochre, CircleShape))
        Spacer(Modifier.width(10.dp))
        Text("${title}的总结还没写", style = body(13.sp, ink.ink2))
        Text("  补写 →", style = body(13.sp, ink.ochre, FontWeight.Medium))
        Spacer(Modifier.weight(1f))
        TextButton(onDismiss) { Text("×", style = body(15.sp, ink.ink3)) }
    }
}

@Composable
private fun CheckCircle(checked: Boolean) {
    val ink = LocalInk.current
    Canvas(Modifier.size(22.dp)) {
        if (checked) {
            drawCircle(ink.ink)
            val s = size.width
            drawLine(ink.paper, Offset(s * 0.3f, s * 0.52f), Offset(s * 0.45f, s * 0.66f), strokeWidth = 2.2.dp.toPx())
            drawLine(ink.paper, Offset(s * 0.45f, s * 0.66f), Offset(s * 0.72f, s * 0.36f), strokeWidth = 2.2.dp.toPx())
        } else {
            drawCircle(ink.ink3, style = Stroke(1.5.dp.toPx()))
        }
    }
}

@Composable
private fun GlyphMeter(fraction: Double, cells: Int = 9) {
    val ink = LocalInk.current
    val filled = (fraction * cells).toInt()
    Row {
        Text("▓".repeat(filled), style = mono(11.sp, ink.ink))
        Text("░".repeat(cells - filled), style = mono(11.sp, ink.ink3))
    }
}

@OptIn(ExperimentalLayoutApi::class, ExperimentalFoundationApi::class)
@Composable
private fun SparkWall(model: RijiViewModel, sparks: List<Block>) {
    val ink = LocalInk.current
    FlowRow(Modifier.fillMaxWidth().padding(top = 14.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        for (spark in sparks) {
            var menu by remember { mutableStateOf(false) }
            val tilt = ((spark.id.hashCode() and 0xFFFF) % 31 - 15) / 10f
            Box(Modifier.rotate(tilt)) {
                Column(
                    Modifier.width(138.dp).heightIn(min = 96.dp).shadow(6.dp).background(ink.sticky(spark.color))
                        .combinedClickable(onClick = { menu = true }, onLongClick = { menu = true })
                        .padding(start = 13.dp, end = 13.dp, top = 16.dp, bottom = 10.dp),
                ) {
                    Text(spark.text, style = serif(15.sp, ink.stickyInk, FontWeight.Normal))
                    Spacer(Modifier.height(8.dp))
                    if (spark.attrs["promoted_to"] != null) Text("已转目标", style = mono(10.sp, ink.stickyInk.copy(alpha = 0.55f)))
                }
                Box(Modifier.align(Alignment.TopCenter).offset(y = (-7).dp).width(46.dp).height(14.dp).background(ink.tape))
                DropdownMenu(menu, onDismissRequest = { menu = false }) {
                    if (spark.attrs["promoted_to"] == null) DropdownMenuItem(text = { Text("变成今日目标") }, onClick = { menu = false; model.promote(spark.id) })
                    for ((color, name) in listOf("yellow" to "黄", "pink" to "粉", "mint" to "薄荷", "blue" to "雾蓝")) {
                        DropdownMenuItem(text = { Text("换成$name") }, onClick = { menu = false; model.recolor(spark.id, color) })
                    }
                    DropdownMenuItem(text = { Text("撕掉") }, onClick = { menu = false; model.delete(spark.id) })
                }
            }
        }
        if (sparks.isEmpty()) Text("底部速记条切到 Spark，就能贴一张。", style = body(13.sp, ink.ink3))
    }
}

@Composable
private fun NotesBlock(model: RijiViewModel, date: String) {
    val ink = LocalInk.current
    var text by remember(date) { mutableStateOf(model.notes(date)) }
    SectionHeader("随记", "")
    Box(Modifier.padding(top = 8.dp)) {
        if (text.isEmpty()) Text("今天想到的、看到的，随手写下来", style = serif(16.sp, ink.ink3, FontWeight.Normal))
        BasicTextField(
            value = text, onValueChange = { text = it; model.setNotes(it, date) },
            textStyle = serif(16.sp, ink.ink2, FontWeight.Normal), cursorBrush = SolidColor(ink.ochre),
            modifier = Modifier.fillMaxWidth().heightIn(min = 72.dp),
        )
    }
}

/** 一天的收尾：一句总结，加上明天要做的事（第二天自动成为那天的今日目标）。过去的日子也显示，方便补写。 */
@Composable
private fun EveningCard(model: RijiViewModel, date: String, isToday: Boolean) {
    val ink = LocalInk.current
    val evening = model.evening(date)
    val stats = evening.stats
    val clock = model.book.clock
    var summary by remember(date) { mutableStateOf(model.summary(date)) }
    var draft by remember(date) { mutableStateOf("") }
    val addDraft = { val text = draft.trim(); if (text.isNotEmpty()) { model.addPlan(text, date); draft = "" } }
    Column(
        Modifier.padding(top = 28.dp).fillMaxWidth()
            .dashedBorder(ink.line).padding(16.dp),
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Eyebrow(if (isToday) "今日总结" else "当天总结")
            Text("完成 ${stats.done} · 延续 ${stats.carried} · Spark ${stats.sparks}", style = mono(11.sp, ink.ink2))
        }
        Box(Modifier.padding(top = 10.dp)) {
            if (summary.isEmpty()) Text(if (isToday) "用一句话记下今天" else "补一句那天的总结", style = serif(16.sp, ink.ink3, FontWeight.Normal))
            BasicTextField(summary, { summary = it; model.setSummary(it, date) }, textStyle = serif(16.sp, ink.ink, FontWeight.Normal),
                cursorBrush = SolidColor(ink.ochre), modifier = Modifier.fillMaxWidth())
        }
        Canvas(Modifier.padding(vertical = 16.dp).fillMaxWidth().height(1.dp)) {
            drawLine(ink.line, Offset(0f, 0f), Offset(size.width, 0f), strokeWidth = 1.dp.toPx(),
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 6f)))
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Eyebrow(if (isToday) "明日目标" else "次日目标")
            Text(if (isToday) "明早出现在今日目标里" else "排进 ${clock.title(clock.adding(1, date))}", style = mono(10.5.sp, ink.ink3))
        }
        for (item in model.items(SectionRole.TOMORROW, date)) PlanRow(model, item)
        Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("＋", style = body(15.sp, ink.ink3), modifier = Modifier.width(22.dp))
            Spacer(Modifier.width(12.dp))
            Box(Modifier.weight(1f)) {
                if (draft.isEmpty()) Text("明天想做的事", style = body(15.sp, ink.ink3))
                BasicTextField(
                    draft, { draft = it }, singleLine = true, textStyle = body(15.sp, ink.ink), cursorBrush = SolidColor(ink.ochre),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next), keyboardActions = KeyboardActions(onNext = { addDraft() }, onDone = { addDraft() }),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
        if (isToday && evening.pending + evening.staying > 0) {
            val parts = listOfNotNull(
                evening.pending.takeIf { it > 0 }?.let { "$it 件没做完的会带到明天" },
                evening.staying.takeIf { it > 0 }?.let { "$it 件留在今天" },
            )
            Text(parts.joinToString("，") + "（点任务右边的「→」选择）。", style = body(12.sp, ink.ink3))
        }
        if (isToday) {
            Row(Modifier.padding(top = 12.dp).fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                if (evening.missing.isNotEmpty()) Text("还差：" + evening.missing.joinToString(" · "), style = mono(11.sp, ink.ochre))
                else Text("今天收好了", style = mono(11.sp, ink.ink2))
                Text(if (model.reminderOn) "${EveningReminder.label(model.reminderMinutes)} 提醒" else "提醒已关", style = mono(11.sp, ink.ink3),
                    modifier = Modifier.clickable { model.tab = Tab.ME })
            }
            Text("网站上将公开：今日 ${stats.done}/${stats.total} · 连续 ${model.streak()} 天（同步上线后可发布）", style = body(12.sp, ink.ink3),
                modifier = Modifier.padding(top = 8.dp))
        }
    }
}

private fun Modifier.dashedBorder(color: Color) = this.drawBehind {
    drawRoundRect(color, style = Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 6f))),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(10.dp.toPx()))
}

/** 底部墨色速记条：默认记成 TODO，点左边的小纸片切换成 Spark。 */
@Composable
private fun CaptureBar(asSpark: Boolean, onToggle: () -> Unit, onSubmit: (String) -> Unit) {
    val ink = LocalInk.current
    var text by remember { mutableStateOf("") }
    val submit = { val trimmed = text.trim(); if (trimmed.isNotEmpty()) { onSubmit(trimmed); text = "" } }
    Row(
        Modifier.padding(horizontal = 16.dp, vertical = 10.dp).imePadding().fillMaxWidth().height(52.dp)
            .shadow(10.dp, RoundedCornerShape(16.dp)).background(if (ink == DarkInk) Color(0xFF2E2C28) else LightInk.ink, RoundedCornerShape(16.dp)).padding(start = 8.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(36.dp).background(if (asSpark) ink.sticky("yellow") else Color(0xFF33312C), RoundedCornerShape(11.dp)).clickable(onClick = onToggle),
            contentAlignment = Alignment.Center,
        ) { Text(if (asSpark) "✦" else "○", style = body(15.sp, if (asSpark) LightInk.stickyInk else Color(0xFFF2EEE4))) }
        Spacer(Modifier.width(10.dp))
        Box(Modifier.weight(1f)) {
            if (text.isEmpty()) Text(if (asSpark) "记一个灵感…" else "记一件事…", style = body(14.sp, Color(0xFFCFCABD)))
            BasicTextField(
                text, { text = it }, singleLine = true, textStyle = body(15.sp, Color(0xFFF7F4EC)), cursorBrush = SolidColor(LightInk.sticky("yellow")),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { submit() }),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Box(
            Modifier.size(36.dp).background(LightInk.sticky("yellow"), RoundedCornerShape(11.dp)).clickable { submit() },
            contentAlignment = Alignment.Center,
        ) { Text("＋", style = body(18.sp, LightInk.stickyInk, FontWeight.Bold)) }
    }
}

@Composable
private fun EditDialog(title: String, initial: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { BasicTextField(text, { text = it }, textStyle = body(16.sp, LocalInk.current.ink), modifier = Modifier.fillMaxWidth()) },
        confirmButton = { TextButton({ onSave(text); onDismiss() }) { Text("保存") } },
        dismissButton = { TextButton(onDismiss) { Text("取消") } },
    )
}

// ---------------------------------------------------------------- 时间线 / 进度 / 我

/** 同步：没配对时输入 Mac 上的配对码，核对比对码；配对后显示状态与「立即同步」。 */
@Composable
private fun SyncSettings(model: RijiViewModel) {
    val ink = LocalInk.current
    Eyebrow("同步")
    if (model.syncEnabled) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            val parts = listOfNotNull(
                model.syncStatus,
                model.lastSync?.atZone(java.time.ZoneId.systemDefault())?.format(DateTimeFormatter.ofPattern("HH:mm")),
                model.syncDevices.takeIf { it > 0 }?.let { "$it 台设备" },
            )
            Text(parts.joinToString(" · "), style = body(14.sp, ink.ink), modifier = Modifier.weight(1f))
            TextButton({ model.syncNow() }, enabled = !model.syncing) { Text(if (model.syncing) "同步中…" else "立即同步", color = ink.ochre) }
        }
        Text("与 Mac 端到端加密同步：密钥只在你的设备上，腾讯云只存密文。打开应用、内容变化后与每分钟会自动同步。", style = body(13.sp, ink.ink3))
        return
    }
    var code by remember { mutableStateOf("") }
    when (val state = model.pairState) {
        is RijiViewModel.PairState.Confirm -> {
            Text("请确认 Mac 上显示的比对码", style = body(14.sp, ink.ink2))
            Text(state.sas.take(3) + " " + state.sas.takeLast(3), style = mono(32.sp, ink.ink).copy(fontWeight = FontWeight.SemiBold))
            Text("一致的话，在 Mac 上点「一致，发送」；不一致就取消。正在等 Mac…", style = body(13.sp, ink.ink3))
            TextButton({ model.cancelPairing() }) { Text("取消", color = ink.ink2) }
        }
        RijiViewModel.PairState.Joining -> Text("正在连接…", style = body(14.sp, ink.ink2))
        RijiViewModel.PairState.Done -> Text("配对完成，正在同步…", style = body(14.sp, ink.ink))
        else -> {
            Text("在 Mac 的「设置 → 同步」里点「添加手机」，把显示的 8 位数字填在这里。", style = body(13.5.sp, ink.ink2))
            LabeledField("配对码", code, singleLine = true) { code = it.filter(Char::isDigit).take(8) }
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton({ model.joinPairing(code) }, enabled = code.length == 8) { Text("配对", color = ink.ochre) }
                (state as? RijiViewModel.PairState.Failed)?.let { Text(it.message, style = body(12.sp, Color(0xFFB5443A))) }
            }
        }
    }
}

/** 邮件提醒（兜底）：开关、收件邮箱（可多个）、兜底时间、连接码、测试邮件。 */
@Composable
private fun MailSettings(model: RijiViewModel) {
    val ink = LocalInk.current
    val mail = model.mail
    var recipients by remember { mutableStateOf(mail.recipients) }
    var token by remember { mutableStateOf(mail.token) }
    LaunchedEffect(mail.recipients) { if (mail.recipients != recipients && MailReminder.parse(mail.recipients) != MailReminder.parse(recipients)) recipients = mail.recipients }
    val (valid, invalid) = MailReminder.parse(recipients)
    Eyebrow("邮件提醒（兜底）")
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text("通知之后仍没写，发邮件提醒", style = body(14.5.sp, ink.ink), modifier = Modifier.weight(1f))
        Switch(mail.email, { model.updateMail(mail.copy(email = it)) })
    }
    LabeledField("收件邮箱（可填多个，用逗号或换行隔开）", recipients, singleLine = false) {
        recipients = it
        model.updateMail(model.mail.copy(recipients = it))
    }
    if (invalid.isNotEmpty()) Text("格式不对：" + invalid.joinToString("、"), style = body(12.sp, Color(0xFFB5443A)))
    else if (valid.size > MailReminder.MAX_RECIPIENTS) Text("最多 ${MailReminder.MAX_RECIPIENTS} 个，多出的不会收到", style = body(12.sp, Color(0xFFB5443A)))
    Text("兜底时间", style = body(13.sp, ink.ink2))
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for (minutes in MailReminder.delays) {
            val on = mail.delay == minutes
            val label = if (minutes < 60) "$minutes 分" else if (minutes % 60 == 0) "${minutes / 60} 小时" else "${minutes / 60}.5 小时"
            Text(label, style = mono(12.sp, if (on) ink.paper else ink.ink2),
                modifier = Modifier.background(if (on) ink.ink else ink.paper2, RoundedCornerShape(8.dp))
                    .clickable { model.updateMail(mail.copy(delay = minutes)) }.padding(horizontal = 12.dp, vertical = 7.dp))
        }
    }
    LabeledField("连接码", token, singleLine = true, secret = true) {
        token = it
        model.updateMail(model.mail.copy(token = it))
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        TextButton({ model.sendTestMail() }, enabled = token.isNotBlank() && valid.isNotEmpty()) { Text("发一封测试邮件", color = ink.ochre) }
        Text(model.mailStatus, style = body(12.sp, ink.ink3))
    }
    Text("到「提醒时间 + 兜底时间」时，今日总结或明日目标仍然空着、或者今天还没打开日迹，就由腾讯云上的服务发一封邮件，一天最多一封。" +
        "只上传今天的几个数字（总结写没写、目标几条、完成几件），不上传笔记内容。在 Mac 上改过的收件人会自动同步过来；和 Mac 配对时连接码会自动填好。", style = body(13.sp, ink.ink3))
}

@Composable
private fun LabeledField(label: String, value: String, singleLine: Boolean, secret: Boolean = false, onChange: (String) -> Unit) {
    val ink = LocalInk.current
    Column {
        Text(label, style = body(13.sp, ink.ink2))
        BasicTextField(
            value, onChange, singleLine = singleLine, textStyle = body(15.sp, ink.ink), cursorBrush = SolidColor(ink.ochre),
            visualTransformation = if (secret) androidx.compose.ui.text.input.PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
            modifier = Modifier.padding(top = 6.dp).fillMaxWidth().background(ink.paper2, RoundedCornerShape(8.dp)).padding(12.dp),
        )
    }
}

@Composable
fun TimelineScreen(model: RijiViewModel) {
    val ink = LocalInk.current
    val days = model.days().filter { model.stats(it.date).hasContent || it.date == model.today }
    LazyColumn(Modifier.fillMaxSize().statusBarsPadding().padding(horizontal = 24.dp)) {
        item { Spacer(Modifier.height(18.dp)); Text("时间线", style = serif(32.sp, ink.ink)); Spacer(Modifier.height(8.dp)) }
        item { Heatmap(model) }
        var month = ""
        for (day in days) {
            val m = day.date.take(7)
            if (m != month) {
                month = m
                item(key = "m$m") { Text(m.replace("-", " · "), style = serif(20.sp, ink.ink), modifier = Modifier.padding(top = 22.dp, bottom = 6.dp)) }
            }
            item(key = day.date) {
                val stats = model.stats(day.date)
                val preview = model.items(SectionRole.SPARK, day.date).firstOrNull()?.text?.let { "Spark · $it" }
                    ?: model.items(SectionRole.TODO, day.date).firstOrNull()?.text ?: model.notes(day.date)
                Row(Modifier.fillMaxWidth().clickable { model.open(day.date) }.padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(day.date.takeLast(5).replace("-", ""), style = serif(20.sp, ink.ink), modifier = Modifier.width(64.dp))
                    Column(Modifier.weight(1f)) {
                        Text(if (day.date == model.today) "今天" else model.book.clock.weekday(day.date), style = body(13.sp, ink.ink2, FontWeight.Medium))
                        Text(preview, style = body(13.sp, ink.ink3), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    Text("${stats.done}/${stats.total}", style = mono(11.sp, ink.ink3))
                }
                Box(Modifier.fillMaxWidth().height(1.dp).background(ink.line))
            }
        }
    }
}

@Composable
private fun Heatmap(model: RijiViewModel, weeks: Int = 18) {
    val ink = LocalInk.current
    val clock = model.book.clock
    val levels = model.heatmap()
    val weekday = java.time.LocalDate.parse(model.today).dayOfWeek.value - 1
    val start = clock.adding(-(weeks - 1) * 7 - weekday, model.today)
    Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        for (w in 0 until weeks) {
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                for (d in 0 until 7) {
                    val date = clock.adding(w * 7 + d, start)
                    val color = if (date > model.today) Color.Transparent else ink.heat[levels[date] ?: 0]
                    Box(
                        Modifier.size(12.dp).background(color, RoundedCornerShape(2.dp))
                            .then(if (date == model.today) Modifier.border(BorderStroke(1.5.dp, ink.ochre), RoundedCornerShape(2.dp)) else Modifier)
                            .clickable(enabled = date <= model.today) { model.open(date) },
                    )
                }
            }
        }
    }
    Text("连续 ${model.streak()} 天", style = mono(11.sp, ink.ink2), modifier = Modifier.padding(top = 8.dp))
}

@Composable
fun ProgressScreen(model: RijiViewModel) {
    val ink = LocalInk.current
    LazyColumn(Modifier.fillMaxSize().statusBarsPadding().padding(horizontal = 24.dp)) {
        item {
            Spacer(Modifier.height(18.dp))
            Text("进度", style = serif(32.sp, ink.ink))
            Text("写「电路 18 讲」「马原 第 6 章」这样的任务会自动归到这里；勾选时进度推进。", style = body(13.sp, ink.ink3), modifier = Modifier.padding(vertical = 8.dp))
        }
        items(model.progresses(), key = { it.id }) { progress ->
            Column(Modifier.padding(vertical = 8.dp).fillMaxWidth().background(ink.paper2, RoundedCornerShape(12.dp)).padding(16.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(progress.name, style = body(15.sp, ink.ink, FontWeight.Medium))
                    Text(progress.target?.let { "${progress.current}/$it ${progress.unit}" } ?: "${progress.current} ${progress.unit}", style = mono(12.sp, ink.ink3))
                }
                Box(Modifier.padding(vertical = 10.dp).fillMaxWidth().height(3.dp).background(ink.line, CircleShape)) {
                    Box(Modifier.fillMaxWidth((progress.fraction ?: 0.0).toFloat()).height(3.dp).background(ink.ink, CircleShape))
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton({ model.updateProgress(progress.copy(current = maxOf(0, progress.current - 1))) }) { Text("−1", color = ink.ink2) }
                    TextButton({ model.updateProgress(progress.copy(current = progress.current + 1)) }) { Text("+1", color = ink.ink2) }
                    Spacer(Modifier.weight(1f))
                    Text("公开", style = body(12.5.sp, ink.ink2))
                    Switch(progress.isPublic, { model.updateProgress(progress.copy(isPublic = it)) })
                }
            }
        }
    }
}

@Composable
fun MeScreen(model: RijiViewModel) {
    val ink = LocalInk.current
    Column(Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text("ƒ ", style = serif(32.sp, ink.ochre))
            Text("日迹", style = serif(32.sp, ink.ink))
        }
        Text("每天一页：灵感、今日目标、长期进度、晚上一句总结和明日目标。", style = body(14.sp, ink.ink2))
        Box(Modifier.fillMaxWidth().height(1.dp).background(ink.line))
        SyncSettings(model)
        Eyebrow("一天")
        Text("一天结束于", style = body(14.5.sp, ink.ink))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (minutes in listOf(0, 120, 180, 240, 300)) {
                val on = model.dayStart == minutes
                Text(if (minutes == 0) "零点" else "${minutes / 60} 点", style = mono(12.sp, if (on) ink.paper else ink.ink2),
                    modifier = Modifier.background(if (on) ink.ink else ink.paper2, RoundedCornerShape(8.dp))
                        .clickable { model.changeDayStart(minutes) }.padding(horizontal = 12.dp, vertical = 7.dp))
            }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("没做完的事自动带到明天", style = body(14.5.sp, ink.ink), modifier = Modifier.weight(1f))
            Switch(model.carryByDefault, { model.changeCarryByDefault(it) })
        }
        Text("分界线之前仍算前一天：零点后写的总结记在当天，明日目标与没做完的事也在分界线上才带到新的一天。" +
            "每件事右边的「→ 明天」可以单独选带不带，优先于这个开关；明日目标总会排进明天。", style = body(13.sp, ink.ink3))
        Eyebrow("晚间提醒")
        val context = androidx.compose.ui.platform.LocalContext.current
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("每晚提醒写今日总结和明日目标", style = body(14.5.sp, ink.ink))
                Text(
                    EveningReminder.label(model.reminderMinutes) + "  更改",
                    style = mono(12.sp, if (model.reminderOn) ink.ochre else ink.ink3),
                    modifier = Modifier.padding(top = 4.dp).clickable(enabled = model.reminderOn) {
                        android.app.TimePickerDialog(context, { _, h, m -> model.setReminder(true, h * 60 + m) },
                            model.reminderMinutes / 60, model.reminderMinutes % 60, true).show()
                    },
                )
            }
            Switch(model.reminderOn, { model.setReminder(it, model.reminderMinutes) })
        }
        Text("都写好了就不提醒；只差一样，就只提那一样。第二天早上如果昨天还没写总结，今天页顶部会出现「补写」。" +
            "荣耀手机请在「设置 → 应用 → 日迹」里允许自启动与后台运行，否则提醒可能被系统拦下。", style = body(13.sp, ink.ink3))
        MailSettings(model)
        Eyebrow("这台设备")
        Text("已记录 ${model.days().count { model.stats(it.date).hasContent }} 天 · " + if (model.syncEnabled) "与 Mac 加密同步" else "数据只在本机", style = mono(12.sp, ink.ink3))
    }
}

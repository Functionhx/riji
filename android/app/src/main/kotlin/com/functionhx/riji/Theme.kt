package com.functionhx.riji

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp

// 纸与墨（docs/DESIGN.md §4.1），与 Mac 版的 Theme.swift 同一套令牌。不用 Material 的动态取色。

@Immutable
data class InkColors(
    val paper: Color, val paper2: Color, val ink: Color, val ink2: Color, val ink3: Color, val line: Color,
    val ochre: Color, val ochreSoft: Color, val selection: Color, val stickyInk: Color, val tape: Color,
    val stickies: Map<String, Color>, val heat: List<Color>,
) {
    fun sticky(name: String) = stickies[name] ?: stickies.getValue("yellow")
}

val LightInk = InkColors(
    paper = Color(0xFFFAF8F3), paper2 = Color(0xFFF2EFE7), ink = Color(0xFF1D1C1A), ink2 = Color(0xFF55524A), ink3 = Color(0xFF8F8B80),
    line = Color(0xFFE6E2D8), ochre = Color(0xFFB5762A), ochreSoft = Color(0xFFEAD2AD), selection = Color(0xFFE6E1D4),
    stickyInk = Color(0xFF3A372C), tape = Color(0xA6DAD1BA),
    stickies = mapOf("yellow" to Color(0xFFF8EAA6), "pink" to Color(0xFFF6D7D9), "mint" to Color(0xFFD6ECDF), "blue" to Color(0xFFD9E6F6)),
    heat = listOf(Color(0xFFECE8DE), Color(0xFFD9D2BF), Color(0xFFB9AE8F), Color(0xFF8A7D5A), Color(0xFF4F4632)),
)

val DarkInk = InkColors(
    paper = Color(0xFF141413), paper2 = Color(0xFF1C1B19), ink = Color(0xFFF3F0E8), ink2 = Color(0xFFB5B1A6), ink3 = Color(0xFF7D796F),
    line = Color(0xFF2D2B27), ochre = Color(0xFFD79A4E), ochreSoft = Color(0xFF5A4428), selection = Color(0xFF2A2925),
    stickyInk = Color(0xFFEFE9D6), tape = Color(0x29FFFFFF),
    stickies = mapOf("yellow" to Color(0xFF4A4327), "pink" to Color(0xFF4B3035), "mint" to Color(0xFF27433A), "blue" to Color(0xFF2B3A4E)),
    heat = listOf(Color(0xFF22211E), Color(0xFF3A362C), Color(0xFF6B6148), Color(0xFFA8996F), Color(0xFFE9DCB4)),
)

val LocalInk = staticCompositionLocalOf { LightInk }

object Typefaces {
    val serif: FontFamily = FontFamily.Serif      // 安卓上是思源宋体 / Noto Serif CJK
    val mono: FontFamily = FontFamily.Monospace
    val hand: FontFamily = FontFamily.Serif        // 手写体子集在后续版本随包附带（霞鹜文楷，SIL OFL）
}

@Composable
fun RijiTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val ink = if (dark) DarkInk else LightInk
    val scheme = if (dark) {
        darkColorScheme(primary = ink.ink, onPrimary = ink.paper, background = ink.paper, surface = ink.paper, onBackground = ink.ink, onSurface = ink.ink)
    } else {
        lightColorScheme(primary = ink.ink, onPrimary = ink.paper, background = ink.paper, surface = ink.paper, onBackground = ink.ink, onSurface = ink.ink)
    }
    CompositionLocalProvider(LocalInk provides ink) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}

/** 等宽小标签：字距 0.14em、全大写。 */
@Composable
fun Eyebrow(text: String, color: Color = LocalInk.current.ink3, size: TextUnit = 11.sp) {
    Text(text.uppercase(), style = TextStyle(fontFamily = Typefaces.mono, fontSize = size, letterSpacing = 0.14.em, color = color))
}

fun serif(size: TextUnit, color: Color, weight: FontWeight = FontWeight.SemiBold) =
    TextStyle(fontFamily = Typefaces.serif, fontSize = size, fontWeight = weight, color = color)

fun mono(size: TextUnit, color: Color) = TextStyle(fontFamily = Typefaces.mono, fontSize = size, color = color)

fun body(size: TextUnit, color: Color, weight: FontWeight = FontWeight.Normal) = TextStyle(fontSize = size, fontWeight = weight, color = color)

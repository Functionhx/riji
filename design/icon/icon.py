#!/usr/bin/env python3
"""日迹的图标「便利贴日出」：python3 design/icon/icon.py

墨绿底上一张便利贴，上面用墨画着山，赭色的太阳正从山间升起——每天一页、一天刚开始。
和应用里的 Spark 便利贴是同一种纸。

输出（都从这里生成，不要手改）：
  riji.svg                       合成的一张（网页、预览、README）
  build/layers/*.svg             分层（便利贴、画、太阳、胶带），Icon Composer 与 Android 前景用
  apple/Riji/App/Shared/AppIcon.icon   macOS / iOS 26 的分层图标
"""

import json
from pathlib import Path

HERE = Path(__file__).parent
ROOT = HERE.parent.parent
S = 1024
TILT = -6  # 便利贴的倾斜
LIFT = 34  # 画在便利贴上往上挪一点，让出胶带下的空白

BG = ("#3D5048", "#1B2421")
NOTE = ("#FDF0B8", "#F2D57C")
CURL = ("#E2C266", "#C9A548")
INK = ("#3A342D", "#1A1714")
WASH = "#3A342D"
SUN = ("#F6B35A", "#D2762A")
TAPE = "#EFE7D2"

NOTE_PATH = "M236 248 H788 V712 Q778 786 702 800 H236 Z"
CURL_PATH = "M702 800 Q778 786 788 712 Q760 736 748 762 Q734 790 702 800 Z"
# 近山：左边一座高峰，右边一道缓坡；远山：一道淡墨的山脊，压在太阳下沿
NEAR = ("M250 720 C318 700 352 640 390 600 C414 574 428 520 448 506 C466 512 484 560 506 590 "
        "C526 616 548 628 578 616 C606 604 626 584 652 590 C688 598 720 640 770 680 V780 H250 Z")
FAR = ("M250 660 C330 650 380 628 440 622 C500 616 540 612 590 600 C640 588 690 600 770 624 V780 H250 Z")
PEAK = "M448 506 C458 512 467 528 474 548 C463 540 455 537 442 539 C444 527 446 515 448 506 Z"


def svg(defs: str, body: str) -> str:
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}"><defs>{defs}</defs>{body}</svg>\n'


def grad(id_, a, b, x2="0.25", y2="1") -> str:
    return (f'<linearGradient id="{id_}" x1="0" y1="0" x2="{x2}" y2="{y2}"><stop offset="0" stop-color="{a}"/>'
            f'<stop offset="1" stop-color="{b}"/></linearGradient>')


def tilt(inner: str, lift: int = 0) -> str:
    return f'<g transform="rotate({TILT} 512 524) translate(0 {-lift})">{inner}</g>'


def note_layer() -> str:
    defs = grad("note", *NOTE) + grad("curl", *CURL, x2="1", y2="1")
    return svg(defs, tilt(f'<path d="{NOTE_PATH}" fill="url(#note)"/><path d="{CURL_PATH}" fill="url(#curl)"/>'))


def art_layer() -> str:
    """墨画的山：远山是淡墨，近山是浓墨，底部晕开进纸里。"""
    defs = ('<linearGradient id="ink" gradientUnits="userSpaceOnUse" x1="0" y1="560" x2="0" y2="760">'
            f'<stop offset="0" stop-color="{INK[1]}"/><stop offset="0.45" stop-color="{INK[0]}" stop-opacity="0.92"/>'
            f'<stop offset="1" stop-color="{INK[0]}" stop-opacity="0"/></linearGradient>'
            '<linearGradient id="far" gradientUnits="userSpaceOnUse" x1="0" y1="590" x2="0" y2="720">'
            f'<stop offset="0" stop-color="{WASH}" stop-opacity="0.34"/><stop offset="1" stop-color="{WASH}" stop-opacity="0"/></linearGradient>'
            + '<linearGradient id="fade" x1="0" y1="0" x2="0" y2="1"><stop offset="0.55" stop-color="#fff"/>'
              '<stop offset="0.93" stop-color="#fff" stop-opacity="0"/></linearGradient>'
              '<linearGradient id="sides" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#fff" stop-opacity="0"/>'
              '<stop offset="0.16" stop-color="#fff"/><stop offset="0.84" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>'
              '<mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">'
              '<rect x="250" y="440" width="520" height="340" fill="url(#sides)"/></mask>')
    near_ridge = NEAR.split(" V")[0]
    far_ridge = FAR.split(" V")[0]
    body = (f'<g mask="url(#m)"><path d="{FAR}" fill="url(#far)"/>'
            f'<path d="{far_ridge}" fill="none" stroke="{WASH}" stroke-opacity="0.35" stroke-width="5" stroke-linecap="round"/>'
            f'<path d="{NEAR}" fill="url(#ink)"/>'
            f'<path d="{near_ridge}" fill="none" stroke="{INK[1]}" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/></g>'
            f'<path d="{PEAK}" fill="{NOTE[0]}" opacity="0.55"/>')
    return svg(defs, tilt(body, LIFT))


def sun_layer() -> str:
    defs = ('<radialGradient id="sun" cx="0.4" cy="0.3" r="0.8">'
            f'<stop offset="0" stop-color="{SUN[0]}"/><stop offset="1" stop-color="{SUN[1]}"/></radialGradient>'
            '<linearGradient id="sfade" x1="0" y1="0" x2="0" y2="1"><stop offset="0.6" stop-color="#fff"/>'
            '<stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>'
            '<mask id="sm" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">'
            '<rect x="460" y="420" width="240" height="230" fill="url(#sfade)"/></mask>')
    return svg(defs, tilt('<circle cx="574" cy="528" r="90" fill="url(#sun)" mask="url(#sm)"/>', LIFT))


def tape_layer() -> str:
    """半透明的纸胶带，两端是撕开的毛边。"""
    x0, x1, y0, y1, teeth = 396, 628, 214, 290, 8
    right = [(x1 - (6 if i % 2 else 0), y0 + (y1 - y0) * i / teeth) for i in range(1, teeth)]
    left = [(x0 + (6 if i % 2 else 0), y1 - (y1 - y0) * i / teeth) for i in range(1, teeth)]
    points = [(x0, y0), (x1, y0), *right, (x1, y1), (x0, y1), *left]
    path = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in points) + " Z"
    return svg("", tilt(f'<g transform="rotate(4 512 252)"><path d="{path}" fill="{TAPE}" opacity="0.86"/></g>'))


def background() -> str:
    defs = (grad("bg", *BG, x2="0.45", y2="1")
            + '<radialGradient id="vig" cx="0.5" cy="0.42" r="0.75"><stop offset="0.6" stop-color="#000" stop-opacity="0"/>'
              '<stop offset="1" stop-color="#000" stop-opacity="0.28"/></radialGradient>')
    return svg(defs, f'<rect width="{S}" height="{S}" fill="url(#bg)"/><rect width="{S}" height="{S}" fill="url(#vig)"/>')


def inner(document: str) -> str:
    return document.split(">", 1)[1].rsplit("</svg>", 1)[0]


def flat(shadow: bool = True) -> str:
    """合成一张：背景 + 投影 + 便利贴 + 画 + 太阳 + 胶带。"""
    shadow_defs = ('<filter id="drop" x="-30%" y="-30%" width="160%" height="160%">'
                   '<feDropShadow dx="0" dy="24" stdDeviation="26" flood-color="#000" flood-opacity="0.42"/></filter>')
    parts = [inner(background())]
    if shadow:
        parts.append(f'<defs>{shadow_defs}</defs><g filter="url(#drop)">{inner(note_layer())}</g>')
    else:
        parts.append(inner(note_layer()))
    parts += [inner(sun_layer()), inner(art_layer()), inner(tape_layer())]
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">{"".join(parts)}</svg>\n'


def write_icon_composer(target: Path) -> None:
    """Icon Composer 图标：背景用填充，便利贴（连同画和太阳）与胶带两层，系统负责玻璃质感与投影。"""
    assets = target / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    for old in assets.glob("*"):
        old.unlink()
    # 画和太阳与便利贴合成一层：系统会在每层的边缘画玻璃高光，分开的话渐隐的边界上会出现横线。
    paper = f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">' \
            f'{inner(note_layer())}{inner(sun_layer())}{inner(art_layer())}</svg>\n'
    files = {"tape.svg": tape_layer(), "paper.svg": paper}
    for name, content in files.items():
        (assets / name).write_text(content)

    def color(hex_: str) -> str:
        r, g, b = (int(hex_[i:i + 2], 16) / 255 for i in (1, 3, 5))
        return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"

    config = {
        "fill": {"linear-gradient": [color(BG[0]), color(BG[1])]},
        "groups": [
            {"layers": [{"image-name": "tape.svg", "name": "tape"}],
             "shadow": {"kind": "neutral", "opacity": 0.3}, "translucency": {"enabled": True, "value": 0.3}},
            {"layers": [{"image-name": "paper.svg", "name": "paper"}],
             "shadow": {"kind": "layer-color", "opacity": 0.5}, "translucency": {"enabled": False, "value": 0.5}},
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    (target / "icon.json").write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n")


def android_foreground() -> str:
    """自适应图标的前景：便利贴整体缩小，落进安全区（圆形遮罩也不裁到角）。"""
    shadow = ('<filter id="drop" x="-30%" y="-30%" width="160%" height="160%">'
              '<feDropShadow dx="0" dy="20" stdDeviation="22" flood-color="#000" flood-opacity="0.4"/></filter>')
    body = (f'<defs>{shadow}</defs><g transform="translate(512 524) scale(0.74) translate(-512 -524)">'
            f'<g filter="url(#drop)">{inner(note_layer())}</g>{inner(sun_layer())}{inner(art_layer())}{inner(tape_layer())}</g>')
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">{body}</svg>\n'


def android_monochrome() -> str:
    """主题图标（Android 13+）只用透明度：便利贴的剪影，山和太阳镂空，四周留边、两者之间留一道缝。"""
    ridge = NEAR.split(" V")[0]
    cut = (f'<g transform="rotate({TILT} 512 524) translate(0 {-LIFT})">'
           '<clipPath id="inset"><rect x="292" y="300" width="440" height="404" rx="24"/></clipPath>'
           '<circle cx="574" cy="528" r="84" fill="#000"/>'
           f'<g clip-path="url(#inset)"><path d="{NEAR}" fill="#000" stroke="#fff" stroke-width="26"/>'
           f'<path d="{ridge}" fill="none" stroke="#000" stroke-width="0"/></g></g>')
    body = (f'<defs><mask id="mono" maskUnits="userSpaceOnUse" x="0" y="0" width="{S}" height="{S}">'
            f'<rect width="{S}" height="{S}" fill="#fff"/>{cut}</mask></defs>'
            f'<g transform="translate(512 524) scale(0.74) translate(-512 -524)">'
            f'<g mask="url(#mono)">{tilt(f"<path d=\"{NOTE_PATH}\" fill=\"#fff\"/>")}</g></g>')
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">{body}</svg>\n'


def notification_vector() -> str:
    """通知栏小图标（Android 只用透明度）：山与太阳，24dp。"""
    k = 24 / 560
    ridge = NEAR.replace("V780 H250 Z", "V760 H250 Z")
    return ('<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="24dp" android:height="24dp"\n'
            '    android:viewportWidth="1024" android:viewportHeight="1024">\n'
            '    <!-- 由 design/icon/icon.py 生成：山与升起的太阳 -->\n'
            '    <group android:translateX="-120" android:translateY="-180" android:scaleX="1.25" android:scaleY="1.25">\n'
            '        <path android:fillColor="#FFFFFFFF" android:pathData="M574,438 a90,90 0 1,1 0,180 a90,90 0 1,1 0,-180z"/>\n'
            f'        <path android:fillColor="#FFFFFFFF" android:pathData="{ridge}"/>\n'
            '    </group>\n</vector>\n')


def main() -> None:
    layers = HERE / "build" / "layers"
    layers.mkdir(parents=True, exist_ok=True)
    for name, fn in (("background", background), ("note", note_layer), ("art", art_layer), ("sun", sun_layer), ("tape", tape_layer)):
        (layers / f"{name}.svg").write_text(fn())
    (HERE / "riji.svg").write_text(flat())
    (HERE / "build" / "riji-flat.svg").write_text(flat(shadow=False))
    write_icon_composer(ROOT / "apple" / "Riji" / "App" / "Shared" / "AppIcon.icon")
    (HERE / "build" / "android-foreground.svg").write_text(android_foreground())
    (HERE / "build" / "android-monochrome.svg").write_text(android_monochrome())
    (HERE / "build" / "android-background.svg").write_text(background())
    (ROOT / "android" / "app" / "src" / "main" / "res" / "drawable" / "ic_notify.xml").write_text(notification_vector())
    print("ok")


if __name__ == "__main__":
    main()

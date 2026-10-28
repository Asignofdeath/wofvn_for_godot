## 编辑器面板共用的配色与底板样式。
##
## 只放常量和小工具，不持状态、不 new 节点：
## 两个面板（导图 / 剧本）各自 new 自己的 StyleBox，共用同一个对象会被主题覆盖串味。
## 加一个颜色先加到这里，别在面板里写死 Color("#…")。
extends RefCounted

const BG := Color("#0d1117")          ## 画布底色
const SURFACE := Color("#1a1f28")     ## 顶栏 / 底栏 / 卡片底色
const SURFACE_HI := Color("#242b38")  ## 卡片标题条底色
const BORDER := Color("#2a3040")      ## 分隔线、描边
const TEXT := Color("#e8e4dc")        ## 正文
const MUTED := Color("#8a9aaa")       ## 次要文字、次要按钮
const FAINT := Color("#5a6478")       ## 提示文字（比 MUTED 更弱）
const ACCENT := Color("#c4a882")      ## 强调色：entry、选中态、未保存标记
const SCRIPT := Color("#c47a5a")      ## 剧情片段的类型色
const ERROR := Color("#e08080")
const WARN := Color("#e0c080")


## 顶栏 / 底栏的底板：底色 + 左右内边距，顶栏多一条下边线。
static func bar_style(with_bottom_line: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = SURFACE
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	if with_bottom_line:
		sb.border_color = BORDER
		sb.border_width_bottom = 1
	return sb


## 顶栏上那种扁平次要按钮。flat 之外统一给 MUTED 字色，改风格只改这里。
static func flat_button(text: String, muted := true) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.add_theme_color_override("font_color", MUTED if muted else TEXT)
	return b

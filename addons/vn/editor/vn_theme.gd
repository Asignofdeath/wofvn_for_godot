## 编辑器面板的共用配色与底板。
##
## 两个面板用同一套色，改色只改这里。刻意只放「视觉常量 + 一个底板工厂」，
## 不放控件工厂：控件结构一旦共享，两个面板就会长在一起。
class_name VNEditorTheme
extends RefCounted

const BG := Color("#0d1117")          ## 画布底色
const SURFACE := Color("#1a1f28")     ## 顶栏 / 底栏 / 卡片底色
const SURFACE_HI := Color("#242b38")  ## 卡片标题条
const BORDER := Color("#2a3040")      ## 分隔线、描边
const TEXT := Color("#e8e4dc")        ## 主要文字
const MUTED := Color("#8a9aaa")       ## 次要文字、次要按钮
const ACCENT := Color("#c4a882")      ## 强调：entry、选中、未保存
const SCRIPT := Color("#c47a5a")      ## 章节节点类型色
const ERROR := Color("#e08080")       ## 错误
const WARN := Color("#e0c080")        ## 提示 / 草稿态


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

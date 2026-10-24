## VN 章节路由图编辑器。
##
## 只做一件事：编辑 story_graph.json。
## 不定义新的资源格式，不接管运行时，不参与游戏的节点结构。
## 关掉这个面板、甚至删掉整个 addons/vn/，图和游戏都照常跑。
@tool
extends Control

const DEFAULT_GRAPH := "res://demo/story/story_graph.json"

const TOP_H := 52
const HINT_H := 26

const C_BG := Color("#0d1117")
const C_SURFACE := Color("#1a1f28")
const C_SURFACE_HI := Color("#242b38")
const C_BORDER := Color("#2a3040")
const C_TEXT := Color("#e8e4dc")
const C_MUTED := Color("#8a9aaa")
const C_ACCENT := Color("#c4a882")
const C_SCRIPT := Color("#c47a5a")
const C_ERROR := Color("#e08080")
const C_WARN := Color("#e0c080")

var _doc := VNGraphDoc.new()
var _dirty := false

var _root: VBoxContainer
var _top_wrap: PanelContainer
var _top: HBoxContainer
var _hint_wrap: PanelContainer
var _hint_bar: HBoxContainer
var _title: Label
var _file_label: Label
var _save_btn: Button
var _stats: Label
var _zoom_label: Label
var _issue_btn: Button
var _graph: GraphEdit
var _hint: Label
var _status: Label
var _issue_panel: PanelContainer
var _issue_list: ItemList
var _file_dialog: FileDialog
var _add_menu: MenuButton
var _dialog: AcceptDialog
var _dialog_body: VBoxContainer
var _dialog_id := ""

var _last_zoom := 1.0


func _ready() -> void:
	_build_ui()
	_apply_graph_theme()
	if FileAccess.file_exists(DEFAULT_GRAPH):
		_open(DEFAULT_GRAPH)
	else:
		_set_hint("未打开图。点左上「打开」选择一份 story_graph.json")


func _process(_delta: float) -> void:
	if _graph == null:
		return
	if not is_equal_approx(_graph.zoom, _last_zoom):
		_last_zoom = _graph.zoom
		_zoom_label.text = "%d%%" % roundi(_graph.zoom * 100.0)


## ---- 布局 ----
##
## 尺寸适配只靠两件事，不写任何 position/size 手算：
##   1. 本节点挂 SIZE_EXPAND_FILL —— 父节点是编辑器主屏幕的 VBoxContainer(MainScreen)，
##      不挂 EXPAND 它只按最小高度塞一条矮带，画布就只剩 50px。
##   2. 内部用 VBoxContainer 排队：顶栏固定高、画布抢剩余、底栏固定高。

func _build_ui() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	_root = VBoxContainer.new()
	_root.name = "Root"
	_root.add_theme_constant_override("separation", 0)
	add_child(_root)
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_top_wrap = PanelContainer.new()
	_top_wrap.name = "TopBar"
	_top_wrap.custom_minimum_size.y = TOP_H
	_top_wrap.add_theme_stylebox_override("panel", _bar_style(true))
	_root.add_child(_top_wrap)

	# 顶栏按钮多，套一层横向滚动，窗口很窄时不会把整个面板的宽度撑开
	var top_scroll := ScrollContainer.new()
	top_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	top_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_top_wrap.add_child(top_scroll)

	_top = HBoxContainer.new()
	_top.add_theme_constant_override("separation", 10)
	top_scroll.add_child(_top)

	# 画布：唯一挂 EXPAND 的子节点，抢走顶栏与底栏之外的全部高度
	_graph = GraphEdit.new()
	_graph.name = "Graph"
	_graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph.right_disconnects = true
	_graph.minimap_enabled = false
	_graph.connection_lines_curvature = 0.0
	_graph.connection_lines_thickness = 1.6
	_graph.connection_lines_antialiased = true
	_graph.grid_pattern = GraphEdit.GRID_PATTERN_DOTS
	_graph.snapping_enabled = false
	# 关掉引擎自带的浮动工具栏，操作入口统一放到顶部细栏
	_graph.show_menu = false
	_graph.show_zoom_label = false
	_graph.show_zoom_buttons = false
	_graph.show_grid_buttons = false
	_graph.show_minimap_button = false
	_graph.show_arrange_button = false
	_graph.connection_request.connect(_on_connection_request)
	_graph.disconnection_request.connect(_on_disconnection_request)
	_graph.delete_nodes_request.connect(_on_delete_nodes_request)
	_root.add_child(_graph)

	var open_btn := Button.new()
	open_btn.text = "打开"
	open_btn.flat = true
	open_btn.add_theme_color_override("font_color", C_MUTED)
	open_btn.pressed.connect(_on_open_pressed)
	_top.add_child(open_btn)

	_save_btn = Button.new()
	_save_btn.text = "保存"
	_save_btn.flat = true
	_save_btn.add_theme_color_override("font_color", C_MUTED)
	_save_btn.pressed.connect(_on_save_pressed)
	_top.add_child(_save_btn)

	_add_menu = MenuButton.new()
	_add_menu.text = "＋ 节点"
	_add_menu.flat = true
	_add_menu.add_theme_color_override("font_color", C_MUTED)
	var popup := _add_menu.get_popup()
	popup.add_item("剧本节点", 0)
	popup.add_item("终止节点", 1)
	popup.id_pressed.connect(_on_add_node)
	_top.add_child(_add_menu)

	var sep := VSeparator.new()
	sep.add_theme_color_override("separator", C_BORDER)
	_top.add_child(sep)

	_title = Label.new()
	_title.text = "剧本导图"
	_title.add_theme_color_override("font_color", C_ACCENT)
	_title.add_theme_font_size_override("font_size", 14)
	_top.add_child(_title)

	_file_label = Label.new()
	_file_label.add_theme_color_override("font_color", C_MUTED)
	_file_label.add_theme_font_size_override("font_size", 12)
	_file_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_file_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_top.add_child(_file_label)

	_stats = Label.new()
	_stats.add_theme_color_override("font_color", C_MUTED)
	_stats.add_theme_font_size_override("font_size", 12)
	_top.add_child(_stats)

	_issue_btn = Button.new()
	_issue_btn.text = "✓ 无问题"
	_issue_btn.flat = true
	_issue_btn.add_theme_font_size_override("font_size", 12)
	_issue_btn.pressed.connect(_toggle_issues)
	_top.add_child(_issue_btn)

	var fit_btn := Button.new()
	fit_btn.text = "适应画布"
	fit_btn.flat = true
	fit_btn.add_theme_color_override("font_color", C_MUTED)
	fit_btn.add_theme_font_size_override("font_size", 12)
	fit_btn.pressed.connect(_fit_canvas)
	_top.add_child(fit_btn)

	var reset_btn := Button.new()
	reset_btn.text = "重置视图"
	reset_btn.flat = true
	reset_btn.add_theme_color_override("font_color", C_MUTED)
	reset_btn.add_theme_font_size_override("font_size", 12)
	reset_btn.pressed.connect(_reset_view)
	_top.add_child(reset_btn)

	_zoom_label = Label.new()
	_zoom_label.text = "100%"
	_zoom_label.add_theme_color_override("font_color", C_MUTED)
	_zoom_label.add_theme_font_size_override("font_size", 12)
	_zoom_label.custom_minimum_size.x = 42
	_zoom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_top.add_child(_zoom_label)

	_hint_wrap = PanelContainer.new()
	_hint_wrap.name = "HintBar"
	_hint_wrap.custom_minimum_size.y = HINT_H
	_hint_wrap.add_theme_stylebox_override("panel", _bar_style(false))
	_root.add_child(_hint_wrap)

	_hint_bar = HBoxContainer.new()
	_hint_bar.add_theme_constant_override("separation", 16)
	_hint_wrap.add_child(_hint_bar)

	_hint = Label.new()
	_hint.add_theme_color_override("font_color", Color("#5a6478"))
	_hint.add_theme_font_size_override("font_size", 11)
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 长提示文案不参与最小宽度计算，否则窗口一窄就把整个面板撑宽
	_hint.clip_text = true
	_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_hint.text = "拖节点移动 · 空白处拖动平移 · 滚轮缩放 · 从节点右侧圆点拖线连接 · 双击节点编辑 · Delete 删除"
	_hint_bar.add_child(_hint)

	_status = Label.new()
	_status.add_theme_color_override("font_color", Color("#8a9aaa"))
	_status.add_theme_font_size_override("font_size", 11)
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hint_bar.add_child(_status)

	_issue_panel = PanelContainer.new()
	_issue_panel.visible = false
	var psb := StyleBoxFlat.new()
	psb.bg_color = C_SURFACE
	psb.border_color = C_BORDER
	psb.set_border_width_all(1)
	psb.set_corner_radius_all(8)
	psb.content_margin_left = 10
	psb.content_margin_right = 10
	psb.content_margin_top = 8
	psb.content_margin_bottom = 8
	_issue_panel.add_theme_stylebox_override("panel", psb)
	# 浮层：靠锚点贴底，父节点尺寸变了自己会跟着走，不用手算
	_issue_panel.anchor_left = 0.0
	_issue_panel.anchor_right = 1.0
	_issue_panel.anchor_top = 1.0
	_issue_panel.anchor_bottom = 1.0
	_issue_panel.offset_left = 14
	_issue_panel.offset_right = -14
	_issue_panel.offset_top = -(HINT_H + 134)
	_issue_panel.offset_bottom = -(HINT_H + 6)
	add_child(_issue_panel)

	_issue_list = ItemList.new()
	_issue_list.add_theme_font_size_override("font_size", 12)
	_issue_panel.add_child(_issue_list)

	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_RESOURCES
	_file_dialog.use_native_dialog = false
	_file_dialog.file_selected.connect(_on_file_selected)
	add_child(_file_dialog)

	_dialog = AcceptDialog.new()
	_dialog.title = "编辑节点"
	_dialog.ok_button_text = "完成"
	_dialog.min_size = Vector2i(440, 200)
	add_child(_dialog)
	_dialog_body = VBoxContainer.new()
	_dialog_body.add_theme_constant_override("separation", 8)
	_dialog_body.custom_minimum_size = Vector2(410, 0)
	_dialog.add_child(_dialog_body)


## 顶栏 / 底栏的底板：底色 + 左右内边距，顶栏多一条下边线。
func _bar_style(with_bottom_line: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_SURFACE
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	if with_bottom_line:
		sb.border_color = C_BORDER
		sb.border_width_bottom = 1
	return sb


func _apply_graph_theme() -> void:
	var panel := StyleBoxFlat.new()
	panel.bg_color = C_BG
	panel.set_border_width_all(0)
	_graph.add_theme_stylebox_override("panel", panel)

	# 金褐色点阵，和参考源一致
	_graph.add_theme_color_override("grid_major", Color(C_ACCENT, 0.22))
	_graph.add_theme_color_override("grid_minor", Color(C_BORDER, 0.45))


## ---- 打开 / 保存 ----

func _open(p: String) -> void:
	var issues := _doc.load_from(p)
	_dirty = false
	_save_btn.text = "保存"
	_save_btn.add_theme_color_override("font_color", C_MUTED)
	_rebuild_all()
	if issues.size() > 0:
		_set_hint(String(issues[0]))
	else:
		_set_hint("已打开 %s" % p)


func _on_open_pressed() -> void:
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.filters = PackedStringArray(["*.json ; 图数据"])
	_file_dialog.set_meta("purpose", "open")
	_file_dialog.popup_centered_ratio(0.55)


func _on_save_pressed() -> void:
	var p := _doc.path.strip_edges()
	if p == "":
		_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_file_dialog.filters = PackedStringArray(["*.json ; 图数据"])
		_file_dialog.set_meta("purpose", "save")
		_file_dialog.popup_centered_ratio(0.55)
		return
	_save_to(p)


func _save_to(p: String) -> void:
	_sync_positions()
	_doc.path = p
	var err := _doc.save_to(p)
	if err != OK:
		_set_hint("保存失败：%s" % error_string(err))
		return
	_dirty = false
	_save_btn.text = "保存"
	_save_btn.add_theme_color_override("font_color", C_MUTED)
	_file_label.text = p.get_file()
	_file_label.tooltip_text = p
	_refresh_issues()
	_set_hint("已保存 %s" % p)


func _on_file_selected(p: String) -> void:
	var purpose := String(_file_dialog.get_meta("purpose", ""))
	match purpose:
		"open":
			_open(p)
		"save":
			_save_to(p)
		"chapter":
			var i := _doc.find_state(_dialog_id)
			if i >= 0:
				_doc.states[i]["chapter"] = p
				_touch()
				_rebuild_all()
				_open_dialog(_dialog_id)


## ---- 重建视图 ----

func _rebuild_all() -> void:
	_sync_positions()
	_graph.clear_connections()
	# 先摘出场景树再 queue_free：本方法会被 GraphEdit 的连线/删除信号回调调用，
	# 在信号处理链里立即 free() 节点是不安全的。
	for c in _graph.get_children():
		if c is GraphNode:
			_graph.remove_child(c)
			c.queue_free()
	for st in _doc.states:
		_add_node_ui(st)
	for tr in _doc.transitions:
		var f := _node_by_id(String(tr["from"]))
		var t := _node_by_id(String(tr["to"]))
		if f != null and t != null:
			_graph.connect_node(f.name, 0, t.name, 0)
	_file_label.text = _doc.path.get_file() if _doc.path != "" else ""
	_file_label.tooltip_text = _doc.path
	_refresh_stats()
	_refresh_issues()


func _add_node_ui(state: Dictionary) -> GraphNode:
	var id := String(state["id"])
	var kind := String(state["type"])
	var is_entry := id == _doc.entry

	var node := GraphNode.new()
	# 节点名必须是合法 NodePath，id 里若含 / : @ 会被引擎改名，导致 _id_of 找不回来。
	# 显示用的 title 仍是原 id，meta vn_id 也存原值。
	node.name = id.validate_node_name()
	node.title = ("▶ " if is_entry else "") + id
	node.position_offset = state["pos"]
	node.resizable = false
	node.set_meta("vn_id", id)
	node.set_meta("vn_type", kind)
	node.gui_input.connect(_on_node_gui_input.bind(node))
	_style_node(node, kind, is_entry)

	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 3)
	body.custom_minimum_size.x = 122
	node.add_child(body)

	var sub := Label.new()
	sub.name = "Sub"
	sub.add_theme_font_size_override("font_size", 12)
	if kind == "chapter":
		var path := String(state["chapter"])
		if path == "":
			sub.text = "未指定脚本"
			sub.add_theme_color_override("font_color", C_WARN)
		else:
			sub.text = path.get_file()
			sub.add_theme_color_override("font_color", C_MUTED)
		sub.tooltip_text = path
	else:
		sub.text = "终止"
		sub.add_theme_color_override("font_color", C_MUTED)
	body.add_child(sub)

	for tr in _doc.transitions:
		if String(tr["from"]) != id:
			continue
		var row := Label.new()
		var guard := String(tr["guard"])
		row.text = "→ %s" % tr["to"]
		if guard != "":
			row.text += "  ⟨%s⟩" % guard
		row.add_theme_font_size_override("font_size", 12)
		row.add_theme_color_override("font_color", C_ACCENT if guard == "" else C_MUTED)
		body.add_child(row)

	node.set_slot(0, true, 0, C_SCRIPT, true, 0, C_SCRIPT)
	_graph.add_child(node)
	node.reset_size()
	return node


func _style_node(node: GraphNode, kind: String, is_entry: bool) -> void:
	var accent := C_SCRIPT if kind == "chapter" else C_MUTED
	if is_entry:
		accent = C_ACCENT

	var titlebar := StyleBoxFlat.new()
	titlebar.bg_color = C_SURFACE_HI
	titlebar.border_color = accent
	titlebar.border_width_bottom = 2
	titlebar.corner_radius_top_left = 9
	titlebar.corner_radius_top_right = 9
	titlebar.content_margin_left = 11
	titlebar.content_margin_right = 11
	titlebar.content_margin_top = 6
	titlebar.content_margin_bottom = 6
	node.add_theme_stylebox_override("titlebar", titlebar)

	var panel := StyleBoxFlat.new()
	panel.bg_color = C_SURFACE
	panel.border_color = accent
	panel.set_border_width_all(1)
	panel.border_width_top = 0
	panel.corner_radius_bottom_left = 9
	panel.corner_radius_bottom_right = 9
	panel.content_margin_left = 10
	panel.content_margin_right = 10
	panel.content_margin_top = 6
	panel.content_margin_bottom = 8
	node.add_theme_stylebox_override("panel", panel)

	var panel_sel := panel.duplicate() as StyleBoxFlat
	panel_sel.border_color = C_ACCENT
	panel_sel.set_border_width_all(2)
	panel_sel.border_width_top = 0
	node.add_theme_stylebox_override("panel_selected", panel_sel)

	var titlebar_sel := titlebar.duplicate() as StyleBoxFlat
	titlebar_sel.border_color = C_ACCENT
	node.add_theme_stylebox_override("titlebar_selected", titlebar_sel)

	node.add_theme_color_override("title_color", C_TEXT)
	node.add_theme_font_size_override("title_font_size", 13)


## ---- 交互 ----

func _on_node_gui_input(event: InputEvent, node: GraphNode) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.double_click:
			_open_dialog(String(node.get_meta("vn_id", "")))
			accept_event()


func _open_dialog(id: String) -> void:
	_dialog_id = id
	var i := _doc.find_state(id)
	if i < 0:
		return
	var st: Dictionary = _doc.states[i]

	for c in _dialog_body.get_children():
		_dialog_body.remove_child(c)
		c.queue_free()

	_dialog.title = "编辑节点 · %s" % id

	if String(st["type"]) == "chapter":
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var lbl := Label.new()
		lbl.text = "章节脚本"
		lbl.custom_minimum_size.x = 72
		row.add_child(lbl)
		var path := LineEdit.new()
		path.text = String(st["chapter"])
		path.placeholder_text = "res://story/ch01.gd"
		path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		path.text_submitted.connect(func(t: String) -> void:
			_doc.set_state_chapter(id, t)
			_touch()
			_rebuild_all()
			_open_dialog(id)
		)
		row.add_child(path)
		var pick := Button.new()
		pick.text = "…"
		pick.pressed.connect(func() -> void:
			_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
			_file_dialog.filters = PackedStringArray(["*.gd ; 章节脚本"])
			_file_dialog.set_meta("purpose", "chapter")
			_file_dialog.popup_centered_ratio(0.55)
		)
		row.add_child(pick)
		_dialog_body.add_child(row)

	var edge_title := Label.new()
	edge_title.text = "出边（priority 小的先命中）"
	edge_title.add_theme_color_override("font_color", C_MUTED)
	edge_title.add_theme_font_size_override("font_size", 11)
	_dialog_body.add_child(edge_title)

	var has_edge := false
	for tr in _doc.transitions:
		if String(tr["from"]) != id:
			continue
		has_edge = true
		_dialog_body.add_child(_make_edge_row(tr))

	if not has_edge:
		var none := Label.new()
		none.text = "还没有出边。回到图上，从这个节点右侧的圆点拖到目标节点即可。"
		none.add_theme_color_override("font_color", C_MUTED)
		none.add_theme_font_size_override("font_size", 11)
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		none.custom_minimum_size.x = 390
		_dialog_body.add_child(none)

	_dialog.popup_centered()


func _make_edge_row(tr: Dictionary) -> Control:
	var from_id := String(tr["from"])
	var to_id := String(tr["to"])

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var arrow := Label.new()
	arrow.text = "→ %s" % to_id
	arrow.custom_minimum_size.x = 84
	row.add_child(arrow)

	var guard := LineEdit.new()
	guard.text = String(tr["guard"])
	guard.placeholder_text = "条件，空 = 默认"
	guard.tooltip_text = "只能引用参数表里的 id，例如 affection >= 5"
	guard.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	guard.text_changed.connect(func(t: String) -> void:
		var k := _doc.find_transition(from_id, to_id)
		if k >= 0:
			_doc.transitions[k]["guard"] = t
			_touch()
	)
	row.add_child(guard)

	var pri := SpinBox.new()
	pri.min_value = 1
	pri.max_value = 99
	pri.value = int(tr["priority"])
	pri.tooltip_text = "数字小的优先命中"
	pri.custom_minimum_size.x = 64
	pri.value_changed.connect(func(v: float) -> void:
		var k := _doc.find_transition(from_id, to_id)
		if k >= 0:
			_doc.transitions[k]["priority"] = int(v)
			_touch()
	)
	row.add_child(pri)

	var del := Button.new()
	del.text = "×"
	del.tooltip_text = "删除这条边"
	del.pressed.connect(func() -> void:
		var k := _doc.find_transition(from_id, to_id)
		if k >= 0:
			_doc.transitions.remove_at(k)
		_touch()
		_rebuild_all()
		_open_dialog(from_id)
	)
	row.add_child(del)

	return row


func _on_add_node(kind_id: int) -> void:
	var kind := "chapter" if kind_id == 0 else "end"
	var id := _doc.next_id("ch") if kind == "chapter" else "end"
	if _doc.find_state(id) >= 0:
		_set_hint("已存在节点 %s" % id)
		return
	var center := (_graph.scroll_offset + _graph.size * 0.5) / maxf(_graph.zoom, 0.01)
	var pos := center - Vector2(80, 40) + Vector2(0, 30 * _doc.states.size())
	if not _doc.add_state(id, kind, "", pos):
		return
	_add_node_ui(_doc.states[_doc.find_state(id)])
	_touch()
	_refresh_stats()
	_refresh_issues()


func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	var from_id := _id_of(String(from_node))
	var to_id := _id_of(String(to_node))
	if from_id == "" or to_id == "":
		return
	if from_id == to_id:
		_set_hint("不能连到自己")
		return
	if _doc.add_transition(from_id, to_id):
		_graph.connect_node(from_node, from_port, to_node, to_port)
		_touch()
		_rebuild_all()
	else:
		_set_hint("这条边已经存在")


func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	_graph.disconnect_node(from_node, from_port, to_node, to_port)
	var from_id := _id_of(String(from_node))
	var to_id := _id_of(String(to_node))
	var i := _doc.find_transition(from_id, to_id)
	if i >= 0:
		_doc.transitions.remove_at(i)
	_touch()
	_rebuild_all()


func _on_delete_nodes_request(nodes: Array) -> void:
	var ids: Array = []
	for n in nodes:
		var id := _id_of(String(n))
		if id != "":
			ids.append(id)
	for id in ids:
		_doc.remove_state(String(id))
	_rebuild_all()
	_touch()


func _fit_canvas() -> void:
	var rect := Rect2()
	var first := true
	for n in _graph.get_children():
		if not n is GraphNode:
			continue
		var gn := n as GraphNode
		var r := Rect2(gn.position_offset, gn.size)
		rect = r if first else rect.merge(r)
		first = false
	if first:
		return
	_graph.zoom = clampf(minf(
		_graph.size.x / maxf(rect.size.x + 160.0, 1.0),
		_graph.size.y / maxf(rect.size.y + 160.0, 1.0)), 0.25, 1.2)
	# scroll_offset 的单位是图坐标（屏幕像素 / zoom），所以只有 size 那一半要除 zoom，
	# 整体不能再乘回 zoom。
	_graph.scroll_offset = rect.get_center() - _graph.size * 0.5 / _graph.zoom
	_last_zoom = _graph.zoom
	_zoom_label.text = "%d%%" % roundi(_graph.zoom * 100.0)


func _reset_view() -> void:
	_graph.zoom = 1.0
	_graph.scroll_offset = Vector2.ZERO
	_last_zoom = 1.0
	_zoom_label.text = "100%"


func _toggle_issues() -> void:
	if _issue_panel != null:
		_issue_panel.visible = not _issue_panel.visible


## ---- 辅助 ----

func _sync_positions() -> void:
	for n in _graph.get_children():
		if n is GraphNode and n.has_meta("vn_id"):
			_doc.set_state_pos(String(n.get_meta("vn_id")), (n as GraphNode).position_offset)


func _node_by_id(id: String) -> GraphNode:
	for n in _graph.get_children():
		if n is GraphNode and String(n.get_meta("vn_id", "")) == id:
			return n
	return null


func _id_of(node_name: String) -> String:
	var n := _graph.get_node_or_null(NodePath(node_name))
	if n == null or not n.has_meta("vn_id"):
		return ""
	return String(n.get_meta("vn_id"))


func _refresh_stats() -> void:
	var count := 0
	for n in _graph.get_children():
		if n is GraphNode:
			count += 1
	_stats.text = "%d 节点 · %d 连线" % [count, _doc.transitions.size()]


func _touch() -> void:
	_dirty = true
	_save_btn.text = "保存 •"
	_save_btn.add_theme_color_override("font_color", C_ACCENT)


func _set_hint(msg: String) -> void:
	if _status != null:
		_status.text = msg


func _refresh_issues() -> void:
	if _issue_list == null:
		return
	_issue_list.clear()
	var g := StoryGraph.load_dict(_doc.to_dict())
	for m in g.errors:
		var i := _issue_list.add_item("错误  %s" % m)
		_issue_list.set_item_custom_fg_color(i, C_ERROR)
	for m in g.warnings:
		var i := _issue_list.add_item("提示  %s" % m)
		_issue_list.set_item_custom_fg_color(i, C_WARN)

	if g.errors.size() > 0:
		_issue_btn.text = "✕ %d 个错误" % g.errors.size()
		_issue_btn.add_theme_color_override("font_color", C_ERROR)
	elif g.warnings.size() > 0:
		_issue_btn.text = "⚠ %d 个提示" % g.warnings.size()
		_issue_btn.add_theme_color_override("font_color", C_WARN)
	else:
		_issue_btn.text = "✓ 无问题"
		_issue_btn.add_theme_color_override("font_color", C_MUTED)

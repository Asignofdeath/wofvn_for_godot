## 立绘摆位面板：可视化调槽位与每个角色的偏移/缩放，产出 stage_layout.json。
##
## 只做一件事：编辑那份 JSON。不生成节点、不改场景、不带美术资源。
## 摆位几何由 VNStageLayout.place() 提供，和运行时用的是同一份算法，
## 所以「面板里看到的位置」和「游戏里出现的位置」不会不一致。
@tool
extends Control

const DEFAULT_LAYOUT := "res://stage/stage_layout.json"

const TOP_H := 52
const HINT_H := 26
const SIDE_W := 262
const CANVAS_RATIO := 16.0 / 9.0

var _lay := VNStageLayout.new()
var _dirty := false

## 布局骨架：顶栏固定 / 主体抢剩余 / 底栏固定
var _root: VBoxContainer
var _top_wrap: PanelContainer
var _top: HBoxContainer
var _hint_wrap: PanelContainer
var _hint: Label
var _status: Label

## 主体：左边预览，右边参数
var _body: HBoxContainer
var _preview_wrap: PanelContainer
var _aspect: AspectRatioContainer
var _canvas: Panel
var _side: PanelContainer

## 侧栏分两块：名字行常驻（重建会丢用户输入），其余每次重建
var _name_box: VBoxContainer
var _dyn_box: VBoxContainer

## 顶栏控件
var _file_label: Label
var _save_btn: Button
var _show_all_chk: CheckBox

## 名字行
var _who_edit: LineEdit
var _pose_edit: LineEdit

## 动态部分（每次重建）
var _slot_opt: OptionButton
var _s_char_scale: HSlider
var _s_off_x: HSlider
var _s_off_y: HSlider
var _s_slot_x: HSlider
var _s_slot_scale: HSlider
var _v_char_scale: Label
var _v_off_x: Label
var _v_off_y: Label
var _v_slot_x: Label
var _v_slot_scale: Label

var _file_dialog: FileDialog

## slot 名 -> 预览里的容器
var _holders: Dictionary = {}
## 当前选中的槽位。下拉重建后靠它恢复选中项
var _slot_sel := "center"
## 扫描出来的素材名，给 ▾ 菜单用
var _scan_chars: PackedStringArray = PackedStringArray()
var _scan_poses: PackedStringArray = PackedStringArray()

## 「滑条改数据 → 刷新预览 → 回写滑条」会打架，回写时把信号关掉
var _syncing := false
var _dragging := false


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_ui()
	_build_name_rows()

	_lay.reset()
	_lay.path = DEFAULT_LAYOUT
	if FileAccess.file_exists(DEFAULT_LAYOUT):
		for msg in _lay.load_from(DEFAULT_LAYOUT):
			_set_hint(msg)
		_set_status("已打开 %s" % DEFAULT_LAYOUT)
	else:
		_set_hint("还没有 %s。调好位置后点「保存」生成。" % DEFAULT_LAYOUT)

	_scan_assets()
	_rebuild_side()
	_refresh_preview()


## ---- 布局 ----
##
## 和 flow_screen 同一套：本节点挂 EXPAND_FILL，内部 VBox 排队，不写 position/size 手算。
## 预览区用 AspectRatioContainer 锁 16:9，不用自己算黑边。

func _build_ui() -> void:
	_root = VBoxContainer.new()
	_root.name = "Root"
	_root.add_theme_constant_override("separation", 0)
	add_child(_root)
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_top_wrap = PanelContainer.new()
	_top_wrap.name = "TopBar"
	_top_wrap.custom_minimum_size.y = TOP_H
	_top_wrap.add_theme_stylebox_override("panel", VNEditorTheme.bar_style(true))
	_root.add_child(_top_wrap)

	var top_scroll := ScrollContainer.new()
	top_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	top_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_top_wrap.add_child(top_scroll)

	_top = HBoxContainer.new()
	_top.add_theme_constant_override("separation", 10)
	top_scroll.add_child(_top)

	var open_btn := Button.new()
	open_btn.text = "打开"
	open_btn.flat = true
	open_btn.add_theme_color_override("font_color", VNEditorTheme.MUTED)
	open_btn.pressed.connect(_on_open_pressed)
	_top.add_child(open_btn)

	_save_btn = Button.new()
	_save_btn.text = "保存"
	_save_btn.flat = true
	_save_btn.add_theme_color_override("font_color", VNEditorTheme.MUTED)
	_save_btn.pressed.connect(_on_save_pressed)
	_top.add_child(_save_btn)

	var sep := VSeparator.new()
	sep.add_theme_color_override("separator", VNEditorTheme.BORDER)
	_top.add_child(sep)

	var title := Label.new()
	title.text = "立绘摆位"
	title.add_theme_color_override("font_color", VNEditorTheme.ACCENT)
	title.add_theme_font_size_override("font_size", 14)
	_top.add_child(title)

	_file_label = Label.new()
	_file_label.add_theme_color_override("font_color", VNEditorTheme.MUTED)
	_file_label.add_theme_font_size_override("font_size", 12)
	_file_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 顶栏在 ScrollContainer 里只按最小宽度分配，带 ellipsis 的 Label 最小宽度是 1，
	# 不给下限的话文件名会被压成 0 宽。
	_file_label.custom_minimum_size.x = 130
	_file_label.clip_text = true
	_file_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_top.add_child(_file_label)

	_show_all_chk = CheckBox.new()
	_show_all_chk.text = "显示全部槽位"
	_show_all_chk.button_pressed = true
	_show_all_chk.add_theme_color_override("font_color", VNEditorTheme.MUTED)
	_show_all_chk.add_theme_font_size_override("font_size", 12)
	_show_all_chk.toggled.connect(func(_on: bool) -> void: _refresh_preview())
	_top.add_child(_show_all_chk)

	_body = HBoxContainer.new()
	_body.name = "Body"
	_body.add_theme_constant_override("separation", 0)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(_body)

	_preview_wrap = PanelContainer.new()
	_preview_wrap.name = "Preview"
	_preview_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var preview_sb := StyleBoxFlat.new()
	preview_sb.bg_color = Color("#11151c")
	preview_sb.content_margin_left = 10
	preview_sb.content_margin_right = 10
	preview_sb.content_margin_top = 10
	preview_sb.content_margin_bottom = 10
	_preview_wrap.add_theme_stylebox_override("panel", preview_sb)
	_body.add_child(_preview_wrap)

	_aspect = AspectRatioContainer.new()
	_aspect.name = "Aspect"
	_aspect.ratio = CANVAS_RATIO
	_aspect.stretch_mode = AspectRatioContainer.STRETCH_FIT
	_aspect.alignment_horizontal = AspectRatioContainer.ALIGNMENT_CENTER
	_aspect.alignment_vertical = AspectRatioContainer.ALIGNMENT_CENTER
	_preview_wrap.add_child(_aspect)

	_canvas = Panel.new()
	_canvas.name = "Canvas"
	_canvas.clip_contents = true
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	var canvas_sb := StyleBoxFlat.new()
	canvas_sb.bg_color = VNEditorTheme.BG
	canvas_sb.border_color = VNEditorTheme.BORDER
	canvas_sb.set_border_width_all(1)
	_canvas.add_theme_stylebox_override("panel", canvas_sb)
	_canvas.gui_input.connect(_on_canvas_input)
	_canvas.resized.connect(_refresh_preview)
	_aspect.add_child(_canvas)

	# 地面参考线：立绘脚底就该贴在这
	var ground := ColorRect.new()
	ground.name = "Ground"
	ground.color = Color(VNEditorTheme.ACCENT, 0.35)
	ground.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ground.anchor_left = 0.0
	ground.anchor_right = 1.0
	ground.anchor_top = 1.0
	ground.anchor_bottom = 1.0
	ground.offset_top = -1
	ground.offset_bottom = 0
	_canvas.add_child(ground)

	_side = PanelContainer.new()
	_side.name = "Side"
	_side.custom_minimum_size.x = SIDE_W
	var side_sb := StyleBoxFlat.new()
	side_sb.bg_color = VNEditorTheme.SURFACE
	side_sb.border_color = VNEditorTheme.BORDER
	side_sb.border_width_left = 1
	side_sb.content_margin_left = 12
	side_sb.content_margin_right = 12
	side_sb.content_margin_top = 10
	side_sb.content_margin_bottom = 10
	_side.add_theme_stylebox_override("panel", side_sb)
	_body.add_child(_side)

	var side_scroll := ScrollContainer.new()
	side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_side.add_child(side_scroll)

	var side_box := VBoxContainer.new()
	side_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side_box.add_theme_constant_override("separation", 6)
	side_scroll.add_child(side_box)

	_name_box = VBoxContainer.new()
	_name_box.add_theme_constant_override("separation", 6)
	side_box.add_child(_name_box)

	_dyn_box = VBoxContainer.new()
	_dyn_box.add_theme_constant_override("separation", 6)
	side_box.add_child(_dyn_box)

	_hint_wrap = PanelContainer.new()
	_hint_wrap.name = "HintBar"
	_hint_wrap.custom_minimum_size.y = HINT_H
	_hint_wrap.add_theme_stylebox_override("panel", VNEditorTheme.bar_style(false))
	_root.add_child(_hint_wrap)

	var hint_bar := HBoxContainer.new()
	hint_bar.add_theme_constant_override("separation", 16)
	_hint_wrap.add_child(hint_bar)

	_hint = Label.new()
	_hint.add_theme_color_override("font_color", Color("#5a6478"))
	_hint.add_theme_font_size_override("font_size", 11)
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint.clip_text = true
	_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_hint.text = "拖动画面里的立绘调偏移 · 槽位 X 决定站位 · 没有图时用占位色块"
	hint_bar.add_child(_hint)

	_status = Label.new()
	_status.add_theme_color_override("font_color", VNEditorTheme.MUTED)
	_status.add_theme_font_size_override("font_size", 11)
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.clip_text = true
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hint_bar.add_child(_status)

	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_RESOURCES
	_file_dialog.use_native_dialog = false
	_file_dialog.file_selected.connect(_on_file_selected)
	add_child(_file_dialog)


## 角色 / 表情两行常驻，不随重建消失（否则每次保存后用户输入的名字就没了）。
func _build_name_rows() -> void:
	_who_edit = LineEdit.new()
	_who_edit.text = "凛"
	_who_edit.placeholder_text = "角色名（可以是还没画的）"
	_who_edit.text_changed.connect(func(_t: String) -> void:
		_scan_poses = _scan_poses_of(_current_who())
		_refresh_preview()
	)
	_name_box.add_child(_labeled(_who_edit, _pick_button(_who_edit, true), "角色"))

	_pose_edit = LineEdit.new()
	_pose_edit.text = "default"
	_pose_edit.placeholder_text = "表情名"
	_pose_edit.text_changed.connect(func(_t: String) -> void: _refresh_preview())
	_name_box.add_child(_labeled(_pose_edit, _pick_button(_pose_edit, false), "表情"))


## ---- 侧栏（动态部分） ----

func _rebuild_side() -> void:
	for c in _dyn_box.get_children():
		_dyn_box.remove_child(c)
		c.queue_free()
	for c in _canvas.get_children():
		if c is Control and String(c.name).begins_with("Holder"):
			_canvas.remove_child(c)
			c.queue_free()
	_holders.clear()

	_dyn_box.add_child(_section("槽位"))
	_slot_opt = OptionButton.new()
	var names := _lay.slot_names()
	var idx := 0
	for i in names.size():
		_slot_opt.add_item(names[i])
		if names[i] == _slot_sel:
			idx = i
	_slot_opt.select(idx)
	_slot_sel = _slot_opt.get_item_text(idx)
	_slot_opt.item_selected.connect(func(i: int) -> void:
		_slot_sel = _slot_opt.get_item_text(i)
		_sync_sliders()
		_refresh_preview()
	)
	_dyn_box.add_child(_slot_opt)

	_s_slot_x = _make_slider(0.0, 1.0, 0.005)
	_v_slot_x = _add_slider_row("槽位 X", _s_slot_x)
	_s_slot_x.value_changed.connect(func(v: float) -> void:
		if _syncing:
			return
		_lay.set_slot(_current_slot(), v, _s_slot_scale.value)
		_touch()
		_refresh_preview()
	)

	_s_slot_scale = _make_slider(0.3, 2.0, 0.01)
	_v_slot_scale = _add_slider_row("槽位缩放", _s_slot_scale)
	_s_slot_scale.value_changed.connect(func(v: float) -> void:
		if _syncing:
			return
		_lay.set_slot(_current_slot(), _s_slot_x.value, v)
		_touch()
		_refresh_preview()
	)

	_dyn_box.add_child(_section("角色微调"))
	_s_char_scale = _make_slider(0.3, 2.0, 0.01)
	_v_char_scale = _add_slider_row("整体缩放", _s_char_scale)
	_s_char_scale.value_changed.connect(func(v: float) -> void:
		if _syncing:
			return
		var c := _lay.character(_current_who())
		_lay.set_character(_current_who(), c["offset"], v)
		_touch()
		_refresh_preview()
	)

	_s_off_x = _make_slider(-600.0, 600.0, 1.0)
	_v_off_x = _add_slider_row("左右偏移", _s_off_x)
	_s_off_x.value_changed.connect(func(v: float) -> void:
		if _syncing:
			return
		var c := _lay.character(_current_who())
		_lay.set_character(_current_who(), Vector2(v, c["offset"].y), c["scale"])
		_touch()
		_refresh_preview()
	)

	_s_off_y = _make_slider(-600.0, 600.0, 1.0)
	_v_off_y = _add_slider_row("上下偏移", _s_off_y)
	_s_off_y.value_changed.connect(func(v: float) -> void:
		if _syncing:
			return
		var c := _lay.character(_current_who())
		_lay.set_character(_current_who(), Vector2(c["offset"].x, v), c["scale"])
		_touch()
		_refresh_preview()
	)

	var reset_btn := Button.new()
	reset_btn.text = "当前角色归零"
	reset_btn.tooltip_text = "偏移清零、缩放回 1.0"
	reset_btn.pressed.connect(func() -> void:
		_lay.set_character(_current_who(), Vector2.ZERO, 1.0)
		_touch()
		_sync_sliders()
		_refresh_preview()
	)
	_dyn_box.add_child(reset_btn)

	_dyn_box.add_child(_section("素材"))
	var info := Label.new()
	info.add_theme_color_override("font_color", VNEditorTheme.MUTED)
	info.add_theme_font_size_override("font_size", 11)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.text = "约定：%s/<角色>/<表情>.png\n扫描到 %d 个角色目录" % [
		_lay.chara_dir, _scan_chars.size()]
	_dyn_box.add_child(info)

	_build_holders()
	_sync_sliders()
	_update_file_label()
	# 重建后立刻按新数据摆一遍：否则要等下一次刷新（窗口 resize / 拖滑块）才对位
	_refresh_preview()


## 预览里每个槽位一个容器，用 VNStageLayout.place() 摆（和运行时同一份算法）。
func _build_holders() -> void:
	var tex := _current_texture()
	for slot_name in _lay.slot_names():
		var holder := Control.new()
		holder.name = "Holder_%s" % slot_name
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.clip_contents = true
		_canvas.add_child(holder)

		var img := TextureRect.new()
		img.name = "Img"
		img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		img.mouse_filter = Control.MOUSE_FILTER_IGNORE
		img.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		img.texture = tex
		img.visible = tex != null
		holder.add_child(img)

		var ph := ColorRect.new()
		ph.name = "Ph"
		ph.color = Color(0.62, 0.68, 0.80, 0.5)
		ph.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		ph.visible = tex == null
		holder.add_child(ph)

		var lb := Label.new()
		lb.name = "PhLabel"
		lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lb.add_theme_color_override("font_color", Color(0.92, 0.94, 0.98))
		lb.add_theme_font_size_override("font_size", 14)
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		lb.visible = tex == null
		holder.add_child(lb)

		_holders[slot_name] = holder


## ---- 预览 ----

func _refresh_preview() -> void:
	if _canvas == null or not is_instance_valid(_canvas):
		return
	if _canvas.size.x <= 0.0 or _lay.canvas.x <= 0:
		return

	# 画布坐标 → 预览像素的换算（预览是缩小版，尺寸和偏移都要跟着缩）
	var k := _canvas.size.x / float(_lay.canvas.x)
	var who := _current_who()
	var pose := _current_pose()
	var tex := _current_texture()
	var offset: Vector2 = _lay.character(who)["offset"]
	var show_all := _show_all_chk != null and _show_all_chk.button_pressed
	var cur_slot := _current_slot()

	for slot_name in _holders:
		var holder: Control = _holders[slot_name]
		holder.visible = show_all or slot_name == cur_slot
		var px := _lay.sprite_px(tex, who, slot_name) * k
		VNStageLayout.place(holder, float(_lay.slot(slot_name)["x"]), px, offset * k)

		var img: TextureRect = holder.get_node_or_null("Img")
		if img != null:
			img.texture = tex
			img.visible = tex != null
		var ph := holder.get_node_or_null("Ph")
		if ph != null:
			(ph as ColorRect).visible = tex == null
		var lb := holder.get_node_or_null("PhLabel")
		if lb != null:
			(lb as Label).visible = tex == null
			(lb as Label).text = "%s\n%s" % [who, pose]


## ---- 交互 ----

func _on_canvas_input(event: InputEvent) -> void:
	if _current_who() == "":
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		var k := _canvas.size.x / maxf(float(_lay.canvas.x), 1.0)
		var delta := motion.relative / maxf(k, 0.0001)
		var c := _lay.character(_current_who())
		_lay.set_character(_current_who(), c["offset"] + delta, c["scale"])
		_touch()
		_sync_sliders()
		_refresh_preview()


## ---- 打开 / 保存 ----

func _on_open_pressed() -> void:
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.filters = PackedStringArray(["*.json ; 舞台数据"])
	_file_dialog.set_meta("purpose", "open")
	_file_dialog.popup_centered_ratio(0.55)


func _on_save_pressed() -> void:
	if _lay.path == "":
		_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_file_dialog.filters = PackedStringArray(["*.json ; 舞台数据"])
		_file_dialog.current_file = "stage_layout.json"
		_file_dialog.set_meta("purpose", "save")
		_file_dialog.popup_centered_ratio(0.55)
		return
	_save_to(_lay.path)


func _save_to(p: String) -> void:
	var err := _lay.save_to(p)
	if err != OK:
		_set_status("保存失败：%s" % error_string(err))
		return
	_dirty = false
	_save_btn.text = "保存"
	_save_btn.add_theme_color_override("font_color", VNEditorTheme.MUTED)
	_update_file_label()
	_set_status("已保存 %s" % p)


func _on_file_selected(p: String) -> void:
	match String(_file_dialog.get_meta("purpose", "")):
		"open":
			var issues := _lay.load_from(p)
			_scan_assets()
			_rebuild_side()
			_refresh_preview()
			_set_status(String(issues[0]) if issues.size() > 0 else "已打开 %s" % p)
		"save":
			_save_to(p)


## ---- 素材扫描（只给 ▾ 菜单用，不参与加载） ----

func _scan_assets() -> void:
	_scan_chars = PackedStringArray()
	var dir := DirAccess.open(_lay.chara_dir)
	if dir != null:
		var dirs: PackedStringArray = []
		dir.list_dir_begin()
		var entry := dir.get_next()
		while entry != "":
			if dir.current_is_dir() and not entry.begins_with("."):
				dirs.append(entry)
			entry = dir.get_next()
		dir.list_dir_end()
		dirs.sort()
		_scan_chars = dirs
	_scan_poses = _scan_poses_of(_current_who())


func _scan_poses_of(who: String) -> PackedStringArray:
	var out: PackedStringArray = []
	if who == "":
		return out
	var dir := DirAccess.open("%s/%s" % [_lay.chara_dir.trim_suffix("/"), who])
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var lower := entry.to_lower()
		if not dir.current_is_dir():
			for ext in VNStageLayout.IMAGE_EXTS:
				if lower.ends_with("." + ext):
					out.append(entry.get_basename())
					break
		entry = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _pick_button(edit: LineEdit, is_who: bool) -> Button:
	var btn := Button.new()
	btn.text = "▾"
	btn.flat = true
	btn.tooltip_text = "扫描 %s 下的素材" % ("角色目录" if is_who else "当前角色的表情")
	btn.pressed.connect(func() -> void:
		if is_who:
			_scan_assets()
		else:
			_scan_poses = _scan_poses_of(_current_who())
		var names := _scan_chars if is_who else _scan_poses
		_popup_names(btn, names, func(picked: String) -> void:
			edit.text = picked
			if is_who:
				_scan_poses = _scan_poses_of(picked)
			_refresh_preview()
		)
	)
	return btn


func _popup_names(anchor: Control, names: PackedStringArray, on_pick: Callable) -> void:
	var menu := PopupMenu.new()
	add_child(menu)
	if names.is_empty():
		menu.add_item("（目录里没有素材）")
		menu.set_item_disabled(0, true)
	for n in names:
		menu.add_item(n)
	menu.id_pressed.connect(func(i: int) -> void: on_pick.call(names[i]))
	menu.popup_hide.connect(menu.queue_free)
	menu.position = Vector2i(anchor.get_screen_position() + Vector2(0, anchor.size.y))
	menu.popup()


## ---- 辅助 ----

func _current_who() -> String:
	if _who_edit == null or not is_instance_valid(_who_edit):
		return ""
	return _who_edit.text.strip_edges()


func _current_pose() -> String:
	if _pose_edit == null or not is_instance_valid(_pose_edit):
		return "default"
	var t := _pose_edit.text.strip_edges()
	return t if t != "" else "default"


func _current_slot() -> String:
	if _slot_opt == null or not is_instance_valid(_slot_opt) or _slot_opt.selected < 0:
		return _slot_sel
	return _slot_opt.get_item_text(_slot_opt.selected)


func _current_texture() -> Texture2D:
	var who := _current_who()
	if who == "":
		return null
	return VNStageLayout.load_texture(_lay.chara_path(who, _current_pose()))


## 滑条值 ← 数据。回写时关信号，避免「改数据 → 刷新 → 又改数据」的回环。
func _sync_sliders() -> void:
	if _s_slot_x == null or not is_instance_valid(_s_slot_x):
		return
	_syncing = true
	var s := _lay.slot(_current_slot())
	var c := _lay.character(_current_who())
	var off: Vector2 = c["offset"]
	_s_slot_x.set_value_no_signal(float(s["x"]))
	_s_slot_scale.set_value_no_signal(float(s["scale"]))
	_s_char_scale.set_value_no_signal(float(c["scale"]))
	_s_off_x.set_value_no_signal(off.x)
	_s_off_y.set_value_no_signal(off.y)
	_syncing = false
	_v_slot_x.text = "%.2f" % float(s["x"])
	_v_slot_scale.text = "%.2f" % float(s["scale"])
	_v_char_scale.text = "%.2f" % float(c["scale"])
	_v_off_x.text = "%d" % int(off.x)
	_v_off_y.text = "%d" % int(off.y)


func _labeled(main: Control, extra: Button, label_text: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lb := Label.new()
	lb.text = label_text
	lb.custom_minimum_size.x = 34
	lb.add_theme_color_override("font_color", VNEditorTheme.MUTED)
	lb.add_theme_font_size_override("font_size", 12)
	row.add_child(lb)
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(main)
	if extra != null:
		row.add_child(extra)
	return row


func _make_slider(min_v: float, max_v: float, step: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size.y = 18
	return s


func _add_slider_row(label_text: String, slider: HSlider) -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lb := Label.new()
	lb.text = label_text
	lb.custom_minimum_size.x = 62
	lb.add_theme_color_override("font_color", VNEditorTheme.MUTED)
	lb.add_theme_font_size_override("font_size", 12)
	row.add_child(lb)
	row.add_child(slider)
	var val := Label.new()
	val.custom_minimum_size.x = 42
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.add_theme_color_override("font_color", VNEditorTheme.TEXT)
	val.add_theme_font_size_override("font_size", 12)
	row.add_child(val)
	_dyn_box.add_child(row)
	return val


func _section(text: String) -> Control:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 2)
	wrap.add_child(HSeparator.new())
	var lb := Label.new()
	lb.text = text
	lb.add_theme_color_override("font_color", VNEditorTheme.ACCENT)
	lb.add_theme_font_size_override("font_size", 12)
	wrap.add_child(lb)
	return wrap


func _update_file_label() -> void:
	if _file_label == null:
		return
	_file_label.text = _lay.path.get_file() if _lay.path != "" else "（未保存）"
	_file_label.tooltip_text = _lay.path


func _touch() -> void:
	if _dirty:
		return
	_dirty = true
	_save_btn.text = "保存 •"
	_save_btn.add_theme_color_override("font_color", VNEditorTheme.ACCENT)


func _set_hint(msg: String) -> void:
	if _hint != null:
		_hint.text = msg
		_hint.tooltip_text = msg


func _set_status(msg: String) -> void:
	if _status != null:
		_status.text = msg
		_status.tooltip_text = msg

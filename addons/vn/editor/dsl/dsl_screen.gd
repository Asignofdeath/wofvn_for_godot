## 剧本面板：编 .script.txt，实时看解析结果与生成物。
##
## 与编译器的边界（别越界）：
##   - 这里只做「编辑 + 反馈」，不认识任何指令语义，全部走 Parser / Emitter
##   - 零草稿层：缓冲区就是文件内容。脏就是脏，编译前一定先落盘
##   - 通用编辑能力（撤销 / 缩进 / 多光标 / 中文输入）全部由 CodeEdit 提供，
##     自己不实现；只加与 DSL 语义绑定的三样：插入模板、补全候选、错误行标色
##
## 删掉这个文件，编译器、CLI、运行时一样都不少。
@tool
extends Control

const T := preload("res://addons/vn/editor/vn_theme.gd")
const Parser := preload("res://addons/vn/editor/dsl/dsl_parser.gd")
const Emitter := preload("res://addons/vn/editor/dsl/dsl_emit.gd")
const Compiler := preload("res://addons/vn/editor/dsl/dsl_compile.gd")
const Highlighter := preload("res://addons/vn/editor/dsl/dsl_highlighter.gd")

const TOP_H := 52
const INSERT_H := 34
const HINT_H := 26
## 解析防抖：每次按键都跑一趟 parser 也不会慢（纯字符串），
## 但连续输入时没必要，等手停一下再算。
const PARSE_DELAY := 0.18

## 侧栏最小宽度。窄于这个值，预览里的生成代码会折行到看不清。
const SIDE_MIN_W := 330

## 顶层布局
var _root: VBoxContainer
var _top: HBoxContainer
var _insert_bar: HBoxContainer
var _split: HSplitContainer
var _bottom: HBoxContainer

## 顶栏
var _file_label: Label
var _stats: Label
var _save_btn: Button
var _compile_btn: Button

## 正文与侧栏
var _code: CodeEdit
var _preview_head: Label
var _preview: CodeEdit
var _issues: ItemList

## 底栏
var _hint: Label
var _product: Label

var _file_dialog: FileDialog

## 当前打开的文件（res:// 路径）。空串 = 没打开任何文件
var _src := ""
## 缓冲区与磁盘不一致。只影响显示和按钮文案，不阻止任何操作
var _dirty := false
## 距离下一次解析还剩多少秒；<= 0 表示不用解析
var _parse_left := 0.0
## 上次解析出来的错误行（1 基），换颜色前要先擦掉旧的
var _error_lines: Array = []


func _ready() -> void:
	_build()
	_parse_now()
	_code.grab_focus.call_deferred()
	_set_hint("打开一份 .script.txt 开始。")


## ---- 布局 ----

func _build() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	_root = VBoxContainer.new()
	_root.name = "Root"
	_root.add_theme_constant_override("separation", 0)
	add_child(_root)
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_build_top()
	_build_insert_bar()
	_build_body()
	_build_bottom()

	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_RESOURCES
	_file_dialog.use_native_dialog = false
	_file_dialog.filters = PackedStringArray(["*.script.txt ; 剧本源文件", "*.txt ; 文本"])
	_file_dialog.file_selected.connect(_open)
	add_child(_file_dialog)


func _build_top() -> void:
	var wrap := PanelContainer.new()
	wrap.name = "TopBar"
	wrap.custom_minimum_size.y = TOP_H
	wrap.add_theme_stylebox_override("panel", T.bar_style(true))
	_root.add_child(wrap)

	# 顶栏只有三个按钮，不需要横向滚动；套 ScrollContainer 会让 EXPAND 失效，
	# 文件名撑不开、统计被顶到中间（试过，别回去）
	_top = HBoxContainer.new()
	_top.add_theme_constant_override("separation", 10)
	wrap.add_child(_top)

	var open_btn := T.flat_button("打开")
	open_btn.pressed.connect(func() -> void:
		_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.popup_centered_ratio(0.55)
	)
	_top.add_child(open_btn)

	_save_btn = T.flat_button("保存")
	_save_btn.tooltip_text = "把正文写回源文件（Ctrl+S）。这里没有草稿层，不保存就等于没改"
	_save_btn.pressed.connect(_save)
	_top.add_child(_save_btn)

	_compile_btn = T.flat_button("编译", false)
	_compile_btn.tooltip_text = "先落盘，再生成同名 .gd。产物被手改过会拒绝覆盖"
	_compile_btn.pressed.connect(_save_and_compile)
	_top.add_child(_compile_btn)

	var sep := VSeparator.new()
	sep.add_theme_color_override("separator", T.BORDER)
	_top.add_child(sep)

	_file_label = Label.new()
	_file_label.text = "未打开"
	_file_label.add_theme_color_override("font_color", T.ACCENT)
	_file_label.add_theme_font_size_override("font_size", 13)
	_file_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 带 ellipsis 的 Label 最小宽度是 1，不显式给下限会被压成 0 宽（看起来是空的）
	_file_label.custom_minimum_size.x = 150
	_file_label.clip_text = true
	_file_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_top.add_child(_file_label)

	_stats = Label.new()
	_stats.add_theme_color_override("font_color", T.MUTED)
	_stats.add_theme_font_size_override("font_size", 12)
	_top.add_child(_stats)


## 按钮墙。全部来自 Emitter.SNIPPETS，一条不硬编码——
## 加指令只改表，面板自动多一个按钮。
func _build_insert_bar() -> void:
	var wrap := PanelContainer.new()
	wrap.name = "InsertBar"
	wrap.custom_minimum_size.y = INSERT_H
	var sb := StyleBoxFlat.new()
	sb.bg_color = T.SURFACE
	sb.border_color = T.BORDER
	sb.border_width_bottom = 1
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	wrap.add_theme_stylebox_override("panel", sb)
	_root.add_child(wrap)

	var scroll := ScrollContainer.new()
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	wrap.add_child(scroll)

	_insert_bar = HBoxContainer.new()
	_insert_bar.add_theme_constant_override("separation", 4)
	scroll.add_child(_insert_bar)

	for pair in Emitter.snippet_groups():
		var group_name := String(pair[0])
		if _insert_bar.get_child_count() > 0:
			var sep := VSeparator.new()
			sep.add_theme_color_override("separator", T.BORDER)
			_insert_bar.add_child(sep)
		var tag := Label.new()
		tag.text = group_name
		# 分组标签用 MUTED 而不是 FAINT：11px 的 FAINT 在 #1a1f28 上几乎看不见
		tag.add_theme_color_override("font_color", T.MUTED)
		tag.add_theme_font_size_override("font_size", 11)
		tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_insert_bar.add_child(tag)
		for s in pair[1]:
			var b := Button.new()
			b.text = String(s["label"])
			b.flat = true
			b.tooltip_text = String(s["hint"])
			b.add_theme_color_override("font_color", T.TEXT)
			b.add_theme_font_size_override("font_size", 12)
			b.pressed.connect(_insert_snippet.bind(s))
			_insert_bar.add_child(b)


func _build_body() -> void:
	_split = HSplitContainer.new()
	_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(_split)

	_code = CodeEdit.new()
	_code.name = "Source"
	_code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_code.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	_code.add_theme_font_size_override("font_size", 14)
	# 行号是 TextEdit 自带的一层开关，不是 gutter（GutterType 里没有「行号」这种）
	_code.gutters_draw_line_numbers = true
	var hl := Highlighter.new()
	hl.bind(_code)
	_code.syntax_highlighter = hl
	_code.text_changed.connect(_on_text_changed)
	_code.caret_changed.connect(_refresh_preview)
	_code.code_completion_requested.connect(_on_completion_requested)
	_code.text = ""
	_split.add_child(_code)

	var side := VBoxContainer.new()
	side.name = "Side"
	side.custom_minimum_size.x = SIDE_MIN_W
	side.add_theme_constant_override("separation", 0)
	_split.add_child(side)

	var head_wrap := PanelContainer.new()
	head_wrap.add_theme_stylebox_override("panel", T.bar_style(true))
	side.add_child(head_wrap)

	_preview_head = Label.new()
	_preview_head.text = "当前拍"
	_preview_head.add_theme_color_override("font_color", T.FAINT)
	_preview_head.add_theme_font_size_override("font_size", 11)
	head_wrap.add_child(_preview_head)

	# 侧栏窄，生成的一行常常比它长，所以预览要折行（正文不折，正文要能横向滚）。
	# 只读 CodeEdit 而不是 Label：等宽、可选中、样式和正文一致
	_preview = CodeEdit.new()
	_preview.editable = false
	_preview.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_preview.scroll_fit_content_height = false
	_preview.add_theme_font_size_override("font_size", 13)
	_preview.custom_minimum_size.y = 120
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(_preview)

	var issue_wrap := PanelContainer.new()
	var isb := StyleBoxFlat.new()
	isb.bg_color = T.SURFACE
	isb.border_color = T.BORDER
	isb.border_width_top = 1
	isb.border_width_bottom = 1
	isb.content_margin_left = 10
	isb.content_margin_top = 4
	isb.content_margin_bottom = 4
	issue_wrap.add_theme_stylebox_override("panel", isb)
	side.add_child(issue_wrap)

	var issue_head := Label.new()
	issue_head.text = "问题（点一条跳到那一行）"
	issue_head.add_theme_color_override("font_color", T.FAINT)
	issue_head.add_theme_font_size_override("font_size", 11)
	issue_wrap.add_child(issue_head)

	_issues = ItemList.new()
	_issues.custom_minimum_size.y = 140
	_issues.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_issues.add_theme_font_size_override("font_size", 12)
	_issues.item_selected.connect(_on_issue_selected)
	side.add_child(_issues)


func _build_bottom() -> void:
	var wrap := PanelContainer.new()
	wrap.name = "BottomBar"
	wrap.custom_minimum_size.y = HINT_H
	wrap.add_theme_stylebox_override("panel", T.bar_style(true))
	_root.add_child(wrap)

	_bottom = HBoxContainer.new()
	_bottom.add_theme_constant_override("separation", 16)
	wrap.add_child(_bottom)

	_hint = Label.new()
	_hint.add_theme_color_override("font_color", T.FAINT)
	_hint.add_theme_font_size_override("font_size", 11)
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint.clip_text = true
	_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_bottom.add_child(_hint)

	_product = Label.new()
	_product.add_theme_color_override("font_color", T.MUTED)
	_product.add_theme_font_size_override("font_size", 11)
	_product.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_bottom.add_child(_product)


## ---- 打开 / 保存 / 编译 ----

func _open(path: String) -> void:
	if not FileAccess.file_exists(path):
		_set_hint("打不开：%s" % path)
		return
	_src = path
	_code.text = FileAccess.get_file_as_string(path)
	_dirty = false
	_file_label.text = path.get_file()
	_file_label.tooltip_text = path
	_refresh_dirty()
	_parse_now()
	_set_hint("已打开 %s" % path)


## 把正文写回源文件。这是唯一的落盘入口，编译按钮也走它。
func _save() -> void:
	if _src == "":
		_set_hint("还没有打开文件")
		return
	var f := FileAccess.open(_src, FileAccess.WRITE)
	if f == null:
		_set_hint("写不进 %s：%s" % [_src, error_string(FileAccess.get_open_error())])
		return
	f.store_string(_code.text)
	f.close()
	_dirty = false
	_refresh_dirty()
	_set_hint("已保存 %s" % _src)


func _save_and_compile() -> void:
	if _src == "":
		_set_hint("还没有打开文件")
		return
	_save()
	var out := Compiler.out_path_for(_src)
	var r := Compiler.compile_file(_src, out)
	if not r["ok"]:
		# 编译失败不写盘，磁盘上原来的产物保持不动
		_set_hint(String(r["errors"][0]) if not r["errors"].is_empty() else "编译失败")
		_refresh_issues_from(r["errors"], r["warnings"])
		return
	_refresh_status()
	_set_hint("已生成 %s" % out)
	if Engine.is_editor_hint():
		var fs := EditorInterface.get_resource_filesystem()
		if fs != null:
			fs.scan()


## Ctrl+S 直写源文件。
## 必须在 _shortcut_input 里接并 accept_event()：编辑器全局的「保存场景」也会响应
## Ctrl+S，不拦下来就会出现「以为存了剧本，其实存了场景」。
## 只在焦点在面板内时接管（_shortcut_input 本身就沿焦点链上浮，不满足不会到这）。
func _shortcut_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return
	if k.keycode == KEY_S and k.ctrl_pressed and not k.shift_pressed and not k.alt_pressed:
		_save()
		accept_event()


## ---- 插入模板 ----

## 把表里的模板插到光标处：`|` 是落点，插完把光标放到那儿。
## `|<…>` 是「待替换的默认值」，插入后整段选中，用户一打字就顶掉。
## 当前行有内容时另起一行插，否则会和上一句挤进同一拍（那是个编译错误）。
func _insert_snippet(s: Dictionary) -> void:
	var ex := _expand_template(String(s["insert"]))
	var text := String(ex["text"])
	var marker := int(ex["caret"])
	var sel := int(ex["sel"])

	var start_line := _code.get_caret_line()
	var cur := _code.get_line(start_line)
	if cur.strip_edges() != "":
		# 空行才是拍边界，所以「插在当前行后面」要先决定空几行：
		#   - 当前行是台词 / 结构块开头 → 默认另起一拍（新台词同拍会互相覆盖；
		#     想让动作和台词同拍的人会自己删掉那个空行）
		#   - 当前行是普通动作 → 留在同一拍（背景 + 立绘同拍启动是常见写法）
		var bare := cur.strip_edges()
		var alone := cur.contains("「") or bare.begins_with("[选择项") or bare.begins_with("[判断")
		var pad := "\n\n" if alone else "\n"
		text = pad + text
		marker += pad.length()
		_code.set_caret_column(cur.length())

	# 落点在插入文本里的坐标：跨行时不能拿总长度减，必须按换行拆开算
	var before := text.substr(0, marker)
	var newlines := before.count("\n")
	var target_line := start_line + newlines
	var target_col := marker if newlines == 0 else marker - before.rfind("\n") - 1

	_code.insert_text_at_caret(text)
	if sel > 0:
		_code.select(target_line, target_col, target_line, target_col + sel)
	else:
		_code.set_caret_line(target_line)
		_code.set_caret_column(target_col)
	_code.grab_focus()
	# 程序化改文本不会发 text_changed（实测：set_text 和 insert_text_at_caret 都不发），
	# 不手动通知一遍，按钮插完就不会变脏、不重解析、右侧预览还是旧的
	_on_text_changed()


## 解析模板标记：返回 {text: 去掉标记的正文, caret: 落点下标, sel: 要被选中的长度}。
## 只认 `|`（落点，取第一个）和紧跟其后的 `<…>`（默认值，插入后选中）。
func _expand_template(tpl: String) -> Dictionary:
	var out := ""
	var caret := -1
	var sel := 0
	var i := 0
	while i < tpl.length():
		var ch := tpl[i]
		if ch == "|" and caret < 0:
			caret = out.length()
			i += 1
			continue
		if ch == "<" and caret == out.length():
			var gt := tpl.find(">", i)
			if gt > i:
				var inner := tpl.substr(i + 1, gt - i - 1)
				out += inner
				sel = inner.length()
				i = gt + 1
				continue
		out += ch
		i += 1
	if caret < 0:
		caret = out.length()
	return {"text": out, "caret": caret, "sel": sel}


## 补全：CodeEdit 只负责弹窗和键盘导航，候选由指令表给。
## 三种语境分开，避免在台词里冒出 [背景：] 这种驴唇不对马嘴的候选。
func _on_completion_requested() -> void:
	var line_text := _code.get_line(_code.get_caret_line())
	var col := _code.get_caret_column()
	var before := line_text.substr(0, col)

	var items: Array = []
	if _inside_quotes(before):
		items = _known_speakers()
	elif before.strip_edges().begins_with("[") and not before.contains("]"):
		for kw in Emitter.command_names():
			items.append(String(kw))
	for it in items:
		_code.add_code_completion_option(CodeEdit.KIND_PLAIN_TEXT, it, it, T.TEXT)
	_code.update_code_completion_options(true)


func _inside_quotes(text: String) -> bool:
	return text.count("「") > text.count("」")


## 说话人候选：从当前正文里扫已经出现过的 `角色：「`。
## 不引入角色表——那会多一份要维护的数据，而且和 .script.txt 不同步时更麻烦。
func _known_speakers() -> Array:
	var out: Array = []
	var re := RegEx.new()
	re.compile("^\\s*([^「」：\\[\\]]+?)：「")
	for line in _code.text.split("\n"):
		var m := re.search(line)
		if m == null:
			continue
		var who := m.get_string(1).strip_edges()
		if who != "" and not out.has(who):
			out.append(who)
	return out


## ---- 解析 / 刷新 ----

func _on_text_changed() -> void:
	_dirty = true
	_refresh_dirty()
	_parse_left = PARSE_DELAY


func _process(delta: float) -> void:
	if _parse_left <= 0.0:
		return
	_parse_left -= delta
	if _parse_left <= 0.0:
		_parse_left = 0.0
		_parse_now()


func _parse_now() -> void:
	if _code == null:
		return
	var ast := Parser.parse(_code.text)
	var acc := {"beats": 0, "actions": 0, "blocks": 0}
	_count(ast["roots"], acc)
	_stats.text = "%d 拍 · %d 动作%s" % [
		int(acc["beats"]), int(acc["actions"]),
		"" if int(acc["blocks"]) == 0 else " · %d 块" % int(acc["blocks"]),
	]

	# 出错时把生成器那边的错误也并进来：同样的文本，parser 过不代表 emit 过
	var errors: Array = ast["errors"].duplicate()
	var warnings: Array = ast["warnings"].duplicate()
	if errors.is_empty():
		var r := Emitter.emit(ast["roots"], {})
		errors.append_array(r["errors"])
		warnings.append_array(r["warnings"])

	_refresh_issues_from(errors, warnings)
	_mark_error_lines(errors)
	_refresh_preview()
	_refresh_status()


func _count(nodes: Array, acc: Dictionary) -> void:
	for n in nodes:
		match String(n.get("kind", "")):
			"beat":
				acc["beats"] += 1
				acc["actions"] += (n["items"] as Array).size()
			"choice":
				acc["blocks"] += 1
				for opt in n["options"]:
					_count(opt["body"], acc)
			"if":
				acc["blocks"] += 1
				for br in n["branches"]:
					_count(br["body"], acc)


func _refresh_issues_from(errors: Array, warnings: Array) -> void:
	_issues.clear()
	for e in errors:
		var msg := String(e)
		var i := _issues.add_item("错误  %s" % msg)
		_issues.set_item_custom_fg_color(i, T.ERROR)
		_issues.set_item_metadata(i, _line_of(msg))
		# 列表窄，长文案会被省略号吃掉，完整的话留在 tooltip 里
		_issues.set_item_tooltip(i, msg)
	for w in warnings:
		var msg := String(w)
		var i := _issues.add_item("提示  %s" % msg)
		_issues.set_item_custom_fg_color(i, T.WARN)
		_issues.set_item_metadata(i, _line_of(msg))
		_issues.set_item_tooltip(i, msg)
	if errors.is_empty() and warnings.is_empty():
		var ok := _issues.add_item("没有问题")
		_issues.set_item_custom_fg_color(ok, T.FAINT)


## 错误文案统一写成「第 N 行：…」，这里把 N 抠出来做跳行和标色。
func _line_of(msg: String) -> int:
	var re := RegEx.new()
	re.compile("^第\\s*(\\d+)\\s*行")
	var m := re.search(msg)
	return int(m.get_string(1)) if m != null else 0


func _mark_error_lines(errors: Array) -> void:
	for ln in _error_lines:
		_code.set_line_background_color(int(ln) - 1, Color(0, 0, 0, 0))
	_error_lines.clear()
	for e in errors:
		var ln := _line_of(String(e))
		if ln < 1 or ln > _code.get_line_count():
			continue
		_code.set_line_background_color(ln - 1, Color(T.ERROR, 0.12))
		_error_lines.append(ln)


func _on_issue_selected(index: int) -> void:
	var ln := int(_issues.get_item_metadata(index))
	if ln < 1:
		return
	_code.grab_focus()
	_code.set_caret_line(ln - 1)
	_code.set_caret_column(0)


## 光标所在的那一拍 → 生成它对应的 GDScript。
## 不另写一套「人话预览」：DSL 和 VNKit 一一对应，直接把产物摊开更准确。
func _refresh_preview() -> void:
	if _code == null or _preview == null:
		return
	var ast := Parser.parse(_code.text)
	var node := _node_at(ast["roots"], _code.get_caret_line() + 1)
	if node.is_empty():
		_preview_head.text = "当前拍"
		_preview.text = "（光标在空行上）"
		return

	var kind := String(node["kind"])
	var title := "拍 %d" % int(node["line"])
	match kind:
		"beat":
			var items: Array = node["items"]
			var first: Dictionary = items[0]
			title += " · %s" % ("台词" if String(first["kind"]) == "say" else "动作")
		"choice":
			title += " · 选择项"
		"if":
			title += " · 判断"
	_preview_head.text = title

	var r := Emitter.emit([node], {})
	if not r["errors"].is_empty():
		_preview.text = "\n".join(r["errors"])
		return

	var body: Array = []
	var started := false
	for line in r["lines"]:
		var s := String(line)
		if not started:
			if s.begins_with("func play"):
				started = true
			continue
		if s == "\tfinished.emit()":
			continue
		body.append(s)
	_preview.text = "\n".join(body).strip_edges(false, true)


## 找到包含目标行的最内层节点：先取「最后一个起始行 <= 目标的顶层节点」，
## 再往它的 body 里钻。选择项/判断的 body 展开后继续比行号即可。
func _node_at(nodes: Array, line: int) -> Dictionary:
	var best: Dictionary = {}
	for n in nodes:
		if int(n.get("line", 0)) <= line:
			best = n
	if best.is_empty():
		return {}
	var inner := _node_at(_children_of(best), line)
	return inner if not inner.is_empty() else best


func _children_of(node: Dictionary) -> Array:
	var out: Array = []
	match String(node.get("kind", "")):
		"choice":
			for opt in node["options"]:
				out.append_array(opt["body"])
		"if":
			for br in node["branches"]:
				out.append_array(br["body"])
	return out


## ---- 状态显示 ----

func _refresh_dirty() -> void:
	_save_btn.text = "保存 •" if _dirty else "保存"
	_save_btn.add_theme_color_override("font_color", T.ACCENT if _dirty else T.MUTED)
	_refresh_status()


## 底栏右边那格：源文件与产物各自的状态，两个分开显示。
## 「产物已过期」靠源哈希对比算出来，这是命令行那边没有的信息。
func _refresh_status() -> void:
	if _product == null:
		return
	if _src == "":
		_product.text = "未打开文件"
		_product.add_theme_color_override("font_color", T.MUTED)
		return

	var out := Compiler.out_path_for(_src)
	if not FileAccess.file_exists(out):
		_product.text = "产物：未编译"
		_product.add_theme_color_override("font_color", T.FAINT)
		return

	var produced := FileAccess.get_file_as_string(out)
	if not Compiler.is_generated(produced):
		_product.text = "产物：同名文件不是本编译器生成的"
		_product.add_theme_color_override("font_color", T.ERROR)
		return

	var recorded := ""
	for line in produced.split("\n"):
		if line.begins_with("## 源哈希："):
			recorded = line.trim_prefix("## 源哈希：").strip_edges()
			break
	var now := Compiler.source_hash(_code.text)
	if _dirty:
		_product.text = "产物：源已改（未保存）"
		_product.add_theme_color_override("font_color", T.WARN)
	elif recorded == now:
		_product.text = "产物：已是最新"
		_product.add_theme_color_override("font_color", T.MUTED)
	else:
		_product.text = "产物：已过期，需要重编"
		_product.add_theme_color_override("font_color", T.WARN)


func _set_hint(msg: String) -> void:
	if _hint != null:
		_hint.text = msg

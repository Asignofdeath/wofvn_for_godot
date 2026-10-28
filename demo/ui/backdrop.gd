## 背景层：两层 TextureRect 交替淡入，换背景不会先黑一下。
##
## 契约实现：组 vn_stage，方法 set_bg(id, fade) -> Signal
##
## 在场景里就是个普通 Control，用 anchors 铺满要显示的区域。位置、大小全交给
## Godot 的 2D 视图和 Inspector，这里一个坐标都不算。
##
## @tool 是为了在编辑器里直接看到背景图——摆 UI 时不用按 F5。
## preview_id 只在编辑器里生效，运行时完全忽略。
##
##   VNBackdrop
##   ├── __layer_a   ← 内部 TextureRect（internal child：不进场景面板、不被存进 .tscn）
##   └── __layer_b
##
## 为什么它不能自己就是 TextureRect：交叉淡入要两张图同时可见，
## 一个 TextureRect 只有一个 texture，换图就是硬切，中间必然闪黑。
@tool
class_name VNBackdrop
extends Control

const GROUP := "vn_stage"
## 找图依次尝试的扩展名
const IMAGE_EXTS := ["png", "webp", "jpg", "jpeg"]

## 背景目录约定：<bg_dir>/<id>.png。是约定，不是注册表
@export var bg_dir := "res://art/bg":
	set(v):
		bg_dir = v
		if Engine.is_editor_hint():
			_refresh_preview()

## 编辑器预览用哪个背景。留空则只显示底色，方便先摆别的 UI
@export var preview_id := "":
	set(v):
		preview_id = v
		if Engine.is_editor_hint():
			_refresh_preview()

## 没有背景图时的底色
@export var base_color := Color(0.08, 0.09, 0.12):
	set(v):
		base_color = v
		queue_redraw()

## 两层交替。_top 是当前可见那层的下标
var _layers: Array[TextureRect] = []
var _top := 0
var _tweens: Dictionary = {}
var _warned: Dictionary = {}


func _ready() -> void:
	_ensure_layers()
	if not resized.is_connected(queue_redraw):
		resized.connect(queue_redraw)
	if Engine.is_editor_hint():
		_refresh_preview()
		return
	add_to_group(GROUP)


## ---- 契约实现 ----

## 换背景。id 可以是 bg_dir 下的文件名，也可以是 res:// 完整路径。
func set_bg(id: String, fade: float = 0.4) -> Signal:
	_ensure_layers()
	var tex := _load(id)
	if tex == null:
		_warn_once("bg:" + id,
			"[VNBackdrop] 背景找不到：%s（约定 %s/<id>.png），用底色" % [id, bg_dir])
		tex = _solid(base_color)

	var incoming := _layers[1 - _top]
	var outgoing := _layers[_top]
	incoming.texture = tex
	_top = 1 - _top

	if fade <= 0.001:
		incoming.modulate.a = 1.0
		outgoing.modulate.a = 0.0
		_kill(outgoing)
		return get_tree().process_frame

	incoming.modulate.a = 0.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(incoming, "modulate:a", 1.0, fade)
	tw.tween_property(outgoing, "modulate:a", 0.0, fade)
	return _track(incoming, tw)


## ---- 内部 ----

## 两层都是 internal child：不出现在编辑器场景树面板里，也不会被保存进 .tscn。
## 不然用户每次打开场景都会看见两个删不掉的 TextureRect。
func _ensure_layers() -> void:
	if _layers.size() == 2 and is_instance_valid(_layers[0]) and is_instance_valid(_layers[1]):
		return
	_layers.clear()
	for i in 2:
		var t := TextureRect.new()
		t.name = "__layer_%s" % ("a" if i == 0 else "b")
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		t.modulate.a = 0.0
		t.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(t, false, Node.INTERNAL_MODE_FRONT)
		_layers.append(t)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), base_color)
	if not Engine.is_editor_hint():
		return
	# 虚线框只能手画：StyleBoxFlat 没有 dashed 属性
	_dash_rect(Rect2(Vector2.ZERO, size), Color(0.55, 0.62, 0.78, 0.55))
	if preview_id != "":
		return
	var font := get_theme_default_font()
	if font == null:
		return
	draw_string(font, Vector2(10, 22), "背景（preview_id 留空）",
		HORIZONTAL_ALIGNMENT_LEFT, maxf(size.x - 20.0, 10.0), 14, Color(1, 1, 1, 0.5))


func _dash_rect(r: Rect2, c: Color) -> void:
	var p: Array[Vector2] = [
		r.position,
		Vector2(r.end.x, r.position.y),
		r.end,
		Vector2(r.position.x, r.end.y),
	]
	for i in 4:
		draw_dashed_line(p[i], p[(i + 1) % 4], c, 1.0, 6.0)


func _refresh_preview() -> void:
	_ensure_layers()
	_kill(_layers[0])
	_kill(_layers[1])
	var tex: Texture2D = null
	if preview_id != "":
		tex = _load(preview_id)
	_layers[0].texture = tex
	_layers[0].modulate.a = 1.0 if tex != null else 0.0
	_layers[1].texture = null
	_layers[1].modulate.a = 0.0
	_top = 0
	queue_redraw()


func _load(id: String) -> Texture2D:
	var path := _resolve(id)
	if path == "":
		return null
	return ResourceLoader.load(path) as Texture2D


## 背景：id 本身就是完整路径时直接用，否则按 bg_dir/<id>.<ext> 找。
func _resolve(id: String) -> String:
	if id == "":
		return ""
	if id.begins_with("res://") or id.begins_with("user://"):
		return id if ResourceLoader.exists(id) else ""
	var base := "%s/%s" % [bg_dir.trim_suffix("/"), id]
	for ext in IMAGE_EXTS:
		var path := "%s.%s" % [base, ext]
		if ResourceLoader.exists(path):
			return path
	return ""


## 记住并返回这个 tween 的完成信号。同一个节点上的旧 tween 先杀掉，不然两个淡入打架。
func _track(node: Node, tw: Tween) -> Signal:
	var key := node.get_instance_id()
	var old: Tween = _tweens.get(key, null)
	if old != null and old.is_valid():
		old.kill()
	_tweens[key] = tw
	return tw.finished


func _kill(node: Node) -> void:
	var key := node.get_instance_id()
	var tw: Tween = _tweens.get(key, null)
	if tw != null and tw.is_valid():
		tw.kill()
	_tweens.erase(key)


static func _solid(c: Color) -> Texture2D:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, c)
	return ImageTexture.create_from_image(img)


func _warn_once(key: String, msg: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(msg)

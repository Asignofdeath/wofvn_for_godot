## 一个立绘点位。
##
## 这里**不是**契约节点——契约的 set_sprite 在舞台根上，由它把角色分派到某个点位。
## 这个节点只负责一件事：在自己这块矩形里显示一个角色。
##
##   VNSpriteSlot          ← anchors 决定立绘站哪、多大，用 2D 视图调
##   └── __sprite          ← 内部 TextureRect（internal child：不进场景面板、不被保存）
##
## @tool + preview_who 是它相对「随便一个 Control」的全部价值：
## 在编辑器里直接看到立绘，摆位置不用按 F5。preview_* 只在编辑器生效，运行时忽略。
##
## 一个点位只留一个角色，后来者顶替先来者。要两个角色同屏就建两个点位。
@tool
class_name VNSpriteSlot
extends Control

const IMAGE_EXTS := ["png", "webp", "jpg", "jpeg"]

## 剧本里写的 slot 名。留空就用节点名——推荐留空，改名即改槽位
@export var slot_name := "":
	set(v):
		slot_name = v
		queue_redraw()

## 立绘目录约定：<chara_dir>/<角色>/<表情>.png，找不到表情退让到 default
@export var chara_dir := "res://art/chara":
	set(v):
		chara_dir = v
		if Engine.is_editor_hint():
			_refresh_preview()

## 编辑器预览哪个角色。留空则只画虚线框和点位名
@export var preview_who := "":
	set(v):
		preview_who = v
		if Engine.is_editor_hint():
			_refresh_preview()

## 编辑器预览用哪个表情
@export var preview_pose := "default":
	set(v):
		preview_pose = v
		if Engine.is_editor_hint():
			_refresh_preview()

@export var stretch_mode: TextureRect.StretchMode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED:
	set(v):
		stretch_mode = v
		if _spr != null and is_instance_valid(_spr):
			_spr.stretch_mode = v

var _spr: TextureRect
var _who := ""
var _tween: Tween
var _warned: Dictionary = {}


func _ready() -> void:
	_ensure()
	if not resized.is_connected(queue_redraw):
		resized.connect(queue_redraw)
	if Engine.is_editor_hint():
		_refresh_preview()


## ---- 给舞台根用的接口（不是契约，舞台根是唯一调用方） ----

## 让这个点位显示 who。同一个 who 换 pose 只换贴图，不重播淡入（否则会闪一下）。
func set_character(who: String, pose: String = "default", fade: float = 0.2) -> Signal:
	_ensure()
	var fresh := who != _who
	_who = who

	var tex := _load_sprite(who, pose)
	if tex == null:
		_warn_once("spr:%s/%s" % [who, pose],
			"[VNSpriteSlot] 立绘找不到：%s/%s（约定 %s/<角色>/<表情>.png），用占位" % [who, pose, chara_dir])
		tex = _placeholder(who)
	_spr.texture = tex
	set_meta("pose", pose)

	_kill()
	if not fresh:
		_spr.modulate.a = 1.0
		return get_tree().process_frame

	if fade <= 0.001:
		_spr.modulate.a = 1.0
		return get_tree().process_frame
	_spr.modulate.a = 0.0
	_tween = create_tween()
	_tween.tween_property(_spr, "modulate:a", 1.0, fade)
	return _tween.finished


## 立刻收走。节点留着复用，不清空子节点。
func clear_character() -> void:
	_who = ""
	remove_meta("pose")
	if _spr == null or not is_instance_valid(_spr):
		return
	_kill()
	_spr.texture = null
	_spr.modulate.a = 0.0


## 当前站着谁，空串表示空位
func current() -> String:
	return _who


## 剧本里用的 slot 名：slot_name 优先，否则节点名
func slot_id() -> String:
	var s := slot_name.strip_edges()
	return s if s != "" else String(name)


## ---- 内部 ----

func _ensure() -> void:
	if _spr != null and is_instance_valid(_spr):
		return
	_spr = TextureRect.new()
	_spr.name = "__sprite"
	_spr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_spr.stretch_mode = stretch_mode
	_spr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_spr.modulate.a = 0.0
	_spr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_spr, false, Node.INTERNAL_MODE_FRONT)


func _load_sprite(who: String, pose: String) -> Texture2D:
	var path := _sprite_path(who, pose)
	if path == "":
		return null
	return ResourceLoader.load(path) as Texture2D


## 找图顺序：请求的 pose → default → 空串（调用方用占位）
func _sprite_path(who: String, pose: String) -> String:
	var base := chara_dir.trim_suffix("/")
	var p := pose.strip_edges()
	var tries: Array[String] = []
	if p != "":
		tries.append("%s/%s/%s" % [base, who, p])
	if p != "default":
		tries.append("%s/%s/default" % [base, who])
	for rel in tries:
		for ext in IMAGE_EXTS:
			var path := "%s.%s" % [rel, ext]
			if ResourceLoader.exists(path):
				return path
	return ""


## 占位色块：同一个角色每次都是同一个颜色，灰盒阶段能分辨谁是谁。
func _placeholder(who: String) -> Texture2D:
	var w := maxi(int(size.x), 2)
	var h := maxi(int(size.y), 2)
	# 取 hash 的中位而不是低位：短字符串的 hash 低位容易扎堆，
	# 「葵」和「凛」直接 mod 360 只差 6°，肉眼分不出是两个人。
	var hue := float((abs(hash(who)) >> 4) % 360) / 360.0
	var tint := Color.from_hsv(hue, 0.32, 0.9, 0.85)
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(tint)
	var edge := tint.darkened(0.45)
	for x in w:
		img.set_pixel(x, 0, edge)
		img.set_pixel(x, h - 1, edge)
	for y in h:
		img.set_pixel(0, y, edge)
		img.set_pixel(w - 1, y, edge)
	return ImageTexture.create_from_image(img)


func _refresh_preview() -> void:
	_ensure()
	var who := preview_who.strip_edges()
	if who == "":
		_spr.texture = null
		_spr.modulate.a = 0.0
	else:
		var tex := _load_sprite(who, preview_pose)
		_spr.texture = tex if tex != null else _placeholder(who)
		_spr.modulate.a = 1.0
	queue_redraw()


func _kill() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	# 虚线框只能手画：StyleBoxFlat 没有 dashed 属性
	_dash_rect(Rect2(Vector2.ZERO, size), Color(0.45, 0.85, 0.75, 0.5))
	# 有预览图时不画名字：贴图是子节点，画在 _draw 之后的层，名字会被盖住
	if preview_who.strip_edges() != "":
		return
	var font := get_theme_default_font()
	if font == null:
		return
	draw_string(font, Vector2(8, 20), "slot: %s（preview_who 留空）" % slot_id(),
		HORIZONTAL_ALIGNMENT_LEFT, maxf(size.x - 16.0, 10.0), 13, Color(0.8, 1.0, 0.95, 0.75))


func _dash_rect(r: Rect2, c: Color) -> void:
	var p: Array[Vector2] = [
		r.position,
		Vector2(r.end.x, r.position.y),
		r.end,
		Vector2(r.position.x, r.end.y),
	]
	for i in 4:
		draw_dashed_line(p[i], p[(i + 1) % 4], c, 1.0, 6.0)


func _warn_once(key: String, msg: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(msg)

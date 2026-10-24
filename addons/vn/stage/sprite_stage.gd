## 可选舞台节点：vn_stage 契约的参考实现。
##
## 2026-10-24 收窄过一次：**这里不算任何坐标**。
## 立绘放在哪、多大，由场景里「槽位节点」的 anchors 决定，用 Godot 编辑器摆
## （那里有真背景、真 UI、真分辨率，F5 就能看）。这个节点只补引擎没有的三件事：
## 契约方法、缺图占位、两层背景交叉淡入。
##
## 槽位 = 本节点的子节点，节点名就是剧本里写的 slot：
##
##   VNSpriteStage
##   ├── left      (Control，自己摆 anchors)
##   ├── center
##   └── right
##
## 一个槽位都没有时，立绘直接铺满整个舞台（单人场景的常见用法）。
##
## 可选。不用它，自己 add_to_group("vn_stage") 实现两个方法即可，插件不知道你的存在。
class_name VNSpriteStage
extends Control

const GROUP := "vn_stage"
## 内部节点名前缀，用来跳过自己建的背景层与立绘
const INTERNAL_PREFIX := "__"
## 找图依次尝试的扩展名
const IMAGE_EXTS := ["png", "webp", "jpg", "jpeg"]

## 目录约定，不是注册表：<chara_dir>/<角色>/<表情>.png，找不到表情退让到 default
@export var chara_dir := "res://art/chara"
## <bg_dir>/<id>.png
@export var bg_dir := "res://art/bg"
## 槽位尺寸还是 0 时（没布局 / headless），占位色块用多大
@export var placeholder_size := Vector2i(420, 700)

## 背景两层交替淡入淡出，避免换景时闪一下
var _bg: Array[TextureRect] = []
var _bg_top := 0
## who -> 立绘节点
var _sprites: Dictionary = {}
## slot 名 -> who。一个槽位只留一个角色
var _slot_owner: Dictionary = {}
## 重复调用时先杀掉旧 tween，不然两个淡入打架
var _tweens: Dictionary = {}
## 同一句警告只说一次，避免刷屏
var _warned: Dictionary = {}


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	add_to_group(GROUP)
	# 父节点不是 Control（例如 CanvasLayer）时锚点相对视口，铺满即可
	if size.is_zero_approx():
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_bg()


## ---- 契约实现 ----

## 换背景。id 可以是 bg_dir 下的文件名，也可以是 res:// 完整路径。
func set_bg(id: String, fade: float = 0.4) -> Signal:
	var tex := _load_tex(_res_path(bg_dir, id))
	var incoming := _bg[1 - _bg_top]
	var outgoing := _bg[_bg_top]
	if tex == null:
		_warn_once("bg:" + id,
			"[VNSpriteStage] 背景找不到：%s（约定 %s/<id>.png），用占位" % [id, bg_dir])
		tex = _solid(Vector2i(size), Color(0.09, 0.10, 0.13))
	incoming.texture = tex
	_bg_top = 1 - _bg_top

	if fade <= 0.001:
		incoming.modulate.a = 1.0
		outgoing.modulate.a = 0.0
		return get_tree().process_frame

	incoming.modulate.a = 0.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(incoming, "modulate:a", 1.0, fade)
	tw.tween_property(outgoing, "modulate:a", 0.0, fade)
	return _track(incoming, tw)


## 换立绘 / 换表情 / 换槽位。已经挂在台上的角色不重播淡入，避免换表情闪一下。
func set_sprite(who: String, pose: String = "default", slot: String = "center", fade: float = 0.2) -> Signal:
	var host := _slot_host(slot)
	var spr: TextureRect = _sprites.get(who, null)
	if spr != null and spr.get_parent() != host:
		# 换槽位：搬过去，重新铺满新容器
		spr.reparent(host, false)
		spr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var fresh := spr == null
	if fresh:
		spr = _make_sprite(host, who)
		_sprites[who] = spr

	# 槽位互斥：后来者顶替先来者
	var prev := String(_slot_owner.get(slot, ""))
	if prev != "" and prev != who:
		_drop(prev)
	_slot_owner[slot] = who

	var tex := _load_tex(_sprite_path(who, pose))
	if tex == null:
		_warn_once("spr:%s/%s" % [who, pose],
			"[VNSpriteStage] 立绘找不到：%s/%s（约定 %s/<角色>/<表情>.png），用占位" % [who, pose, chara_dir])
		tex = _solid(_host_size(host), _tint_of(who))
	spr.texture = tex
	spr.set_meta("pose", pose)
	spr.set_meta("slot", slot)

	if not fresh:
		spr.modulate.a = 1.0
		return get_tree().process_frame
	return _fade_in(spr, fade)


## ---- 查询（给项目自己用，不是契约） ----

func has_sprite(who: String) -> bool:
	return _sprites.has(who)


func sprite_node(who: String) -> TextureRect:
	return _sprites.get(who, null)


## ---- 内部 ----

## 找槽位容器。名字匹配的子节点就是槽位；没有就退回整个舞台并警告一次。
func _slot_host(slot: String) -> Control:
	for c in get_children():
		if c is Control and String(c.name) == slot and not String(c.name).begins_with(INTERNAL_PREFIX):
			return c as Control
	_warn_once("slot:" + slot,
		"[VNSpriteStage] 场景里没有名为「%s」的子节点，立绘铺满整个舞台。要摆位就在场景里建同名 Control" % slot)
	return self


func _make_sprite(host: Control, who: String) -> TextureRect:
	var spr := TextureRect.new()
	spr.name = INTERNAL_PREFIX + "spr_" + who.validate_node_name()
	spr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	spr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	spr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spr.modulate.a = 0.0
	spr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(spr)
	return spr


## 立刻收走一个角色的立绘（换槽位被顶替）。契约里没有 hide，所以不在这里做淡出。
func _drop(who: String) -> void:
	var spr: TextureRect = _sprites.get(who, null)
	_sprites.erase(who)
	for slot in _slot_owner.keys():
		if _slot_owner[slot] == who:
			_slot_owner.erase(slot)
	if spr == null:
		return
	var key := spr.get_instance_id()
	var tw: Tween = _tweens.get(key, null)
	if tw != null and tw.is_valid():
		tw.kill()
	_tweens.erase(key)
	if spr.get_parent() != null:
		spr.get_parent().remove_child(spr)
	spr.queue_free()


func _build_bg() -> void:
	for i in 2:
		var layer := TextureRect.new()
		layer.name = INTERNAL_PREFIX + "bg%d" % i
		layer.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		layer.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.modulate.a = 0.0
		layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(layer)
		move_child(layer, i)   # 背景永远在最底下
		_bg.append(layer)


func _fade_in(spr: TextureRect, fade: float) -> Signal:
	if fade <= 0.001:
		spr.modulate.a = 1.0
		return get_tree().process_frame
	var tw := create_tween()
	tw.tween_property(spr, "modulate:a", 1.0, fade)
	return _track(spr, tw)


## 记住并返回这个 tween 的完成信号。同一个节点上的旧 tween 先杀掉。
func _track(node: Node, tw: Tween) -> Signal:
	var key := node.get_instance_id()
	var old: Tween = _tweens.get(key, null)
	if old != null and old.is_valid():
		old.kill()
	_tweens[key] = tw
	return tw.finished


func _host_size(host: Control) -> Vector2i:
	var s := host.size
	if s.x < 1.0 or s.y < 1.0:
		return placeholder_size
	return Vector2i(s)


func _sprite_path(who: String, pose: String) -> String:
	var base := chara_dir.trim_suffix("/")
	var names: Array[String] = []
	var p := pose.strip_edges()
	if p != "":
		names.append("%s/%s/%s" % [base, who, p])
	if p != "default":
		names.append("%s/%s/default" % [base, who])
	for rel in names:
		for ext in IMAGE_EXTS:
			var path := "%s.%s" % [rel, ext]
			if FileAccess.file_exists(path):
				return path
	return ""


## 背景：id 本身就是完整路径时直接用，否则按 bg_dir/<id>.<ext> 找。
func _res_path(dir: String, id: String) -> String:
	if id.begins_with("res://") or id.begins_with("user://"):
		return id if FileAccess.file_exists(id) else ""
	var base := "%s/%s" % [dir.trim_suffix("/"), id]
	for ext in IMAGE_EXTS:
		var path := "%s.%s" % [base, ext]
		if FileAccess.file_exists(path):
			return path
	return ""


static func _load_tex(path: String) -> Texture2D:
	if path == "" or not ResourceLoader.exists(path):
		return null
	return ResourceLoader.load(path) as Texture2D


## 稳定柔和色：同一个角色每次都是同一个颜色，灰盒阶段能分辨谁是谁。
static func _tint_of(who: String) -> Color:
	return Color.from_hsv(float(abs(hash(who)) % 360) / 360.0, 0.32, 0.9, 0.9)


## 占位色块。没画立绘也能先把流程跑通，这是灰盒阶段的主要用法。
static func _solid(size: Vector2i, tint: Color) -> Texture2D:
	var w := maxi(size.x, 2)
	var h := maxi(size.y, 2)
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


func _warn_once(key: String, msg: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(msg)

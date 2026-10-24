## 可选舞台节点：把 vn_stage 契约实现成「读一份 stage_layout.json + 按目录约定找图」。
##
## 设计约束：
## - 可选。不用它，自己 add_to_group("vn_stage") 实现两个方法即可，插件不知道你的存在。
## - 只实现契约里已有的两个方法，不新增组名、不改签名。
## - 视觉没完成不 emit：set_bg / set_sprite 返回的是 Tween 的 finished 信号，
##   await 它拿到的就是「淡入真的走完」那一刻。
## - 找不到图不报错阻断：生成占位色块 + push_warning，流程照常往下走。
class_name VNSpriteStage
extends Control

const GROUP := "vn_stage"

## 舞台数据文件。空 = 只有目录约定与缺省槽位可用。
@export_file("*.json") var layout_path := ""
## 立绘超出画布时是否裁掉。铺满全屏的舞台通常要开。
@export var clip_sprites := true
## 没指定 layout_path 时用的缺省目录（与 VNStageLayout 的缺省一致）
@export var fallback_chara_dir := "res://art/chara"

var layout: VNStageLayout

## 背景两层交替淡入淡出，避免「闪一下白」
var _bg_layers: Array[TextureRect] = []
var _bg_top := 0
## who -> 立绘节点
var _sprites: Dictionary = {}
## 节点 instance_id -> 它当前的 Tween。重复调用时先杀掉旧 tween，不然两个淡入打架。
var _tweens: Dictionary = {}


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	add_to_group(GROUP)
	clip_contents = clip_sprites

	layout = VNStageLayout.new()
	if layout_path != "":
		for msg in layout.load_from(layout_path):
			push_warning("[VNSpriteStage] %s" % msg)
	else:
		push_warning("[VNSpriteStage] 没有指定 layout_path，用缺省槽位与 %s" % fallback_chara_dir)
		layout.reset()
		layout.chara_dir = fallback_chara_dir

	# 父节点不是 Control（例如 CanvasLayer）时，锚点相对视口，铺满即可
	if size.is_zero_approx():
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_bg_layers()


## ---- 契约实现 ----

## 换背景。id 可以是「bg_dir 下的文件名」，也可以是 res:// 完整路径。
func set_bg(id: String, fade: float = 0.4) -> Signal:
	var target := layout.bg_path(id)
	var tex := VNStageLayout.load_texture(target)
	if tex == null:
		push_warning("[VNSpriteStage] 背景找不到：%s（约定 %s/<id>.png），用占位" % [id, layout.bg_dir])
		tex = VNStageLayout.make_placeholder(layout.canvas, Color(0.09, 0.10, 0.13))

	var incoming := _bg_layers[1 - _bg_top]
	var outgoing := _bg_layers[_bg_top]
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


## 换立绘 / 换表情 / 换槽位。已挂在台上的角色不重播淡入，避免换表情闪一下。
func set_sprite(who: String, pose: String = "default", slot: String = "center", fade: float = 0.2) -> Signal:
	if not layout.has_slot(slot):
		push_warning("[VNSpriteStage] 未知槽位：%s，回退到 center" % slot)
		slot = "center"

	var spr: TextureRect = _sprites.get(who, null)
	var fresh := spr == null
	if fresh:
		spr = TextureRect.new()
		spr.name = who.validate_node_name()
		spr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		spr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		spr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		spr.modulate.a = 0.0
		add_child(spr)
		_sprites[who] = spr

	var path := layout.chara_path(who, pose)
	var tex := VNStageLayout.load_texture(path)
	if tex == null:
		push_warning("[VNSpriteStage] 立绘找不到：%s/%s（约定 %s/<who>/<pose>.png），用占位" % [
			who, pose, layout.chara_dir])
		tex = VNStageLayout.make_placeholder(
			Vector2i(layout.placeholder), _placeholder_tint(who))
	spr.texture = tex
	spr.set_meta("pose", pose)
	spr.set_meta("slot", slot)
	spr.tooltip_text = ""  # 占位时不额外加 UI，留给项目自己决定

	var px := layout.sprite_px(tex, who, slot)
	var offset: Vector2 = layout.character(who)["offset"]
	VNStageLayout.place(spr, float(layout.slot(slot)["x"]), px, offset)

	if not fresh:
		# 已经在场：只换图与站位，不做淡入
		spr.modulate.a = 1.0
		return get_tree().process_frame
	if fade <= 0.001:
		spr.modulate.a = 1.0
		return get_tree().process_frame

	var tw := create_tween()
	tw.tween_property(spr, "modulate:a", 1.0, fade)
	return _track(spr, tw)


## ---- 查询（给项目自己用，不是契约） ----

func has_sprite(who: String) -> bool:
	return _sprites.has(who)


func sprite_node(who: String) -> TextureRect:
	return _sprites.get(who, null)


## ---- 内部 ----

func _build_bg_layers() -> void:
	for i in 2:
		var layer := TextureRect.new()
		layer.name = "BG%d" % i
		layer.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		layer.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.modulate.a = 0.0
		layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(layer)
		move_child(layer, i)   # 背景永远在立绘下面
		_bg_layers.append(layer)


## 记住并返回这个 tween 的完成信号。同一个节点上的旧 tween 先杀掉。
func _track(node: Node, tw: Tween) -> Signal:
	var key := node.get_instance_id()
	var old: Tween = _tweens.get(key, null)
	if old != null and old.is_valid():
		old.kill()
	_tweens[key] = tw
	return tw.finished


## 占位色：按角色名算一个稳定的柔和色，同一个角色每次都是同一个颜色。
func _placeholder_tint(who: String) -> Color:
	var hue := float(abs(hash(who)) % 360) / 360.0
	return Color.from_hsv(hue, 0.32, 0.9, 0.9)

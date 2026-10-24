## 舞台：背景、立绘槽位、UI 宿主。
## 契约：组 vn_stage，实现 set_bg(id, fade) -> Signal 与 set_sprite(who, pose, slot, fade) -> Signal
##
## 注意：立绘目前用 ColorRect 占位（按角色名取色的色块），第 2 阶段换成真正的立绘资源。
extends Control

const SLOTS := {
	"left": "SlotLeft",
	"center": "SlotCenter",
	"right": "SlotRight",
}

## 占位背景色板。真实项目应换成贴图或场景。
const BG_COLORS := {
	"教室": Color(0.17, 0.19, 0.26, 1.0),
	"走廊": Color(0.22, 0.17, 0.15, 1.0),
	"夜晚": Color(0.06, 0.07, 0.13, 1.0),
}

const ACTOR_SIZE := Vector2(240, 460)

@onready var bg: ColorRect = $BG
@onready var sprites: Node2D = $Sprites

var _actors: Dictionary = {}


func _ready() -> void:
	# 组名写在 stage.tscn 里（groups=["vn_stage"]），与 DialogueBox / ChoiceBox 一致
	_apply_cjk_theme()
	print("[Stage] ready")


## ---- 契约实现 ----

func set_bg(id: String, fade: float = 0.4) -> Signal:
	if not BG_COLORS.has(id):
		push_warning("[Stage] 未定义的背景：%s" % id)
	var target: Color = BG_COLORS.get(id, Color(0.12, 0.12, 0.14, 1.0))
	var tween := create_tween()
	tween.tween_property(bg, "color", target, fade)
	return tween.finished


func set_sprite(who: String, pose: String, slot: String = "center", fade: float = 0.2) -> Signal:
	if not SLOTS.has(slot):
		push_warning("[Stage] 未知槽位：%s，回退到 center" % slot)
	var marker: Marker2D = get_node_or_null("Sprites/%s" % SLOTS.get(slot, "SlotCenter"))
	if marker == null:
		push_error("[Stage] 槽位节点缺失：%s" % slot)
		return get_tree().process_frame

	var actor: ColorRect = _actors.get(who, null)
	if actor == null:
		actor = ColorRect.new()
		actor.mouse_filter = Control.MOUSE_FILTER_IGNORE
		actor.color = _actor_color(who)
		actor.size = ACTOR_SIZE
		actor.modulate.a = 0.0
		sprites.add_child(actor)
		_actors[who] = actor
		actor.position = _slot_position(marker)

	actor.set_meta("pose", pose)

	var duration := maxf(fade, 0.01)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(actor, "position", _slot_position(marker), duration)
	tween.tween_property(actor, "modulate:a", 1.0, duration)
	return tween.finished


## ---- 内部 ----

func _slot_position(marker: Marker2D) -> Vector2:
	return marker.position - Vector2(ACTOR_SIZE.x * 0.5, ACTOR_SIZE.y)


func _actor_color(who: String) -> Color:
	var hue := float(abs(hash(who)) % 360) / 360.0
	return Color.from_hsv(hue, 0.32, 0.9, 0.9)


## 开发期用系统字体显示中文。发布前应替换为项目内 FontFile。
func _apply_cjk_theme() -> void:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans SC", "SimHei", "Sans-Serif"])
	var ui_theme := Theme.new()
	ui_theme.default_font = font
	ui_theme.default_font_size = 26
	theme = ui_theme

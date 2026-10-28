## 舞台根：只把 set_sprite 分派到对应的立绘点位。
##
## 契约实现：组 vn_stage，方法 set_sprite(who, pose, slot, fade) -> Signal
##
## 背景不在这里——那是 Backdrop 子节点（VNBackdrop），它自己也在 vn_stage 组里
## 实现 set_bg。同一个组放两个节点是合法的：VNKit 找协作节点时会校验方法名。
##
## 舞台只做分派，不做渲染。立绘长什么样归 VNSpriteSlot，摆在哪归它的 anchors。
extends Control

const GROUP := "vn_stage"

var _warned: Dictionary = {}


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	add_to_group(GROUP)
	_apply_cjk_theme()
	print("[Stage] ready")


## ---- 契约实现 ----

func set_sprite(
	who: String,
	pose: String = "default",
	slot: String = "center",
	fade: float = 0.2
) -> Signal:
	var target := _slot_for(slot)
	if target == null:
		push_error("[Stage] 场景里没有任何 VNSpriteSlot，立绘无处可放")
		return get_tree().process_frame

	# 同一个角色换点位：把旧点位清空，不然会有两个分身。
	# 判断依据是点位自己记着谁，不用舞台再维护一份 who -> slot 的映射——
	# 那样在两个角色互相顶替时会留下脏数据。
	for s in _slots():
		if s != target and s.current() == who:
			s.clear_character()

	return target.set_character(who, pose, fade)


## ---- 内部 ----

func _slots() -> Array[VNSpriteSlot]:
	var out: Array[VNSpriteSlot] = []
	var host: Node = get_node_or_null("Slots")
	if host == null:
		host = self
	for c in host.get_children():
		if c is VNSpriteSlot:
			out.append(c)
	return out


## slot 名 → 点位。对不上就用第一个点位并警告一次，不中断剧情。
func _slot_for(slot: String) -> VNSpriteSlot:
	var all := _slots()
	if all.is_empty():
		return null
	for s in all:
		if s.slot_id() == slot:
			return s
	_warn_once("slot:" + slot,
		"[Stage] 没有名为「%s」的立绘点位，改用「%s」。点位名 = 节点名或 slot_name"
		% [slot, all[0].slot_id()])
	return all[0]


func _warn_once(key: String, msg: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(msg)


## 开发期用系统字体显示中文。发布前应替换为项目内 FontFile。
func _apply_cjk_theme() -> void:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans SC", "SimHei", "Sans-Serif"])
	var ui_theme := Theme.new()
	ui_theme.default_font = font
	ui_theme.default_font_size = 26
	theme = ui_theme

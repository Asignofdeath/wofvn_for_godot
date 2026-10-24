## 舞台契约回归测试（headless 可跑）。
##
## 验证四件事，任何一件坏了都会表现成「剧情永久卡住」或「立绘错乱」：
##   1. 契约时序：set_bg / set_sprite 返回的 Signal 必须在视觉完成后才推进
##   2. 槽位映射：slot 参数对应场景里的子节点，立绘铺满该节点
##   3. 槽位互斥：一个槽位只留一个角色，后来者顶替
##   4. 缺图降级：没有美术资源时用占位色块顶上，不崩、不阻断
##
## 跑法：
##   godot --headless --path . --script res://tools/test_stage.gd
extends SceneTree

const StageScript := preload("res://addons/vn/stage/sprite_stage.gd")

var _fails := 0
var _passes := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _test_contract()
	await _test_slots()

	print("[STAGE] %d 通过 / %d 失败" % [_passes, _fails])
	quit(0 if _fails == 0 else 1)


## ---- 1. 契约时序与降级 ----

func _test_contract() -> void:
	var stage: VNSpriteStage = StageScript.new()
	stage.size = Vector2(1920, 1080)
	root.add_child(stage)
	await process_frame

	_ok("自动进 vn_stage 组", stage.is_in_group("vn_stage"))

	# set_bg：await 之后必须是「已经可见」的那一帧，不是发起那一帧
	await stage.set_bg("教室", 0.03)
	_ok("set_bg 完成后背景可见", _bg_alpha(stage) > 0.99)

	# 换背景：两层交替，旧的那层淡掉
	await stage.set_bg("走廊", 0.03)
	_ok("换背景后仍只有一层可见", _bg_alpha(stage) > 0.99)

	# 缺图 → 占位 + 淡入
	await stage.set_sprite("凛", "平静", "center", 0.03)
	var spr: TextureRect = stage.sprite_node("凛")
	_ok("立绘节点已建", spr != null)
	_ok("缺图时用占位贴图", spr != null and spr.texture != null)
	_ok("淡入完成 a=1", spr != null and is_equal_approx(spr.modulate.a, 1.0))
	_ok("记下了 pose", spr != null and String(spr.get_meta("pose", "")) == "平静")

	# 换表情：不重播淡入（否则会闪一下）
	spr.modulate.a = 0.5
	await stage.set_sprite("凛", "微笑", "center", 0.03)
	_ok("换表情不重播淡入", spr != null and is_equal_approx(spr.modulate.a, 1.0))
	_ok("换表情记下了 pose", spr != null and String(spr.get_meta("pose", "")) == "微笑")

	_ok("缺图路径返回空串", stage._sprite_path("不存在的人", "default") == "")
	_ok("缺背景路径返回空串", stage._res_path("res://art/bg", "不存在") == "")

	stage.queue_free()
	await process_frame


## ---- 2. 槽位映射与互斥 ----

func _test_slots() -> void:
	var stage: VNSpriteStage = StageScript.new()
	stage.size = Vector2(1920, 1080)
	root.add_child(stage)
	var left := _make_slot(stage, "left", Vector2(400, 700))
	var right := _make_slot(stage, "right", Vector2(400, 700))
	await process_frame

	# slot 对应场景里的子节点，立绘铺满它
	await stage.set_sprite("凛", "default", "left", 0.0)
	var spr: TextureRect = stage.sprite_node("凛")
	_ok("立绘挂到 left 节点下", spr != null and spr.get_parent() == left)
	_ok("立绘铺满槽位", spr != null and is_zero_approx(spr.anchor_left)
		and is_zero_approx(spr.anchor_top) and is_zero_approx(spr.offset_right)
		and is_zero_approx(spr.offset_bottom))
	_ok("占位尺寸取槽位尺寸", spr != null and spr.texture.get_size() == left.size)

	# 换槽位：同一节点搬过去，不重建
	await stage.set_sprite("凛", "default", "right", 0.0)
	_ok("换槽位后挂到 right", spr != null and spr.get_parent() == right)
	_ok("换槽位没多建节点", stage.has_sprite("凛") and _sprite_count(stage) == 1)

	# 槽位互斥：葵进来，凛被收走
	await stage.set_sprite("葵", "default", "right", 0.0)
	_ok("同槽位后来者顶替", stage.has_sprite("葵") and not stage.has_sprite("凛"))
	_ok("被顶替的节点已移除", _sprite_count(stage) == 1)

	# 槽位名字对不上：退回整个舞台，不报错中断
	await stage.set_sprite("葵2", "default", "nowhere", 0.0)
	var orphan: TextureRect = stage.sprite_node("葵2")
	_ok("未知槽位退回舞台自身", orphan != null and orphan.get_parent() == stage)

	_ok("两个角色各自成节点", stage.sprite_node("葵") != stage.sprite_node("葵2"))

	stage.queue_free()
	await process_frame


## ---- 断言 ----

func _make_slot(stage: Control, slot_name: String, slot_size: Vector2) -> Control:
	var slot := Control.new()
	slot.name = slot_name
	slot.size = slot_size
	stage.add_child(slot)
	return slot


## 数实际存在的立绘节点，而不是数字典——字典没清干净但节点没删，是另一种 bug。
func _sprite_count(node: Node) -> int:
	var n := 1 if String(node.name).begins_with("__spr_") else 0
	for c in node.get_children():
		n += _sprite_count(c)
	return n


func _bg_alpha(stage: VNSpriteStage) -> float:
	var best := 0.0
	for n in stage.get_children():
		if n is TextureRect and String(n.name).begins_with("__bg"):
			best = maxf(best, (n as TextureRect).modulate.a)
	return best


func _ok(what: String, cond: bool) -> void:
	if cond:
		_passes += 1
	else:
		_fails += 1
	print("[STAGE] %-28s %s" % [what, "OK" if cond else "FAIL"])

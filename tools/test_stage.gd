## 舞台回归测试（headless 可跑）。
##
## 验证三件事，任何一件坏了都会表现成「剧情永久卡住」或「立绘消失」：
##   1. 数据层几何：place() 的锚点与偏移算得对
##   2. 契约时序：set_bg / set_sprite 返回的 Signal 必须在视觉完成后才推进
##   3. 缺图降级：没有美术资源时用占位色块顶上，不崩、不阻断
##
## 跑法：
##   godot --headless --path . --script res://tools/test_stage.gd
extends SceneTree

const StageScript := preload("res://addons/vn/stage/sprite_stage.gd")
const LayoutScript := preload("res://addons/vn/stage/stage_layout.gd")
const PanelScript := preload("res://addons/vn/editor/stage_screen.gd")

const TMP := "user://test_stage_layout.json"
const TMP_PANEL := "user://test_panel_layout.json"

var _fails := 0
var _passes := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_layout_data()
	_test_save_roundtrip()
	await _test_stage_contract()
	await _test_panel()

	print("[STAGE] %d 通过 / %d 失败" % [_passes, _fails])
	quit(0 if _fails == 0 else 1)


## ---- 1. 数据层 ----

func _test_layout_data() -> void:
	var lay: VNStageLayout = LayoutScript.new()
	lay.reset()
	_ok("缺省槽位数 = 3", lay.slot_names().size() == 3)
	_ok("未知槽位回退 center", is_equal_approx(float(lay.slot("nope")["x"]), 0.5))
	_ok("未登记角色给全零", lay.character("谁")["offset"] == Vector2.ZERO)

	var c := Control.new()
	LayoutScript.place(c, 0.5, Vector2(200, 400), Vector2(10, -20))
	_ok("锚点落在底边中点", is_equal_approx(c.anchor_left, 0.5) and is_equal_approx(c.anchor_bottom, 1.0))
	_ok("宽 200 居中 + 偏移 10", is_equal_approx(c.offset_left, -90.0) and is_equal_approx(c.offset_right, 110.0))
	_ok("高 400 站地 + 抬高 20", is_equal_approx(c.offset_top, -420.0) and is_equal_approx(c.offset_bottom, -20.0))
	c.free()

	# 缩放：槽位 1.0 × 角色 0.5 → 尺寸减半
	lay.set_character("凛", Vector2.ZERO, 0.5)
	var px := lay.sprite_px(null, "凛", "center")
	_ok("角色缩放生效", is_equal_approx(px.x, lay.placeholder.x * 0.5))

	# 不存在的图返回空串，不是报错
	_ok("缺图返回空串", lay.chara_path("不存在的人", "default") == "")
	_ok("缺背景返回空串", lay.bg_path("不存在") == "")


## ---- 2. 存盘往返 ----

func _test_save_roundtrip() -> void:
	var lay: VNStageLayout = LayoutScript.new()
	lay.reset()
	lay.set_slot("left", 0.3, 1.1)
	lay.set_character("凛", Vector2(12, -8), 0.9)
	lay.characters["凛"]["_raw"] = {"note": "手写字段"}

	_ok("保存成功", lay.save_to(TMP) == OK)

	var back: VNStageLayout = LayoutScript.new()
	var issues := back.load_from(TMP)
	_ok("重载无问题", issues.is_empty())
	_ok("槽位 x 往返", is_equal_approx(float(back.slot("left")["x"]), 0.3))
	_ok("槽位 scale 往返", is_equal_approx(float(back.slot("left")["scale"]), 1.1))
	_ok("角色 offset 往返", back.character("凛")["offset"] == Vector2(12, -8))
	_ok("角色 scale 往返", is_equal_approx(float(back.character("凛")["scale"]), 0.9))
	_ok("手写字段不被吃掉", String(back.characters["凛"]["_raw"].get("note", "")) == "手写字段")

	# 坏文件不清空当前数据
	var bad := VNStageLayout.new()
	bad.reset()
	var bad_issues := bad.load_from("user://__nope__.json")
	_ok("坏路径报 1 条问题", bad_issues.size() == 1)
	_ok("坏路径不清空槽位", bad.slot_names().size() == 3)

	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


## ---- 3. 运行时契约 ----

func _test_stage_contract() -> void:
	var stage: VNSpriteStage = StageScript.new()
	root.add_child(stage)
	stage.size = Vector2(1920, 1080)
	await process_frame

	_ok("自动进 vn_stage 组", stage.is_in_group("vn_stage"))
	_ok("布局对象已建", stage.layout != null)

	# set_bg：await 之后必须是「已经可见」的那一帧，不是发起那一帧
	await stage.set_bg("教室", 0.03)
	_ok("set_bg 完成后背景可见", _bg_alpha(stage) > 0.99)

	# set_sprite：缺图 → 占位 + 淡入 + 落位
	await stage.set_sprite("凛", "平静", "left", 0.03)
	var spr: TextureRect = stage.sprite_node("凛")
	_ok("立绘节点已建", spr != null)
	_ok("缺图时用占位贴图", spr.texture != null)
	_ok("占位尺寸 = placeholder", spr.texture.get_size() == stage.layout.placeholder)
	_ok("淡入完成 a=1", is_equal_approx(spr.modulate.a, 1.0))
	_ok("left 锚点", is_equal_approx(spr.anchor_left, float(stage.layout.slot("left")["x"])))
	_ok("站地（底边对齐）", is_equal_approx(spr.anchor_bottom, 1.0) and is_equal_approx(spr.offset_bottom, 0.0))

	# 换表情：不重播淡入（否则会闪一下）
	await stage.set_sprite("凛", "微笑", "left", 0.03)
	_ok("换表情不闪", is_equal_approx(spr.modulate.a, 1.0))
	_ok("换表情记下了 pose", String(spr.get_meta("pose", "")) == "微笑")

	# 换槽位：同一节点，只改锚点
	await stage.set_sprite("凛", "微笑", "right", 0.03)
	_ok("换槽位生效", is_equal_approx(spr.anchor_left, float(stage.layout.slot("right")["x"])))
	_ok("换槽位没多建节点", stage.has_sprite("凛") and stage.get_child_count() == 3)

	# 未知槽位：回退 center，不报错中断
	await stage.set_sprite("凛", "微笑", "middle", 0.03)
	_ok("未知槽位回退 center", is_equal_approx(spr.anchor_left, 0.5))

	# 两个角色同时在场
	await stage.set_sprite("葵", "default", "left", 0.03)
	_ok("两个角色各自成节点", stage.sprite_node("葵") != null and stage.sprite_node("葵") != spr)

	stage.queue_free()
	await process_frame


## ---- 4. 编辑器面板 ----
##
## 面板不能只靠「打开编辑器看一眼」，那不可重复。这里直接驱动它的数据通路：
## 拖动改偏移、切槽位、存盘，然后检查结果。

func _test_panel() -> void:
	var panel: Control = PanelScript.new()
	root.add_child(panel)
	panel.size = Vector2(1200, 700)
	await _frames_of(4)

	_ok("面板建了 3 个槽位预览", panel._holders.size() == 3)

	var before: Vector2 = panel._lay.character("凛")["offset"]
	var ev := InputEventMouseMotion.new()
	ev.relative = Vector2(40, 20)
	panel._dragging = true
	panel._on_canvas_input(ev)
	panel._dragging = false
	var after: Vector2 = panel._lay.character("凛")["offset"]
	_ok("拖动改偏移", after != before)
	_ok("拖动按画布比例缩放", after.x > before.x and after.y > before.y)

	# 切槽位：预览里的锚点跟着换
	panel._slot_sel = "right"
	panel._rebuild_side()
	await _frames_of(2)
	var holder: Control = panel._holders["right"]
	_ok("切槽位后锚点对齐", is_equal_approx(holder.anchor_left, float(panel._lay.slot("right")["x"])))

	# 存盘：面板产出的就是运行时吃的那份 JSON
	panel._lay.path = TMP_PANEL
	panel._save_to(TMP_PANEL)
	_ok("面板能存盘", FileAccess.file_exists(TMP_PANEL))
	var back: VNStageLayout = LayoutScript.new()
	back.load_from(TMP_PANEL)
	var rt: Vector2 = back.character("凛")["offset"]
	# JSON 里偏移存整数，所以允许 1px 误差
	_ok("存盘内容能被运行时读回", absf(rt.x - after.x) <= 1.0 and absf(rt.y - after.y) <= 1.0)

	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PANEL))
	panel.queue_free()
	await process_frame


## ---- 断言 ----

func _frames_of(n: int) -> void:
	for _i in range(n):
		await process_frame


func _bg_alpha(stage: VNSpriteStage) -> float:
	var best := 0.0
	for n in stage.get_children():
		if n is TextureRect and String(n.name).begins_with("BG"):
			best = maxf(best, (n as TextureRect).modulate.a)
	return best


func _ok(what: String, cond: bool) -> void:
	if cond:
		_passes += 1
	else:
		_fails += 1
	print("[STAGE] %-28s %s" % [what, "OK" if cond else "FAIL"])

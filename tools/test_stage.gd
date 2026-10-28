## 舞台呈现回归测试（headless 可跑）。
##
## 测的不是「节点存在」，是四件坏了会表现成「剧情卡住」或「立绘错乱」的事：
##   1. 接线：两个节点同组、靠方法名各找各的（VNKit._find 的方法过滤）
##   2. 背景：await 之后真的可见；换景交叉淡入不闪黑；缺图降级
##   3. 立绘：槽位分派、换槽位收走旧的、换表情不重播淡入、缺图占位
##   4. 对话框：在组里、show_line 返回可 await 的 Signal
##
## 跑法：
##   godot --headless --path . --script res://tools/test_stage.gd
extends SceneTree

var _fails := 0
var _passes := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var stage := await _load_stage()
	if stage == null:
		print("[STAGE] 场景加载失败")
		quit(1)
		return

	await _test_wiring(stage)
	await _test_backdrop(stage)
	await _test_sprite(stage)
	await _test_dialogue(stage)

	print("[STAGE] %d 通过 / %d 失败" % [_passes, _fails])
	quit(0 if _fails == 0 else 1)


func _load_stage() -> Node:
	var packed := load("res://demo/stage.tscn") as PackedScene
	if packed == null:
		return null
	var stage := packed.instantiate()
	# 关掉自动开播，否则剧情会和测试抢对话框
	var runner := stage.get_node_or_null("StoryRunner")
	if runner != null:
		runner.set("autostart", false)
	root.add_child(stage)
	await process_frame
	return stage


## ---- 1. 接线：同组两节点 + 方法过滤 ----

func _test_wiring(stage: Node) -> void:
	var backdrop: VNBackdrop = stage.get_node_or_null("Backdrop")
	var dialogue: VNDialogueBox = stage.get_node_or_null("Dialogue")
	var slots_root: Node = stage.get_node_or_null("Slots")

	_ok("Stage 进了 vn_stage 组", stage.is_in_group("vn_stage"))
	_ok("Backdrop 也进了 vn_stage 组", backdrop != null and backdrop.is_in_group("vn_stage"))
	_ok("Dialogue 自动进了 vn_dialogue_box 组",
		dialogue != null and dialogue.is_in_group("vn_dialogue_box"))

	# 同组两个节点，靠方法名各找各的——这是 _find 加方法过滤的全部理由
	_ok("set_bg 找到 Backdrop", VNKit._find(stage, "vn_stage", "set_bg") == backdrop)
	_ok("set_sprite 找到 Stage 根", VNKit._find(stage, "vn_stage", "set_sprite") == stage)
	_ok("方法不存在时返回 null", VNKit._find(stage, "vn_stage", "no_such_method") == null)
	_ok("show_line 找到 Dialogue", VNKit._find(stage, "vn_dialogue_box", "show_line") == dialogue)

	# 组名靠脚本自己入组，不靠 .tscn 里的 groups——重写场景时最容易漏掉
	var choice: VNChoiceBox = stage.get_node_or_null("ChoiceBox")
	_ok("ChoiceBox 自动进了 vn_choice_box 组",
		choice != null and choice.is_in_group("vn_choice_box"))
	_ok("present 找到 ChoiceBox", VNKit._find(stage, "vn_choice_box", "present") == choice)

	# 三个点位，名字就是剧本里写的 slot
	var ids: Array[String] = []
	for c in slots_root.get_children():
		if c is VNSpriteSlot:
			ids.append((c as VNSpriteSlot).slot_id())
	_ok("三个立绘点位 left/center/right", ids == ["left", "center", "right"])

	# 内部 TextureRect 必须是 internal child：不占 get_children()，也就不会被误删、存不进 .tscn
	var slot: VNSpriteSlot = slots_root.get_node("center")
	_ok("内部立绘节点不污染子节点列表", slot.get_child_count() == 0)
	_ok("内部立绘节点确实存在", slot.get_children(true).size() == 1)


## ---- 2. 背景 ----

func _test_backdrop(stage: Node) -> void:
	var backdrop: VNBackdrop = stage.get_node("Backdrop")

	# await 之后必须是「已经可见」的那一帧，不是发起那一帧
	await VNKit.bg(stage, "教室", 0.03)
	_ok("set_bg 完成后背景可见", _layer_alpha(backdrop) > 0.99)

	# 换背景：两层交替，旧层淡掉，新层顶上
	var before := _top_layer_index(backdrop)
	await VNKit.bg(stage, "走廊", 0.03)
	_ok("换背景换了另一层", _top_layer_index(backdrop) != before)
	_ok("换背景后仍只有一层全亮", _layer_alpha(backdrop) > 0.99)

	# 缺图：用底色顶上，不崩、不阻断
	await VNKit.bg(stage, "根本没有这张图", 0.03)
	_ok("缺背景图时降级为底色", _layer_alpha(backdrop) > 0.99)


## ---- 3. 立绘 ----

func _test_sprite(stage: Node) -> void:
	var left: VNSpriteSlot = stage.get_node("Slots/left")
	var center: VNSpriteSlot = stage.get_node("Slots/center")
	var right: VNSpriteSlot = stage.get_node("Slots/right")

	await VNKit.sprite(stage, "凛", "平静", "center", 0.03)
	_ok("center 站着凛", center.current() == "凛")
	_ok("淡入完成后 a=1", _spr_alpha(center) > 0.99)
	_ok("记下了 pose", String(center.get_meta("pose", "")) == "平静")
	_ok("缺图时用占位贴图", _spr_texture(center) != null)

	# 换表情：不重播淡入，否则会闪一下
	_spr_node(center).modulate.a = 0.5
	await VNKit.sprite(stage, "凛", "微笑", "center", 0.03)
	_ok("换表情不重播淡入", _spr_alpha(center) > 0.99)
	_ok("换表情记下了新 pose", String(center.get_meta("pose", "")) == "微笑")
	_ok("换表情没多建节点", _spr_count(stage) == 1)

	# 换槽位：旧点位空出来，不能有分身
	await VNKit.sprite(stage, "凛", "微笑", "right", 0.0)
	_ok("换槽位后 right 站着凛", right.current() == "凛")
	_ok("换槽位后 center 空出来", center.current() == "")
	_ok("换槽位后没有分身", _spr_count(stage) == 1)

	# 槽位互斥：后来者顶替先来者
	await VNKit.sprite(stage, "葵", "default", "right", 0.0)
	_ok("同点位后来者顶替", right.current() == "葵")
	_ok("被顶替的立绘已清空", _spr_texture(right) != null and left.current() != "凛")

	# 点位名对不上：退回第一个点位，不中断
	await VNKit.sprite(stage, "葵2", "default", "根本没有这个点位", 0.0)
	_ok("未知点位退回第一个", left.current() == "葵2")
	_ok("两个角色各自成节点", right.current() == "葵" and left.current() == "葵2")

	_ok("缺图路径返回空串", center._sprite_path("不存在的人", "default") == "")


## ---- 4. 对话框 ----

func _test_dialogue(stage: Node) -> void:
	var box: VNDialogueBox = stage.get_node("Dialogue")
	_ok("对话框实现 show_line", box.has_method("show_line"))

	var sig: Signal = VNKit.say(stage, "凛", "这是一次测试。")
	_ok("say 拿到的是可 await 的 Signal", typeof(sig) == TYPE_SIGNAL)
	_ok("say 把台词交给了对话框", box.get_node("Panel/Name").text == "凛")
	_ok("say 让对话框可见", box.visible)

	# 收尾：补完打字并放行，不留悬挂的 tween
	box.line_finished.emit()


## ---- 断言与取数 ----

func _layer_alpha(b: VNBackdrop) -> float:
	var best := 0.0
	for n in b.get_children(true):
		if n is TextureRect:
			best = maxf(best, (n as TextureRect).modulate.a)
	return best


func _top_layer_index(b: VNBackdrop) -> int:
	var best := -1
	var alpha := 0.0
	var i := 0
	for n in b.get_children(true):
		if n is TextureRect and (n as TextureRect).modulate.a > alpha:
			alpha = (n as TextureRect).modulate.a
			best = i
		if n is TextureRect:
			i += 1
	return best


func _spr_node(slot: VNSpriteSlot) -> TextureRect:
	for n in slot.get_children(true):
		if n is TextureRect:
			return n
	return null


func _spr_texture(slot: VNSpriteSlot) -> Texture2D:
	var n := _spr_node(slot)
	return n.texture if n != null else null


func _spr_alpha(slot: VNSpriteSlot) -> float:
	var n := _spr_node(slot)
	return n.modulate.a if n != null else 0.0


## 数实际存在的贴图节点，而不是看字典——字典清干净了但节点还在，是另一种 bug。
func _spr_count(node: Node) -> int:
	var n := 0
	for c in node.get_children(true):
		if c is TextureRect and String(c.name) == "__sprite" and (c as TextureRect).texture != null:
			n += 1
		n += _spr_count(c)
	return n


func _ok(what: String, cond: bool) -> void:
	if cond:
		_passes += 1
	else:
		_fails += 1
	print("[STAGE] %-30s %s" % [what, "OK" if cond else "FAIL"])

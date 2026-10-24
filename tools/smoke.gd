## headless 冒烟测试：模拟鼠标点击，验证「图在路由」而不是写死顺序。
##
## 运行：
##   Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://tools/smoke.gd
## 选第二项（走另一条边）：
##   VN_PICK=1 Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://tools/smoke.gd
extends SceneTree

const CLICK_AT := Vector2(960, 490)
const CLICKS := 40
const INTERVAL := 0.28


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var pick := 0
	if OS.has_environment("VN_PICK"):
		pick = int(OS.get_environment("VN_PICK"))
	print("[SMOKE] 预期选择第 %d 项" % pick)

	var scene = load("res://demo/stage.tscn").instantiate()
	root.add_child(scene)
	await process_frame

	var runner := root.get_node_or_null("Stage/StoryRunner")
	var done := [false]
	if runner != null:
		runner.transition_taken.connect(_on_transition)
		runner.finished.connect(func() -> void: done[0] = true)
	else:
		push_error("[SMOKE] 没找到 Stage/StoryRunner")

	for i in CLICKS:
		if done[0]:
			break
		await create_timer(INTERVAL).timeout
		_click()
		await process_frame
		_auto_pick(pick)
		await process_frame

	if runner != null:
		print("[SMOKE] 结果：状态=%s 参数=%s" % [runner.current, runner.params])
		print("[SMOKE] %s" % ("已走到终止" if done[0] else "未结束（可能点击次数不够）"))
	print("[SMOKE] 完成")
	quit(0)


func _on_transition(from_id: String, to_id: String, guard: String) -> void:
	var label := "默认" if guard.strip_edges() == "" else guard
	print("[SMOKE] 边 %s --(%s)--> %s" % [from_id, label, to_id])


## headless 下鼠标 hit test 不可靠，选项直接触发按钮信号。
func _auto_pick(index: int) -> void:
	var box := root.get_node_or_null("Stage/ChoiceBox")
	if box == null or not box.visible:
		return
	var list := box.get_node_or_null("Center/List")
	if list == null or list.get_child_count() <= index:
		return
	var button := list.get_child(index)
	if button is Button:
		print("[SMOKE] 自动选择：%s" % button.text)
		button.pressed.emit()


func _click() -> void:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = CLICK_AT
	Input.parse_input_event(down)

	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = CLICK_AT
	Input.parse_input_event(up)

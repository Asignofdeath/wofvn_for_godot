## 可选的路由器节点：按图播章节。
##
## 不用它也完全能跑，手写就是这几行：
##     var ch := load("res://demo/story/ch01.gd").new()
##     add_child(ch)
##     ch.play()
##     await ch.finished
##
## 设计约束：
## - 不是 autoload，不当根节点，不接管场景切换，不接管 root。
## - 只认两件事：章节节点有 play()，有 finished 信号。不要求继承任何基类。
## - 参数状态存在自己身上（用户 add_child 进来的节点），删掉节点等于结束这场播放。
## - 图只决定「下一段是谁」；章节内部怎么走，由 .gd 里的 if / for / await 决定。
class_name StoryRunner
extends Node

const GROUP := "vn_story"
## 防御：图成环且 guard 恒真时会无限跑，超过这么多次就停。
const MAX_HOPS := 1000

## 进入一个状态（章节或终止）
signal state_entered(id: String)
## 命中一条边
signal transition_taken(from_id: String, to_id: String, guard: String)
signal finished

@export_file("*.json") var graph_path := ""
## 在场景里放好就自动开播。脚本调用 start() 时无视它。
@export var autostart := true

## 载入后的图。start() 之前为 null。
var graph: StoryGraph
## 本局的参数表，_load_graph() 时从图里的 default 复制一份。
## 存在自己身上而不是全局，所以同时播两场互不干扰，删节点就等于结束这场。
var params: Dictionary = {}
## 当前所在状态 id。给外部查进度用（不含「将要进入」的那个）。
var current := ""

## start() 到 _finish() 之间为 true，防止重复开播。
var _running := false


func _ready() -> void:
	add_to_group(GROUP)
	if not autostart or Engine.is_editor_hint():
		return
	start()


## 开播。返回 finished 信号，直接 await 即可。
func start(path: String = "") -> Signal:
	if _running:
		push_warning("[StoryRunner] 已在播放，忽略重复 start()")
		return finished
	if path != "":
		graph_path = path
	_running = true
	_run.call_deferred()
	return finished


## ---- 参数表。剧本通过 VNKit.add_param / set_param 调用 ----

func add_param(key: String, delta: Variant) -> void:
	if not params.has(key):
		push_warning("[StoryRunner] 未知参数：%s" % key)
		return
	var cur: Variant = params[key]
	if cur is bool:
		push_warning("[StoryRunner] %s 是 flag，请用 set_param" % key)
		return
	# 按参数表声明的类型归一化，否则 int 参数被浮点加一次就变成 5.0
	params[key] = _coerce(key, cur + delta)


## 按图里声明的 type 把值掰回来。没有 graph（未开播）时按值本身推断。
func _coerce(key: String, value: Variant) -> Variant:
	var declared := "int"
	if graph != null and graph.params.has(key):
		declared = String(graph.params[key]["type"])
	match declared:
		"flag", "bool":
			return bool(value)
		"float":
			return float(value)
		"string":
			return String(value)
		_:
			return int(value)


func set_param(key: String, value: Variant) -> void:
	if not params.has(key):
		push_warning("[StoryRunner] 未知参数：%s" % key)
		return
	params[key] = value


func get_param(key: String, fallback: Variant = null) -> Variant:
	return params.get(key, fallback)


## ---- 内部 ----

func _run() -> void:
	_load_graph()
	if graph == null or graph.errors.size() > 0:
		_finish()
		return
	_check_collaborators()

	var id := graph.entry
	var hops := 0

	while true:
		if hops >= MAX_HOPS:
			push_error("[StoryRunner] 超过 %d 次跳转，疑似死循环，强制停止" % MAX_HOPS)
			break
		hops += 1

		var st: Dictionary = graph.get_state(id)
		if st.is_empty():
			push_error("[StoryRunner] 状态不存在：%s" % id)
			break

		current = id
		state_entered.emit(id)

		if String(st["type"]) == StoryGraph.TYPE_END:
			print("[Runner] 终止于 %s（参数 %s）" % [id, params])
			break

		print("[Runner] %s" % id)
		var played: bool = await _play_state(st)
		if not played:
			break

		var tr: Dictionary = graph.pick_transition(id, params)
		if tr.is_empty():
			push_error("[Runner] %s 没有可走的边（参数 %s）" % [id, params])
			break

		var guard: String = tr["guard"]
		var label := "默认" if guard.strip_edges() == "" else guard
		print("[Story] %s --(%s)--> %s" % [id, label, tr["to"]])
		transition_taken.emit(id, String(tr["to"]), guard)
		id = String(tr["to"])

	_finish()


## 开播前自检：VNKit 靠组名找协作节点，缺了只会跑到那一步才报错，
## 而且降级成"一闪而过"，日志里很容易被忽略。开场一次性列清楚。
func _check_collaborators() -> void:
	var need := {
		VNKit.GROUP_STAGE: "set_bg(id, fade) / set_sprite(who, pose, slot, fade)",
		VNKit.GROUP_DIALOGUE: "show_line(speaker, text) -> Signal",
		VNKit.GROUP_CHOICE: "present(options) -> int",
	}
	var missing: Array[String] = []
	for group: String in need:
		if get_tree().get_first_node_in_group(group) == null:
			missing.append("  - %s（需要 %s）" % [group, need[group]])
	if missing.is_empty():
		return
	push_warning("[StoryRunner] 缺少协作节点，用到时会跳过：\n%s" % "\n".join(missing))


## 载图并把 errors / warnings 搬到编辑器日志里。有 errors 就返回（参数表也不初始化）。
func _load_graph() -> void:
	graph = StoryGraph.load_file(graph_path)
	for msg in graph.errors:
		push_error("[StoryGraph] %s" % msg)
	for msg in graph.warnings:
		push_warning("[StoryGraph] %s" % msg)
	if graph.errors.size() > 0:
		push_error("[StoryRunner] 图有 %d 处错误，不启动" % graph.errors.size())
		return
	params = graph.initial_params()
	print("[Graph] %d states / %d transitions / %d params" % [
		graph.states.size(), graph.transition_count(), graph.params.size()
	])


## 播一个章节状态。返回 false 表示这一节没法播，整场应当停下。
func _play_state(st: Dictionary) -> bool:
	var path := String(st.get("chapter", ""))
	if path == "":
		push_error("[StoryRunner] 状态 %s 没有指定章节脚本" % st["id"])
		return false

	var script: GDScript = load(path)
	if script == null:
		push_error("[StoryRunner] 载入章节失败：%s" % path)
		return false

	var node: Node = script.new()
	if not node.has_method("play"):
		push_error("[StoryRunner] %s 缺少 play()" % path)
		node.free()
		return false
	if not node.has_signal("finished"):
		push_error("[StoryRunner] %s 缺少 finished 信号" % path)
		node.free()
		return false

	add_child(node)
	# 先挂起 play()，再 await，避免空章节在 await 之前就 emit 造成死等。
	node.play.call_deferred()
	await node.finished
	node.queue_free()
	return true


## 收尾：置回未运行态并 emit。正常走完、校验失败、中途出错都走这里，保证 finished 一定发。
func _finish() -> void:
	_running = false
	finished.emit()

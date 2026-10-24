## 布局回归测试（headless 可跑）。
##
## 复现「父容器反复改尺寸」的场景：编辑器主屏幕区在拖控制台分隔条、拉窗口时会这样。
##
## 判定两件事：
##   1. 面板撑满 MainScreen
##   2. 画布 == 面板减去顶栏与底栏
##
## 跑法：
##   godot --headless --path . --script res://tools/test_layout.gd
extends SceneTree

const FlowScript := preload("res://addons/vn/editor/flow_screen.gd")

const TOP_H := 52
const HINT_H := 26
const EPS := 0.51

var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# 照实镜像编辑器：父节点是 VBoxContainer（编辑器里叫 MainScreen），
	# 里面除了本插件还有别的已隐藏的屏幕节点。
	var host := VBoxContainer.new()
	host.name = "MainScreen"
	host.size = Vector2(1060, 786)
	root.add_child(host)

	var other := Control.new()
	other.name = "AnotherScreen"
	other.visible = false
	host.add_child(other)

	var screen: Control = FlowScript.new()
	host.add_child(screen)

	await _frames(3)
	_check("初始 786", host, screen)

	# 模拟：把控制台分隔条一路往上拖
	for h in [640, 420, 260, 180]:
		host.size = Vector2(1060, h)
		await _frames(2)
		_check("缩小到 %d" % h, host, screen)

	# 再拖回来 / 拉大窗口
	for h in [700, 986]:
		host.size = Vector2(1060, h)
		await _frames(2)
		_check("放大到 %d" % h, host, screen)

	# 宽度也要跟
	host.size = Vector2(660, 500)
	await _frames(2)
	_check("窄窗口 660x500", host, screen)

	print("[LAYOUT] %s" % ("全部通过" if _fails == 0 else "%d 项失败" % _fails))
	quit(0 if _fails == 0 else 1)


func _check(tag: String, host: Control, screen: Control) -> void:
	var screen_ok := _near(screen.size, host.size)
	var graph: Control = screen.get_node_or_null("Root/Graph")
	var graph_want := Vector2(host.size.x, maxf(host.size.y - TOP_H - HINT_H, 0.0))
	var graph_ok := graph != null and _near(graph.size, graph_want)

	var ok := screen_ok and graph_ok
	if not ok:
		_fails += 1
	print("[LAYOUT] %-14s host=%s 面板=%s 画布=%s(期望 %s) %s" % [
		tag, str(host.size), str(screen.size),
		str(graph.size if graph != null else Vector2.ZERO), str(graph_want),
		"OK" if ok else "FAIL"])


func _near(a: Vector2, b: Vector2) -> bool:
	return absf(a.x - b.x) <= EPS and absf(a.y - b.y) <= EPS


func _frames(n: int) -> void:
	for _i in range(n):
		await process_frame

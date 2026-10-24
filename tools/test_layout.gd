## 布局回归测试（headless 可跑）。
##
## 复现"父容器反复改尺寸"场景：编辑器主屏幕区在拖控制台分隔条、拉窗口时会这样。
## 判定标准：面板与画布必须每一轮都等于父容器可用区域，不能被上一轮的尺寸卡死。
##
## 跑法：
##   godot --headless --path . --script res://tools/test_layout.gd
extends SceneTree

const FlowScreen := preload("res://addons/vn/editor/flow_screen.gd")

const TOP_H := 52
const HINT_H := 26

var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# 照实镜像编辑器：父节点是 VBoxContainer（编辑器里叫 MainScreen），
	# 里面除了本面板还可能有别的已隐藏的屏幕节点。
	var host := VBoxContainer.new()
	host.name = "MainScreen"
	host.size = Vector2(1060, 786)
	root.add_child(host)

	var other := Control.new()
	other.name = "AnotherScreen"
	other.visible = false
	host.add_child(other)

	var screen: Control = FlowScreen.new()
	host.add_child(screen)

	await _frames(2)
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
	var graph: Control = screen.get_node_or_null("Root/Graph")
	var want := host.size
	var got := screen.size
	var gsize := graph.size if graph != null else Vector2.ZERO
	var want_body := maxf(want.y - TOP_H - HINT_H, 40.0)
	var ok := got.is_equal_approx(want) and is_equal_approx(gsize.y, want_body) \
		and is_equal_approx(gsize.x, want.x)
	if not ok:
		_fails += 1
	print("[LAYOUT] %-14s host=%s screen=%s graph=%s me=%s" % [
		tag, str(want), str(got), str(gsize), "OK" if ok else "FAIL"])


func _frames(n: int) -> void:
	for _i in range(n):
		await process_frame

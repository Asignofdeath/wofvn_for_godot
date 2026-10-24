## 布局回归测试（headless 可跑）。
##
## 复现「父容器反复改尺寸」的场景：编辑器主屏幕区在拖控制台分隔条、拉窗口时会这样。
## 现在主屏幕里多了一层 TabContainer（一个插件只能有一个主屏幕），所以断言的是
## 「面板 == 宿主减去标签栏的高度」，而不是整个宿主——这一层要照实镜像，否则测了等于没测。
##
## 判定三件事：
##   1. 宿主撑满 MainScreen
##   2. 流程图面板 == 宿主可用区；画布 == 面板减去顶栏底栏
##   3. 立绘摆位面板同样撑满；预览画布是 16:9 且不为零
##
## 跑法：
##   godot --headless --path . --script res://tools/test_layout.gd
extends SceneTree

const HomeScript := preload("res://addons/vn/editor/vn_home.gd")

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

	var home: TabContainer = HomeScript.new()
	host.add_child(home)

	await _frames(3)
	_check("初始 786", host, home)

	# 模拟：把控制台分隔条一路往上拖
	for h in [640, 420, 260, 180]:
		host.size = Vector2(1060, h)
		await _frames(2)
		_check("缩小到 %d" % h, host, home)

	# 再拖回来 / 拉大窗口
	for h in [700, 986]:
		host.size = Vector2(1060, h)
		await _frames(2)
		_check("放大到 %d" % h, host, home)

	# 宽度也要跟
	host.size = Vector2(660, 500)
	await _frames(2)
	_check("窄窗口 660x500", host, home)

	# 切到第二个标签，隐藏期间也要保持正确尺寸，切过去才会是对的
	home.current_tab = 1
	await _frames(3)
	_check("切到立绘摆位", host, home)

	print("[LAYOUT] %s" % ("全部通过" if _fails == 0 else "%d 项失败" % _fails))
	quit(0 if _fails == 0 else 1)


## TabContainer 只给「当前标签」排版，隐藏的标签尺寸是 0——这是引擎行为，不是缺陷。
## 所以只断言当前可见的那个面板，切标签后再断言另一个。
func _check(tag: String, host: Control, home: TabContainer) -> void:
	var bar := home.get_tab_bar()
	var bar_h := bar.size.y if bar != null else 0.0
	var want := host.size - Vector2(0, bar_h)

	var idx := home.current_tab
	var screen: Control = home.get_child(idx)
	var home_ok := _near(home.size, host.size)
	var screen_ok := _near(screen.size, want)

	var detail := ""
	var extra_ok := false
	if idx == 0:
		var graph: Control = screen.get_node_or_null("Root/Graph")
		var graph_want := Vector2(want.x, maxf(want.y - TOP_H - HINT_H, 0.0))
		extra_ok = graph != null and _near(graph.size, graph_want)
		detail = "画布=%s" % str(graph.size if graph != null else Vector2.ZERO)
	else:
		var canvas: Control = screen.get_node_or_null("Root/Body/Preview/Aspect/Canvas")
		if canvas != null and canvas.size.x > 1.0 and canvas.size.y > 1.0:
			var ratio := canvas.size.x / canvas.size.y
			extra_ok = absf(ratio - 16.0 / 9.0) < 0.02
			detail = "预览=%s(%.2f)" % [str(canvas.size), ratio]
		else:
			detail = "预览=(0,0)"

	var ok := home_ok and screen_ok and extra_ok
	if not ok:
		_fails += 1
	print("[LAYOUT] %-14s host=%s want=%s 面板=%s %s me=%s" % [
		tag, str(host.size), str(want), str(screen.size), detail, "OK" if ok else "FAIL"])


func _near(a: Vector2, b: Vector2) -> bool:
	return absf(a.x - b.x) <= EPS and absf(a.y - b.y) <= EPS


func _frames(n: int) -> void:
	for _i in range(n):
		await process_frame

## VNKit.join 的回归：并行合流必须等最慢的那个，不能提前也不能挂死。
##
## 运行：
##   godot --headless --path . --script res://tools/test_join.gd
##
## 这个测试不起场景，只用一个空 Node 当 host——join 只碰 SceneTree，
## 不该依赖舞台、对话框或任何模板节点。
extends SceneTree

const TOLERANCE_MS := 120

var _pass := 0
var _fail := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var host := Node.new()
	root.add_child(host)
	await process_frame

	await _test_waits_slowest(host)
	await _test_empty(host)
	await _test_with_null(host)
	await _test_single(host)

	print("[JOIN] %d 通过 / %d 失败" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)


## 0.1s + 0.3s 同时起跑：必须等 0.3s 那个。
## 逐个 await 的写法会在这里挂死（0.1s 的信号早已发过）。
func _test_waits_slowest(host: Node) -> void:
	var a := host.get_tree().create_timer(0.1)
	var b := host.get_tree().create_timer(0.3)

	var start := Time.get_ticks_msec()
	await VNKit.join(host, [a.timeout, b.timeout])
	var elapsed := Time.get_ticks_msec() - start

	_check(elapsed >= 300 - TOLERANCE_MS, "合流：不会提前返回", "用了 %d ms" % elapsed)
	_check(elapsed < 300 + TOLERANCE_MS * 3, "合流：不会永久挂起", "用了 %d ms" % elapsed)


func _test_empty(host: Node) -> void:
	var start := Time.get_ticks_msec()
	await VNKit.join(host, [])
	var elapsed := Time.get_ticks_msec() - start
	_check(elapsed < 100, "合流：空数组等一帧就返回", "用了 %d ms" % elapsed)


## 生成器不会传 null，但手写调用可能混进坏值。坏值要跳过，不能把计数卡死。
func _test_with_null(host: Node) -> void:
	var a := host.get_tree().create_timer(0.15)
	var start := Time.get_ticks_msec()
	await VNKit.join(host, [null, a.timeout, null])
	var elapsed := Time.get_ticks_msec() - start
	_check(elapsed >= 150 - TOLERANCE_MS, "合流：跳过 null", "用了 %d ms" % elapsed)
	_check(elapsed < 500, "合流：null 不卡计数", "用了 %d ms" % elapsed)


func _test_single(host: Node) -> void:
	var a := host.get_tree().create_timer(0.12)
	var start := Time.get_ticks_msec()
	await VNKit.join(host, [a.timeout])
	var elapsed := Time.get_ticks_msec() - start
	_check(elapsed >= 120 - TOLERANCE_MS, "合流：单个信号", "用了 %d ms" % elapsed)


func _check(cond: bool, name: String, detail := "") -> void:
	if cond:
		_pass += 1
		print("[PASS] %s" % name)
	else:
		_fail += 1
		print("[FAIL] %s%s" % [name, "" if detail == "" else "  :: " + detail])

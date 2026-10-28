## VN 工具集：剧本里可 await 的几个动作。
##
## 设计约束：
## - 不持有状态，不依赖基类，不是 autoload。
## - 靠「组名 + 方法名」找协作节点，找不到就报错降级，不中断其它系统。
## - 剧情逻辑写在 .gd 里，这里只提供动作。
##
## 用法：
##   await VNKit.say(self, "凛", "你还没走？")
##   var i: int = await VNKit.choice(self, ["选项甲", "选项乙"])
class_name VNKit
extends RefCounted

## 四个约定组名。插件认的全部契约就是这四个字符串 + 下面几个方法签名。
## 没有基类、没有注册表：节点加进组、实现方法，就被找到了。
const GROUP_DIALOGUE := "vn_dialogue_box"   ## 需要 show_line(speaker, text) -> Signal
const GROUP_CHOICE := "vn_choice_box"       ## 需要 present(options) -> int
const GROUP_STAGE := "vn_stage"             ## 需要 set_bg(id, fade) / set_sprite(who, pose, slot, fade)
const GROUP_STORY := "vn_story"             ## StoryRunner，参数表的持有者


## 显示一句对白，等到玩家点击推进后返回。
static func say(host: Node, speaker: String, text: String) -> Signal:
	var box := _find(host, GROUP_DIALOGUE, "show_line")
	if box == null:
		push_error("[VNKit] 缺少对话框：组 %s 内需实现 show_line(speaker, text) -> Signal" % GROUP_DIALOGUE)
		return _next_frame(host)
	return box.show_line(speaker, text)


## 切换背景，等淡入完成。
static func bg(host: Node, id: String, fade: float = 0.4) -> Signal:
	var stage := _find(host, GROUP_STAGE, "set_bg")
	if stage == null:
		push_error("[VNKit] 缺少舞台：组 %s 内需实现 set_bg(id, fade) -> Signal" % GROUP_STAGE)
		return _next_frame(host)
	return stage.set_bg(id, fade)


## 把角色立绘放到槽位（left / center / right），等淡入完成。
static func sprite(
	host: Node,
	who: String,
	pose: String = "default",
	slot: String = "center",
	fade: float = 0.2
) -> Signal:
	var stage := _find(host, GROUP_STAGE, "set_sprite")
	if stage == null:
		push_error("[VNKit] 缺少舞台：组 %s 内需实现 set_sprite(who, pose, slot, fade)" % GROUP_STAGE)
		return _next_frame(host)
	return stage.set_sprite(who, pose, slot, fade)


## 显示选项并等待选择，返回下标。
static func choice(host: Node, options: Array) -> int:
	var box := _find(host, GROUP_CHOICE, "present")
	if box == null:
		push_error("[VNKit] 缺少选项框：组 %s 内需实现 present(options) -> int" % GROUP_CHOICE)
		return 0
	var index: int = await box.present(options)
	return index


## 同一拍里多个「阻塞动作」的合流：全部启动，一次等齐。
##
## 语义来源：Web 版运行时 engine.js 的 _runStep 把 BLOCKING 类命令的
## promise 收进 blockers，最后 Promise.all(blockers)（engine.js:470）。
## 本方法就是它的 GDScript 对应物。注意：背景 / 立绘不是阻塞动作，
## Web 版从不等待它们，这里也不该把它们的信号喂进来。
##
## 为什么不能「先取 Signal 再逐个 await」：Tween.finished 只发一次。
## 先完成的那个（0.2s 的立绘）在后一个 await（2s 的背景）之后早已发过，
## 再去 await 它会永久挂起。所以必须一次监听全部信号。
##
## 用法：
##     var a := VNKit.say(self, "凛", "……")
##     var b := get_tree().create_timer(1.5).timeout
##     await VNKit.join(self, [a, b])
##
## 它是协程（返回 void），不是返回 Signal 的工厂：计数器必须留在协程栈上，
## 否则 RefCounted 在 await 挂起时就被回收了，「done」连连接对象都没有。
##
## 前提：动作必须在启动后至少一帧才 emit。show_line 与 create_timer 都满足。
static func join(host: Node, signals: Array) -> void:
	var valid: Array = []
	for s in signals:
		if typeof(s) == TYPE_SIGNAL:
			valid.append(s)

	if valid.is_empty():
		await _next_frame(host)
		return

	var gate := _Join.new(valid.size())
	for s in valid:
		s.connect(gate.one, CONNECT_ONE_SHOT)
	await gate.done


## ---- 参数表。供图里的 guard 使用，剧本不知道 StoryRunner 是什么类 ----

## 数值累加。flag 类型请用 set_param。
static func add_param(host: Node, key: String, delta: Variant) -> void:
	var runner := _find(host, GROUP_STORY, "add_param")
	if runner == null:
		push_warning("[VNKit] 没有 StoryRunner（组 %s），参数 %s 被忽略" % [GROUP_STORY, key])
		return
	runner.add_param(key, delta)


static func set_param(host: Node, key: String, value: Variant) -> void:
	var runner := _find(host, GROUP_STORY, "set_param")
	if runner == null:
		push_warning("[VNKit] 没有 StoryRunner（组 %s），参数 %s 被忽略" % [GROUP_STORY, key])
		return
	runner.set_param(key, value)


## 读参数。没有 StoryRunner 时返回 fallback，不报错——剧本可以当它永远跑在「无路由」环境里。
static func get_param(host: Node, key: String, fallback: Variant = null) -> Variant:
	var runner := _find(host, GROUP_STORY, "get_param")
	if runner == null:
		return fallback
	return runner.get_param(key, fallback)


## 从 host 所在的场景树里找第一个在 group 里、并且实现了 method 的节点。
## 用引擎自带的组查找，不自建注册表：删掉插件，这个组和这些方法仍然归用户所有。
##
## 为什么要校验方法名：同一个组允许有多个节点。例如背景和立绘分属两个节点、
## 都进 vn_stage（一个实现 set_bg，一个实现 set_sprite）。此时
## get_first_node_in_group() 返回谁全看场景树顺序，等于靠运气。按方法名挑，
## 「一个组拆成几个节点」就变成合法用法，谁先谁后都不影响。
static func _find(host: Node, group: String, method: String) -> Node:
	if host == null or not host.is_inside_tree():
		return null
	for n in host.get_tree().get_nodes_in_group(group):
		if n != null and n.has_method(method):
			return n
	return null


## 协作节点缺失时的降级返回值：等一帧就返回，让剧本照常往下走而不是卡死。
static func _next_frame(host: Node) -> Signal:
	assert(host != null and host.is_inside_tree(), "VNKit: host 必须已在场景树中")
	return host.get_tree().process_frame


## join 的计数器。RefCounted 而不是 Node：它不该进场景树，
## 生命周期由那些信号连接持有，全部到齐即随连接释放。
class _Join:
	extends RefCounted

	signal done

	var _left := 0

	func _init(n: int) -> void:
		_left = n

	func one() -> void:
		_left -= 1
		if _left <= 0:
			done.emit()

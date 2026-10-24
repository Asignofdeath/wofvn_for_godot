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

const GROUP_DIALOGUE := "vn_dialogue_box"
const GROUP_CHOICE := "vn_choice_box"
const GROUP_STAGE := "vn_stage"
const GROUP_STORY := "vn_story"


## 显示一句对白，等到玩家点击推进后返回。
static func say(host: Node, speaker: String, text: String) -> Signal:
	var box := _find(host, GROUP_DIALOGUE)
	if box == null or not box.has_method("show_line"):
		push_error("[VNKit] 缺少对话框：组 %s 内需实现 show_line(speaker, text) -> Signal" % GROUP_DIALOGUE)
		return _next_frame(host)
	return box.show_line(speaker, text)


## 切换背景，等淡入完成。
static func bg(host: Node, id: String, fade: float = 0.4) -> Signal:
	var stage := _find(host, GROUP_STAGE)
	if stage == null or not stage.has_method("set_bg"):
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
	var stage := _find(host, GROUP_STAGE)
	if stage == null or not stage.has_method("set_sprite"):
		push_error("[VNKit] 缺少舞台：组 %s 内需实现 set_sprite(who, pose, slot, fade)" % GROUP_STAGE)
		return _next_frame(host)
	return stage.set_sprite(who, pose, slot, fade)


## 显示选项并等待选择，返回下标。
static func choice(host: Node, options: Array) -> int:
	var box := _find(host, GROUP_CHOICE)
	if box == null or not box.has_method("present"):
		push_error("[VNKit] 缺少选项框：组 %s 内需实现 present(options) -> int" % GROUP_CHOICE)
		return 0
	var index: int = await box.present(options)
	return index


## ---- 参数表。供图里的 guard 使用，剧本不知道 StoryRunner 是什么类 ----

## 数值累加。flag 类型请用 set_param。
static func add_param(host: Node, key: String, delta: Variant) -> void:
	var runner := _find(host, GROUP_STORY)
	if runner == null or not runner.has_method("add_param"):
		push_warning("[VNKit] 没有 StoryRunner（组 %s），参数 %s 被忽略" % [GROUP_STORY, key])
		return
	runner.add_param(key, delta)


static func set_param(host: Node, key: String, value: Variant) -> void:
	var runner := _find(host, GROUP_STORY)
	if runner == null or not runner.has_method("set_param"):
		push_warning("[VNKit] 没有 StoryRunner（组 %s），参数 %s 被忽略" % [GROUP_STORY, key])
		return
	runner.set_param(key, value)


static func get_param(host: Node, key: String, fallback: Variant = null) -> Variant:
	var runner := _find(host, GROUP_STORY)
	if runner == null or not runner.has_method("get_param"):
		return fallback
	return runner.get_param(key, fallback)


## 存档点占位。等 rollback 方案（A/B/C）定了再实现。
static func checkpoint(_host: Node, _tag: String = "") -> void:
	pass


static func _find(host: Node, group: String) -> Node:
	if host == null or not host.is_inside_tree():
		return null
	return host.get_tree().get_first_node_in_group(group)


static func _next_frame(host: Node) -> Signal:
	assert(host != null and host.is_inside_tree(), "VNKit: host 必须已在场景树中")
	return host.get_tree().process_frame

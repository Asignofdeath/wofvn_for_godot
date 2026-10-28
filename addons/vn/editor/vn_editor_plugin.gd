## 插件入口：把一个双标签面板挂到编辑器顶部的主屏幕区。
## 第 1 个标签是章节路由图，第 2 个是剧本源文件（.script.txt）。
##
## 刻意不做的事：
## - 不注册 autoload，不改项目设置
## - 不改写场景、不接管已有节点
## - 面板关掉、甚至删掉整个 addons/vn/ 都不影响任何运行时行为
## - 不重造引擎编辑器：布局 / 摆位 / 动画都交给 Godot 自己那些视图
@tool
extends EditorPlugin

## 面板脚本。preload 而不是 class_name，是为了让插件整体拷走时不必先在项目里注册类名。
const FlowScreen := preload("res://addons/vn/editor/flow_screen.gd")
const DslScreen := preload("res://addons/vn/editor/dsl/dsl_screen.gd")

## 主屏幕上的标签容器。_make_visible 只切 visible，不增删节点。
var _tabs: TabContainer


## 挂面板。两个子面板自己都挂了 SIZE_EXPAND_FILL：
## 编辑器主屏幕是一个 VBoxContainer，不挂 EXPAND 就只得到一条按最小高度的矮带。
func _enter_tree() -> void:
	_tabs = TabContainer.new()
	_tabs.name = "VN"
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var flow: Control = FlowScreen.new()
	flow.name = "导图"
	_tabs.add_child(flow)

	var script_screen: Control = DslScreen.new()
	script_screen.name = "剧本"
	_tabs.add_child(script_screen)

	EditorInterface.get_editor_main_screen().add_child(_tabs)
	_make_visible(false)
	print("[VN] 已注册两个面板（顶部主屏幕标签「VN」：导图 / 剧本）")


func _exit_tree() -> void:
	if is_instance_valid(_tabs):
		_tabs.queue_free()
	_tabs = null


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "VN"


func _get_plugin_icon() -> Texture2D:
	var editor_theme := EditorInterface.get_editor_theme()
	if editor_theme == null:
		return null
	return editor_theme.get_icon("GraphEdit", "EditorIcons")


func _make_visible(visible_now: bool) -> void:
	if is_instance_valid(_tabs):
		_tabs.visible = visible_now

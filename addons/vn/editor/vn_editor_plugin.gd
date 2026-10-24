## 插件入口：只做一件事——把工具面板挂到编辑器顶部的主屏幕区。
##
## 刻意不做的事：
## - 不注册 autoload，不改项目设置
## - 不改写场景、不接管已有节点
## - 面板关掉不影响任何运行时行为
@tool
extends EditorPlugin

## 主屏幕宿主（一个 TabContainer，里面每个工具一个标签）。
## preload 而不是 class_name，是为了让插件整体拷走时不必先在项目里注册类名。
const VNHome := preload("res://addons/vn/editor/vn_home.gd")

## 主屏幕上的宿主实例。_make_visible 只切 visible，不增删节点。
var _screen: Control


## 挂面板。注意 add_child 到 MainScreen 后，宿主自己要挂 SIZE_EXPAND_FILL，
## 否则它只会得到一条按最小高度的矮带（见 flow_screen.gd 顶部注释）。
func _enter_tree() -> void:
	_screen = VNHome.new()
	_screen.name = "VN 工具"
	EditorInterface.get_editor_main_screen().add_child(_screen)
	_make_visible(false)
	print("[VN] 工具面板已注册（顶部主屏幕标签「VN 工具」）")


func _exit_tree() -> void:
	if is_instance_valid(_screen):
		_screen.queue_free()
	_screen = null


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "VN 工具"


func _get_plugin_icon() -> Texture2D:
	var editor_theme := EditorInterface.get_editor_theme()
	if editor_theme == null:
		return null
	return editor_theme.get_icon("GraphEdit", "EditorIcons")


func _make_visible(visible_now: bool) -> void:
	if is_instance_valid(_screen):
		_screen.visible = visible_now

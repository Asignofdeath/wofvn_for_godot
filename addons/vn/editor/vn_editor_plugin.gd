## 插件入口：只做一件事——把一个图编辑面板挂到编辑器顶部的主屏幕区。
##
## 刻意不做的事：
## - 不注册 autoload，不改项目设置
## - 不改写场景、不接管已有节点
## - 面板关掉不影响任何运行时行为
## - 不重造引擎编辑器：立绘摆位、UI 布局都交给 Godot 自己的 2D 视图
@tool
extends EditorPlugin

## 面板脚本。preload 而不是 class_name，是为了让插件整体拷走时不必先在项目里注册类名。
const FlowScreen := preload("res://addons/vn/editor/flow_screen.gd")

## 主屏幕上的面板实例。_make_visible 只切 visible，不增删节点。
var _screen: Control


## 挂面板。注意 add_child 到 MainScreen 后，面板自己要挂 SIZE_EXPAND_FILL，
## 否则它只会得到一条按最小高度的矮带（见 flow_screen.gd 顶部注释）。
func _enter_tree() -> void:
	_screen = FlowScreen.new()
	_screen.name = "VN 图"
	EditorInterface.get_editor_main_screen().add_child(_screen)
	_make_visible(false)
	print("[VN] 图编辑器已注册（顶部主屏幕标签「VN 图」）")


func _exit_tree() -> void:
	if is_instance_valid(_screen):
		_screen.queue_free()
	_screen = null


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "VN 图"


func _get_plugin_icon() -> Texture2D:
	var editor_theme := EditorInterface.get_editor_theme()
	if editor_theme == null:
		return null
	return editor_theme.get_icon("GraphEdit", "EditorIcons")


func _make_visible(visible_now: bool) -> void:
	if is_instance_valid(_screen):
		_screen.visible = visible_now

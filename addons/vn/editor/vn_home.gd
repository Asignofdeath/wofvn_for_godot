## 编辑器主屏幕宿主：一个 TabContainer，把各个工具各放一个标签。
##
## 一个插件只能有一个主屏幕，所以多个工具只能靠内部标签分开。
## 这里只做挂载，不做转发：两个面板互不知道对方存在。
@tool
extends TabContainer

const FlowScreen := preload("res://addons/vn/editor/flow_screen.gd")
const StageScreen := preload("res://addons/vn/editor/stage_screen.gd")


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 标签名取自子节点名，所以名字就是给人看的标题
	_add_screen("流程图", FlowScreen.new())
	_add_screen("立绘摆位", StageScreen.new())


func _add_screen(title: String, screen: Control) -> void:
	screen.name = title
	add_child(screen)

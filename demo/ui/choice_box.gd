## 最简选项框：动态生成按钮，返回选中下标。
## 契约：组 vn_choice_box，实现 present(options) -> int
extends Control

signal picked(index: int)

@onready var list: VBoxContainer = $Center/List


func _ready() -> void:
	visible = false


func present(options: Array) -> int:
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()

	for i in options.size():
		var button := Button.new()
		button.text = str(options[i])
		button.custom_minimum_size = Vector2(0, 68)
		button.add_theme_font_size_override("font_size", 28)
		button.pressed.connect(_on_pressed.bind(i))
		list.add_child(button)

	visible = true
	var index: int = await picked
	visible = false
	return index


func _on_pressed(index: int) -> void:
	for child in list.get_children():
		if child is Button:
			child.visible = false
	picked.emit(index)

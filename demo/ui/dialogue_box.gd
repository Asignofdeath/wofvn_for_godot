## 最简对话框：打字机 + 点击推进。
## 契约：组 vn_dialogue_box，实现 show_line(speaker, text) -> Signal
##   第一次点击：补完当前句
##   第二次点击：emit line_finished
extends Control

signal line_finished

const CHARS_PER_SEC := 42.0

@onready var name_label: Label = $Panel/Name
@onready var text_label: RichTextLabel = $Panel/Text
@onready var hint: Label = $Panel/Hint

var _tween: Tween
var _typing := false
var _waiting := false


func _ready() -> void:
	visible = false


func show_line(speaker: String, text: String) -> Signal:
	print("[Dialogue] %s: %s" % [speaker, text])
	visible = true
	name_label.text = speaker
	name_label.visible = speaker != ""
	text_label.text = text
	text_label.visible_ratio = 0.0
	hint.visible = false

	_waiting = true
	_typing = true

	if _tween != null and _tween.is_valid():
		_tween.kill()
	var duration := maxf(0.12, float(text.length()) / CHARS_PER_SEC)
	_tween = create_tween()
	_tween.tween_property(text_label, "visible_ratio", 1.0, duration)
	_tween.finished.connect(_on_typing_done)
	return line_finished


func _on_typing_done() -> void:
	_typing = false
	hint.visible = true


func _unhandled_input(event: InputEvent) -> void:
	if not _waiting:
		return

	var advance := event.is_action_pressed("ui_accept")
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		advance = mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
	if not advance:
		return

	get_viewport().set_input_as_handled()

	if _typing:
		if _tween != null and _tween.is_valid():
			_tween.kill()
		text_label.visible_ratio = 1.0
		_on_typing_done()
	else:
		_waiting = false
		hint.visible = false
		line_finished.emit()

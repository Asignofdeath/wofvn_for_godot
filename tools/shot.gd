## 渲染截图：起一个真实窗口，渲染一帧后存 PNG 并退出。
## 用途：让无法直接看画面的一侧能检查排版、字体、层级。
## 运行（不带 --headless）：
##   Godot_v4.7.2-stable_win64_console.exe --path . --script res://tools/shot.gd
extends SceneTree

const OUT_PATH := "res://docs/shot_stage.png"
const WAIT := 1.6


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene = load("res://demo/stage.tscn").instantiate()
	root.add_child(scene)

	await create_timer(WAIT).timeout
	await RenderingServer.frame_post_draw

	var panel: Control = scene.get_node("DialogueBox/Panel")
	print("[LAYOUT] window=%s canvas=%s panel=%s" % [root.size, root.get_visible_rect().size, panel.get_global_rect()])

	var image := root.get_texture().get_image()
	var err := image.save_png(OUT_PATH)
	print("[SHOT] %s (%s)" % [OUT_PATH, error_string(err)])
	quit(0)

## 把目录下的 .script.txt 批量编译成同名 .gd。
##
## 用法：
##   godot --headless --path . --script res://tools/compile_dsl.gd -- res://demo/story
##
## 不带参数时默认编译 res://story。目录不存在只打印提示，不算失败——
## 新建项目还没写剧本是正常状态。
extends SceneTree

const Compiler := preload("res://addons/vn/editor/dsl/dsl_compile.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var dir := "res://story"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		dir = args[0]

	if not DirAccess.dir_exists_absolute(dir):
		print("[DSL] 目录不存在：%s" % dir)
		print("[DSL] 用法：godot --headless --path . --script res://tools/compile_dsl.gd -- <目录>")
		quit(0)
		return

	var done := 0
	var failed := 0
	for name in DirAccess.get_files_at(dir):
		if not String(name).ends_with(".script.txt"):
			continue

		var src := "%s/%s" % [dir.trim_suffix("/"), name]
		var out := Compiler.out_path_for(src)
		var result := Compiler.compile_file(src, out)

		for warning in result.get("warnings", []):
			print("[WARN] %s: %s" % [name, warning])

		if result["ok"]:
			done += 1
			print("[OK]   %s → %s" % [name, out])
		else:
			failed += 1
			for error in result.get("errors", []):
				print("[ERR]  %s: %s" % [name, error])

	print("[DSL] %d 个成功 / %d 个失败" % [done, failed])
	quit(0 if failed == 0 else 1)

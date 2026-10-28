## 剧本 DSL 回归：解析 / 生成 / 语法 / 覆盖保护。
##
## 运行：
##   godot --headless --path . --script res://tools/test_dsl.gd
##
## 这个测试不启动场景：编译器是纯函数，喂字符串就能验。
## 只有「生成物能不能被 GDScript 解析」和「覆盖保护」两项碰编译器和磁盘。
extends SceneTree

## 走 preload：headless 首次运行时全局 class_name 缓存可能还没生成。
const Compiler := preload("res://addons/vn/editor/dsl/dsl_compile.gd")
const Emitter := preload("res://addons/vn/editor/dsl/dsl_emit.gd")

const SRC_SEQ := """旁白：「第一句。」

旁白：「第二句。」
"""

const SRC_PARALLEL := """[背景：教室 — 淡入：0.8]
[立绘：凛 @中 — 表情：平静 — 淡入：0.4]
[停顿1.5s]
"""

const SRC_CHOICE := """[选择项：怎么回答？
- 我在等你。
  凛：「……笨蛋。」
- 只是忘了时间。
]
"""

const SRC_IF := """[判断：好感 >= 50
凛：「受欢迎呢。」
- 否则判断：好感 >= 20
凛：「还行。」
- 否则
凛：「再努力吧。」
]
"""

const SRC_NESTED := """[选择项：去哪？
- 学校
  [判断：好感 >= 10
  凛：「一起走吧。」
  - 否则
  凛：「先走了。」
  ]
- 回家
]
"""

const SRC_JUMP := """[参数：flag = true]

[跳转章节：第二章]
"""

const SRC_SCENE := """═══════════════════
场景：教室
时间：下午
═══════════════════

旁白：「一。」
"""

const TMP_SRC := "res://tools/.dsl_guard.script.txt"
const TMP_OUT := "res://tools/.dsl_guard.gd"

var _pass := 0
var _fail := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_sequence()
	_test_parallel()
	_test_say_with_action()
	_test_jump_with_action()
	_test_multiple_blockers()
	_test_choice()
	_test_if()
	_test_nested()
	_test_jump_and_scene()
	_test_errors()
	_test_snippets()
	_test_syntax()
	_test_doc_example()
	_test_guard()

	print("[DSL] %d 通过 / %d 失败" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)


## ---- 正常路径 ----

func _test_sequence() -> void:
	var r := Compiler.compile_text(SRC_SEQ, "res://x.script.txt")
	_check(r["ok"], "顺序：编译通过", _errors(r))
	var code := _code(r)
	_has(code, "await VNKit.say(self, \"旁白\", \"第一句。\")", "顺序：第一句")
	_has(code, "await VNKit.say(self, \"旁白\", \"第二句。\")", "顺序：第二句")
	_has(code, "finished.emit()", "顺序：收尾发 finished")


func _test_parallel() -> void:
	var r := Compiler.compile_text(SRC_PARALLEL, "res://x.script.txt")
	_check(r["ok"], "拍内动作：编译通过", _errors(r))
	var code := _code(r)
	# 背景/立绘是非阻塞：裸调用，不带 var、不带 await（对齐 engine.js 不等 bg/sprite）
	_has(code, "\tVNKit.bg(self, \"教室\", 0.8)", "拍内动作：背景裸调用")
	_has(code, "\tVNKit.sprite(self, \"凛\", \"平静\", \"center\", 0.4)", "拍内动作：立绘裸调用")
	_check(not code.contains("var _beat"), "拍内动作：非阻塞不再占用临时变量")
	# 停顿是阻塞类（engine.js BLOCKING 里的 wait）：排在最后，被 await
	_has(code, "\tawait get_tree().create_timer(1.5).timeout", "拍内动作：停顿被等待")
	_check(not code.contains("VNKit.join"), "拍内动作：单阻塞不需要 join")


## 台词和动作同拍——用户最容易写出来的形态，Web 版完全合法。
## 生成顺序必须是非阻塞在前、阻塞（台词）收尾，否则台词后面的
## 背景要等玩家点击后才启动。这里钉死这个顺序。
func _test_say_with_action() -> void:
	var r := Compiler.compile_text("[背景：教室]\n凛：「一。」\n", "res://x.script.txt")
	_check(r["ok"], "台词+动作同拍：编译通过", _errors(r))
	var code := _code(r)
	var bg_at := code.find("VNKit.bg(self, \"教室\", 0.4)")
	var say_at := code.find("await VNKit.say(self, \"凛\", \"一。\")")
	_check(bg_at >= 0 and say_at >= 0 and bg_at < say_at,
		"台词+动作同拍：动作在前、台词收尾", code)
	_check(not code.contains("await VNKit.bg"), "台词+动作同拍：背景不被等待")


## 跳转与动作同拍（engine.js:851 不把 jumpChapter 收进 blockers）：
## 动作启动后立即收尾，不再等待任何阻塞动作。
func _test_jump_with_action() -> void:
	var r := Compiler.compile_text("[背景：教室]\n[跳转章节：第二章]\n", "res://x.script.txt")
	_check(r["ok"], "跳转+动作同拍：编译通过", _errors(r))
	var code := _code(r)
	var bg_at := code.find("VNKit.bg(self, \"教室\", 0.4)")
	var fin_at := code.find("finished.emit()")
	_check(bg_at >= 0 and fin_at >= 0 and bg_at < fin_at, "跳转+动作同拍：动作先启动再收尾", code)
	_check(not code.contains("await"), "跳转+动作同拍：同拍不等待任何动作")


## 多个阻塞动作（台词 + 停顿）同拍：全部启动、join 等齐。
func _test_multiple_blockers() -> void:
	var r := Compiler.compile_text("[停顿1.5s]\n凛：「一。」\n", "res://x.script.txt")
	_check(r["ok"], "双阻塞：编译通过", _errors(r))
	var code := _code(r)
	_has(code, "var _wait0 := get_tree().create_timer(1.5).timeout", "双阻塞：停顿启动")
	_has(code, "var _wait1 := VNKit.say(self, \"凛\", \"一。\")", "双阻塞：台词启动")
	_has(code, "await VNKit.join(self, [_wait0, _wait1])", "双阻塞：合流等待")


func _test_choice() -> void:
	var r := Compiler.compile_text(SRC_CHOICE, "res://x.script.txt")
	_check(r["ok"], "选择项：编译通过", _errors(r))
	var code := _code(r)
	_has(code, "var _picked0 := await VNKit.choice(self, [\"我在等你。\", \"只是忘了时间。\"])",
		"选择项：选项表")
	_has(code, "match _picked0:", "选择项：生成 match")
	_has(code, "await VNKit.say(self, \"凛\", \"……笨蛋。\")", "选择项：第一个分支")
	_has(code, "pass", "选择项：空分支补 pass")


func _test_if() -> void:
	var r := Compiler.compile_text(SRC_IF, "res://x.script.txt")
	_check(r["ok"], "判断：编译通过", _errors(r))
	var code := _code(r)
	_has(code, "if VNKit.get_param(self, \"好感\", 0) >= 50:", "判断：if 带 fallback")
	_has(code, "elif VNKit.get_param(self, \"好感\", 0) >= 20:", "判断：elif")
	_has(code, "else:", "判断：else")


func _test_nested() -> void:
	var r := Compiler.compile_text(SRC_NESTED, "res://x.script.txt")
	_check(r["ok"], "嵌套：编译通过", _errors(r))
	var code := _code(r)
	_has(code, "if VNKit.get_param(self, \"好感\", 0) >= 10:", "嵌套：选项里的判断")


func _test_jump_and_scene() -> void:
	var r := Compiler.compile_text(SRC_JUMP, "res://x.script.txt")
	_check(r["ok"], "跳转：编译通过", _errors(r))
	var code := _code(r)
	_has(code, "VNKit.set_param(self, \"flag\", true)", "参数：= 生成 set_param")
	_has(code, "finished.emit()\n\treturn", "跳转：收尾并返回")
	_check(_has_warning(r, "导图决定"), "跳转：提示由图接管")

	var s := Compiler.compile_text(SRC_SCENE, "res://x.script.txt")
	_check(s["ok"], "场景块：不报错", _errors(s))
	_check(_has_warning(s, "场景块已忽略"), "场景块：给 warning 而不是静默丢")


## ---- 错误路径 ----

func _test_errors() -> void:
	var a := Compiler.compile_text("凛：「一。」\n凛：「二。」\n", "x")
	_check(not a["ok"], "错误：同一拍两句台词")
	_has(_errors(a), "同一拍里有两句台词", "错误：双台词文案")

	var c := Compiler.compile_text("[立绘消失：凛]\n", "x")
	_check(not c["ok"], "错误：未知指令")
	_has(_errors(c), "未知指令", "错误：未知指令文案")

	var d := Compiler.compile_text("[选择项：x\n- a\n", "x")
	_check(not d["ok"], "错误：选择项未闭合")
	_has(_errors(d), "没有用单独的 ] 收尾", "错误：未闭合文案")

	var e := Compiler.compile_text("[判断：a >= 1 且 b <= 2\n凛：「x」\n]\n", "x")
	_check(not e["ok"], "错误：复合条件")
	_has(_errors(e), "暂不支持复合条件", "错误：复合条件文案")

	var f := Compiler.compile_text("[参数：好感]\n", "x")
	_check(not f["ok"], "错误：参数格式")
	_has(_errors(f), "参数要写成", "错误：参数格式文案")

	var g := Compiler.compile_text("这一行不是台词也不是指令\n", "x")
	_check(not g["ok"], "错误：无法识别的行")
	_has(_errors(g), "无法识别的行", "错误：无法识别文案")


## ---- 面板按钮墙的片段表 ----

## 每个按钮插出来的写法，编译器都必须认。
## 这条测试存在的理由：按钮墙是 UI、指令表是编译器，两者一旦分叉，
## 用户会遇到「面板上有这个按钮，插进去却报未知指令」——这种坑只能在测试里钉死。
func _test_snippets() -> void:
	_check(Emitter.SNIPPETS.size() >= 6, "片段表：条目数", str(Emitter.SNIPPETS.size()))
	for s in Emitter.SNIPPETS:
		var label := String(s["label"])
		_check(String(s["insert"]).contains("|"), "片段表：%s 有光标标记" % label)
		var sample := String(s["sample"])
		_check(sample != "", "片段表：%s 有 sample" % label)
		var r := Compiler.compile_text(sample + "\n", "res://x.script.txt")
		_check(r["ok"], "片段表：%s 的 sample 能编过" % label, _errors(r))

	var names := " / ".join(Emitter.command_names())
	_has(names, "背景", "片段表：错误文案含背景")
	_has(names, "跳转章节", "片段表：错误文案含跳转章节")
	# 台词不是方括号指令，不该出现在关键词列表里
	_check(not names.contains("台词"), "片段表：关键词列表不含台词")


## ---- 生成物能不能被 Godot 解析 ----

func _test_syntax() -> void:
	for pair in [
		["顺序", SRC_SEQ],
		["并行", SRC_PARALLEL],
		["选择项", SRC_CHOICE],
		["判断", SRC_IF],
		["嵌套", SRC_NESTED],
	]:
		var r := Compiler.compile_text(pair[1], "res://x.script.txt")
		if not r["ok"]:
			_check(false, "语法：%s 编译失败" % pair[0], _errors(r))
			continue
		_check(_parses(_code(r)), "语法：%s 生成物可被解析" % pair[0])


## ---- 覆盖保护 ----

func _test_guard() -> void:
	_remove(TMP_SRC)
	_remove(TMP_OUT)

	_write(TMP_SRC, "旁白：「一。」\n")
	var r1 := Compiler.compile_file(TMP_SRC, TMP_OUT)
	_check(r1["ok"], "覆盖保护：首次生成", _errors(r1))

	var r2 := Compiler.compile_file(TMP_SRC, TMP_OUT)
	_check(r2["ok"], "覆盖保护：重复生成", _errors(r2))

	# 模拟手改：往生成物末尾追加一行。
	var f := FileAccess.open(TMP_OUT, FileAccess.READ_WRITE)
	if f == null:
		_check(false, "覆盖保护：打不开产物")
	else:
		f.seek_end()
		f.store_string("\n# tamper\n")
		f.close()

	var r3 := Compiler.compile_file(TMP_SRC, TMP_OUT)
	_check(not r3["ok"], "覆盖保护：手改后拒绝覆盖")
	_has(_errors(r3), "产物被手改过", "覆盖保护：拒绝文案")

	var r4 := Compiler.compile_file(TMP_SRC, TMP_OUT, true)
	_check(r4["ok"], "覆盖保护：force 放行", _errors(r4))

	# 不是生成文件时绝不覆盖。
	_write(TMP_OUT, "# 手写剧本\n")
	var r5 := Compiler.compile_file(TMP_SRC, TMP_OUT)
	_check(not r5["ok"], "覆盖保护：拒绝覆盖手写文件")
	_has(_errors(r5), "不是生成文件", "覆盖保护：手写文件文案")

	_remove(TMP_SRC)
	_remove(TMP_OUT)


## ---- 文档 §4 示例 == 真实产物 ----
##
## docs/DSL.md 的「生成示例」是全文唯一没有测试兜底的产物示例
## （SNIPPETS 有 sample 编译兜底，join 有 test_join 兜底）。
## 这里直接解析文档：取 §4 的输入块编译，与 gdscript 代码块比对。
## 空行不比（排版自由）；有没有 await、谁排在前这类语义必须逐字一致——
## 示例错了会误导后来人把非阻塞动作当阻塞。
func _test_doc_example() -> void:
	var txt := FileAccess.get_file_as_string("res://docs/DSL.md")
	_check(txt != "", "文档示例：读得到 docs/DSL.md")
	if txt == "":
		return

	var head := txt.find("## 4. 生成示例")
	_check(head >= 0, "文档示例：找到 §4 标题")
	if head < 0:
		return

	var blocks := _fenced_blocks(txt.substr(head))
	_check(blocks.size() >= 2, "文档示例：§4 有输入与输出两个围栏")
	if blocks.size() < 2:
		return

	var r := Compiler.compile_text(String(blocks[0]), "res://docs/DSL.md")
	_check(r["ok"], "文档示例：输入块能编译", _errors(r))
	if not r["ok"]:
		return

	var code := _code(r)
	var play_at := code.find("func play() -> void:")
	_check(play_at >= 0, "文档示例：产物里有 play()")
	if play_at < 0:
		return

	var got := _squash(code.substr(play_at))
	var want := _squash(String(blocks[1]))
	_check(got == want, "文档示例：§4 代码块 == 真实产物", _first_diff(want, got))


## 提取 markdown 围栏块，返回 [块0, 块1, …]，不含围栏行。
func _fenced_blocks(section: String) -> Array:
	var blocks: Array = []
	var current: Array = []
	var inside := false
	for line in section.split("\n"):
		if String(line).strip_edges().begins_with("```"):
			if inside:
				blocks.append("\n".join(current))
				current = []
			inside = not inside
			continue
		if inside:
			current.append(line)
	return blocks


## 去空行、去行尾空白后逐行拼接：排版自由，语义逐字。
func _squash(text: String) -> String:
	var kept: Array = []
	for line in text.split("\n"):
		var s := String(line).rstrip(" \t")
		if s == "":
			continue
		kept.append(s)
	return "\n".join(kept)


## 两份文本第一处不同的行，给失败信息用。
func _first_diff(want: String, got: String) -> String:
	var w := want.split("\n")
	var g := got.split("\n")
	for i in range(maxi(w.size(), g.size())):
		var a := String(w[i]) if i < w.size() else "<缺>"
		var b := String(g[i]) if i < g.size() else "<缺>"
		if a != b:
			return "第 %d 行：文档=%s  产物=%s" % [i + 1, a, b]
	return ""


## ---- 小工具 ----

func _code(r: Dictionary) -> String:
	return String(r.get("code", ""))


func _errors(r: Dictionary) -> String:
	var list: Array = r.get("errors", [])
	return " / ".join(list)


func _has_warning(r: Dictionary, needle: String) -> bool:
	for msg in r.get("warnings", []):
		if String(msg).contains(needle):
			return true
	return false


func _parses(code: String) -> bool:
	var script := GDScript.new()
	script.source_code = code
	return script.reload() == OK


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _check(cond: bool, name: String, detail := "") -> void:
	if cond:
		_pass += 1
		print("[PASS] %s" % name)
	else:
		_fail += 1
		print("[FAIL] %s%s" % [name, "" if detail == "" else "  :: " + detail])


func _has(text: String, needle: String, name: String) -> void:
	_check(text.contains(needle), name, "没找到：%s" % needle)

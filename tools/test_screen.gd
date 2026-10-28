## 剧本面板回归：插入模板、光标落点、默认值选中。
##
## 运行：
##   godot --headless --path . --script res://tools/test_screen.gd
##
## 只测「文本 + 光标 + 选区」这类纯逻辑，不测画出来的样子——
## 后者 headless 测不了（size 全 0、字体不加载），只能靠真机截图。
## 但插入模板是这一层唯一会写坏正文的地方，必须钉住：
## 光标没落到参数位，用户就会把 `[背景：]` 和上一句台词挤进同一拍，那是个编译错误。
extends SceneTree

const Screen := preload("res://addons/vn/editor/dsl/dsl_screen.gd")
const Emitter := preload("res://addons/vn/editor/dsl/dsl_emit.gd")
const Compiler := preload("res://addons/vn/editor/dsl/dsl_compile.gd")

const TMP_SRC := "res://tools/.screen_dirty.script.txt"

var _pass := 0
var _fail := 0
var _screen: Control
var _code: CodeEdit


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_screen = Screen.new()
	root.add_child(_screen)
	_code = _screen.get("_code")
	if _code == null:
		print("[SCREEN] 面板没建出 CodeEdit")
		quit(1)
		return

	_test_empty_line()
	_test_after_text()
	_test_dialogue()
	_test_choice()
	_test_if()
	_test_wait_default_selected()
	_test_no_marker_left()
	_test_inserted_text_compiles()
	_test_dirty_flag()

	print("[SCREEN] %d 通过 / %d 失败" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)


## ---- 用例 ----

## 空行上插入：不额外加换行，光标落在 `：` 与 `]` 之间
func _test_empty_line() -> void:
	_setup("", 0, 0)
	_insert("背景")
	_eq(_code.text, "[背景：]", "空行插入背景：模板原样")
	_eq(_caret(), Vector2i(0, 4), "空行插入背景：光标在参数位")


## 有内容的行上插入：台词后默认空一行（新台词同拍会互相覆盖），普通动作后留在同一拍
func _test_after_text() -> void:
	_setup("凛：「你还没走？」", 0, 0)
	_insert("背景")
	_eq(_code.text, "凛：「你还没走？」\n\n[背景：]", "台词后插入：另起一拍")
	_eq(_caret(), Vector2i(2, 4), "台词后插入：光标在参数位")
	_code.insert_text_at_caret("教室")
	_eq(_code.text, "凛：「你还没走？」\n\n[背景：教室]", "台词后插入：接着打字补上参数")
	_check(Compiler.compile_text(_code.text + "\n", "x")["ok"], "台词后插入：补完参数能编译",
		_errors(Compiler.compile_text(_code.text + "\n", "x")))

	# 动作行后面插入留在同一拍：背景 + 立绘一起启动，是典型写法
	_setup("[背景：教室]", 0, 0)
	_insert("立绘")
	_eq(_code.text, "[背景：教室]\n[立绘： @中]", "动作后插入：留在同一拍")
	var r := Compiler.compile_text(_code.text.replace("[立绘： @中]", "[立绘：凛 @中]") + "\n", "x")
	_check(r["ok"], "动作后插入：补完参数能编译", _errors(r))
	_check(not String(r.get("code", "")).contains("await VNKit.sprite"),
		"动作后插入：立绘是非阻塞，裸调用不 await")


func _test_dialogue() -> void:
	_setup("", 0, 0)
	_insert("台词")
	_eq(_code.text, "角色：「」", "台词：模板原样")
	_eq(_caret(), Vector2i(0, 4), "台词：光标在两个引号之间")


## 多行模板的落点在第几行第几列，最容易算错
func _test_choice() -> void:
	_setup("", 0, 0)
	_insert("选择项")
	_eq(_code.text, "[选择项：怎么回答？\n- 选项一\n- 选项二\n]", "选择项：模板原样")
	_eq(_code.get_line(_caret().x), "- 选项一", "选择项：光标在第一个选项那行")
	_eq(_caret().y, 5, "选择项：光标在「选项一」末尾")


func _test_if() -> void:
	_setup("", 0, 0)
	_insert("判断")
	_eq(_code.get_line(_caret().x), "", "判断：光标落在正文空行")
	_eq(_caret().y, 0, "判断：光标在行首")


## `[停顿|<1.5s>]`：默认值要被选中，否则用户打一个 2 会变成 `[停顿21.5s]`
func _test_wait_default_selected() -> void:
	_setup("", 0, 0)
	_insert("停顿")
	_eq(_code.text, "[停顿1.5s]", "停顿：模板原样")
	_check(_code.has_selection(), "停顿：默认值处于选中状态")
	_eq(_code.get_selected_text(), "1.5s", "停顿：选中的是默认值")
	# 模拟用户直接输入，默认值应当被顶掉
	_code.insert_text_at_caret("2s")
	_eq(_code.text, "[停顿2s]", "停顿：输入顶掉默认值")
	var r := Compiler.compile_text(_code.text, "x")
	_check(r["ok"], "停顿：改完仍能编译", _errors(r))


## 模板标记一个都不能漏进正文。
## 只查 `|`：`<` `>` 是判据运算符的合法字符（`好感 >= 50`），不能拿来当残留标记
func _test_no_marker_left() -> void:
	for s in Emitter.SNIPPETS:
		_setup("", 0, 0)
		_insert(String(s["label"]))
		_check(_code.text.find("|") < 0, "片段 %s：落点标记没漏进正文" % s["label"], _code.text)


## 插入后补上参数就应当能编译（模板不是给人看的装饰）
func _test_inserted_text_compiles() -> void:
	var args := {"背景": "教室", "立绘": "凛", "参数": "affection"}
	for label in ["背景", "立绘", "参数", "停顿"]:
		_setup("", 0, 0)
		_insert(label)
		if args.has(label):
			_code.insert_text_at_caret(String(args[label]))
		var r := Compiler.compile_text(_code.text + "\n", "x")
		_check(r["ok"], "片段 %s：补参数后能编译" % label, _errors(r))


## 改一下就应该是脏的，保存后不脏。这是「零草稿层」唯一能自动验的部分，
## 也顺带钉住「点按钮插模板不走 text_changed」这个坑
func _test_dirty_flag() -> void:
	_screen.set("_src", TMP_SRC)
	_setup("", 0, 0)
	_screen.set("_dirty", false)
	_insert("背景")
	_check(bool(_screen.get("_dirty")), "脏标记：点按钮插入后为脏")
	_screen.call("_save")
	_check(not bool(_screen.get("_dirty")), "脏标记：保存后不脏")
	_eq(FileAccess.get_file_as_string(TMP_SRC), "[背景：]", "保存：文件内容就是正文")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_SRC))


## ---- 工具 ----

func _setup(text: String, line: int, col: int) -> void:
	_code.deselect()
	_code.text = text
	_code.set_caret_line(line)
	_code.set_caret_column(col)


func _insert(label: String) -> void:
	for s in Emitter.SNIPPETS:
		if String(s["label"]) == label:
			_screen.call("_insert_snippet", s)
			return
	_fail += 1
	print("  ✗ 指令表里没有「%s」" % label)


func _caret() -> Vector2i:
	return Vector2i(_code.get_caret_line(), _code.get_caret_column())


func _check(ok: bool, what: String, detail := "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("  ✗ %s  %s" % [what, detail])


func _eq(actual: Variant, want: Variant, what: String) -> void:
	_check(actual == want, what, "得到 %s，期望 %s" % [actual, want])


func _errors(r: Dictionary) -> String:
	return "" if r["ok"] else " / ".join(r["errors"])


## 生成的 GDScript 里有没有这句话
func _has(r: Dictionary, needle: String, what: String) -> void:
	var code := String(r.get("code", ""))
	_check(code.find(needle) >= 0, what, "生成物：\n%s" % code)

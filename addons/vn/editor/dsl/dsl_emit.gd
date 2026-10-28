## 剧本 DSL 的代码生成：节点树 → GDScript 文本。
##
## 纯函数，不碰文件、不碰场景树、不知道自己在编辑器里还是命令行里。
## 生成目标只有一件事：能直接 F5 跑的普通协程剧本（extends Node + play + finished），
## 所以产物可以脱离这个编译器存在，也可以被手写剧本替换。
##
## 动作只认 VNKit 现有的五个：say / bg / sprite / choice / param。
## 停顿是引擎原生（create_timer），不经插件，所以不算第六个动作。
class_name VNDslEmitter
extends RefCounted

const TAB := "\t"


## ---- 指令片段表 ----
##
## 面板的按钮墙、补全候选、错误文案里那份「当前支持：…」三处都从这里取。
## 目的是让「UI 里有个按钮，但编译器不认」这种事在结构上不可能发生。
##
## 加一条指令 = 这里加一行 + 下面 _command 的 match 加一个分支 + sample 能编过。
##
## 字段：
##   label   按钮上的字
##   kw      方括号里的关键词（台词没有方括号，留空）；也是错误文案的来源
##   cmd     true = 由 _command 解释的单行指令；false = 台词或结构块（parser 管）
##   insert  插进正文的模板。`|` 是光标落点，插入时剥掉；其余字符原样进文件
##           `|<…>` 额外表示「这段是待替换的默认值」：插入后连同 `<>` 一起选中，
##           用户直接输入就顶掉（否则 `[停顿|1.5s]` 里打一个 2 会变成 `[停顿21.5s]`）
##   sample  一小段**合法**写法，tools/test_dsl.gd 会逐条编译它，保证按钮插得出东西
##   hint    按钮 tooltip
const SNIPPETS := [
	{
		"label": "台词",
		"kw": "",
		"cmd": false,
		"group": "台词",
		"insert": "角色：「|」",
		"sample": "凛：「你还没走？」",
		"hint": "角色：「内容」。自己等点击，可以和动作写在一拍",
	},
	{
		"label": "背景",
		"kw": "背景",
		"cmd": true,
		"group": "画面",
		"insert": "[背景：|]",
		"sample": "[背景：教室 — 淡入：0.8]",
		"hint": "背景：名称 — 淡入：秒（默认 0.4）",
	},
	{
		"label": "立绘",
		"kw": "立绘",
		"cmd": true,
		"group": "画面",
		"insert": "[立绘：| @中]",
		"sample": "[立绘：凛 @中 — 表情：平静 — 淡入：0.4]",
		"hint": "立绘：角色 @左/中/右 — 表情：名字 — 淡入：秒",
	},
	{
		"label": "参数",
		"kw": "参数",
		"cmd": true,
		"group": "画面",
		"insert": "[参数：| +1]",
		"sample": "[参数：affection +5]",
		"hint": "参数：名字 +5 / 名字 = 10。同步执行，不占一拍",
	},
	{
		"label": "停顿",
		"kw": "停顿",
		"cmd": true,
		"group": "画面",
		"insert": "[停顿|<1.5s>]",
		"sample": "[停顿1.5s]",
		"hint": "停顿1.5s：走引擎计时器，不经插件",
	},
	{
		"label": "选择项",
		"kw": "选择项",
		"cmd": false,
		"group": "结构",
		"insert": "[选择项：怎么回答？\n- 选项一|\n- 选项二\n]",
		"sample": "[选择项：怎么回答？\n- 甲\n- 乙\n]",
		"hint": "至少两个选项，正文直接写在选项下面",
	},
	{
		"label": "判断",
		"kw": "判断",
		"cmd": false,
		"group": "结构",
		"insert": "[判断：好感 >= 50\n|\n- 否则\n\n]",
		"sample": "[判断：好感 >= 50\n凛：「好。」\n- 否则\n凛：「差。」\n]",
		"hint": "条件只支持 变量 运算符 值，没有且/或",
	},
	{
		"label": "跳转",
		"kw": "跳转章节",
		"cmd": true,
		"group": "流程",
		"insert": "[跳转章节：|]",
		"sample": "[跳转章节：第二章]",
		"hint": "去哪一章由导图决定，剧本只在这里收尾",
	},
]


## `_command` 认识的关键词，按表里的顺序拼。错误文案用它，不再手写一份。
static func command_names() -> Array:
	var out: Array = []
	for s in SNIPPETS:
		if bool(s["cmd"]):
			out.append(String(s["kw"]))
	return out


## 面板按分组排按钮：[[组名, [条目…]], …]，顺序就是表里的顺序。
static func snippet_groups() -> Array:
	var out: Array = []
	for s in SNIPPETS:
		var g := String(s["group"])
		if out.is_empty() or String(out[out.size() - 1][0]) != g:
			var bucket: Array = []
			out.append([g, bucket])
		out[out.size() - 1][1].append(s)
	return out


## roots 来自 VNDslParser.parse()["roots"]。
## 返回 {ok, errors, warnings, lines: Array[String]}，lines 从 extends Node 开始。
static func emit(roots: Array, _meta: Dictionary = {}) -> Dictionary:
	var ctx := {
		"errors": [],
		"warnings": [],
		"beat": 0,
		"choice": 0,
		"wrote": false,
	}

	var body: Array = []
	_emit_nodes(roots, 1, body, ctx)

	if body.is_empty():
		body.append(TAB + "pass")
	else:
		body.append("")
	body.append(TAB + "finished.emit()")

	var lines: Array = [
		"extends Node",
		"",
		"signal finished",
		"",
		"",
		"func play() -> void:",
	]
	lines.append_array(body)

	return {
		"ok": ctx["errors"].is_empty(),
		"errors": ctx["errors"],
		"warnings": ctx["warnings"],
		"lines": lines,
	}


## ---- 节点 ----

static func _emit_nodes(nodes: Array, indent: int, lines: Array, ctx: Dictionary) -> void:
	for node in nodes:
		# 顶层节点之间留空行，生成物才像人写的。块体内部不插，否则
		# `0:` 后面先来一个空行，match 分支会散掉。
		if indent == 1 and bool(ctx["wrote"]):
			if not lines.is_empty() and String(lines[lines.size() - 1]) != "":
				lines.append("")

		match String(node.get("kind", "")):
			"beat":
				_emit_beat(node, indent, lines, ctx)
			"choice":
				_emit_choice(node, indent, lines, ctx)
			"if":
				_emit_if(node, indent, lines, ctx)
			_:
				ctx["errors"].append("第 %d 行：内部错误，未知节点" % int(node.get("line", 0)))
		ctx["wrote"] = true


## 一拍 = 玩家的一次点击。
##
## 语义 oracle：Web 版运行时 GameProject/_template/js/engine.js 的 _runStep（:456）
## 与 BLOCKING 集合（:4）。同拍所有动作**立即启动**，但只有阻塞类会被等待：
##   阻塞类（engine.js 的 BLOCKING）：台词（等点击）、停顿（等计时器）。
##   非阻塞：背景 / 立绘。启动后不等，淡入继续放，剧情照走。
##
## 生成规则：
##   - 非阻塞 + 参数：裸调用 / 直接写，按书写顺序排在前
##   - 阻塞动作：启动后 await（多个则 join），排最后。
##     必须最后：await 挂起后它后面的行都不会执行，
##     若非阻塞动作排在 await 之后，就要等玩家点击后才启动——顺序就反了
##   - 跳转：finished.emit + return 收尾。与动作同拍时动作启动后立即跳，
##     对齐 engine.js:851（jumpChapter 不进 blockers，启动了的动作不被等）
##   - 同拍两句台词：报错。两个对话框同时弹会互相覆盖，前一句永远看不到。
##     Web 版对此静默覆盖，这是唯一一处有意收紧的差异
static func _emit_beat(beat: Dictionary, indent: int, lines: Array, ctx: Dictionary) -> void:
	var items: Array = beat["items"]
	var immediate: Array = []   ## 立即生效的行（非阻塞动作裸调用 + 参数语句）
	var blockers: Array = []    ## 阻塞动作 {line, expr}：台词 / 停顿
	var says := 0
	var first_say_line := 0
	var jump := false

	for item in items:
		if String(item.get("kind", "")) == "say":
			says += 1
			if says == 1:
				first_say_line = int(item.get("line", 0))
			blockers.append({
				"line": int(item.get("line", 0)),
				"expr": "VNKit.say(self, %s, %s)" % [
					_q(String(item.get("speaker", ""))),
					_q(String(item.get("text", ""))),
				],
			})
			continue
		var res := _command(String(item.get("raw", "")), int(item.get("line", 0)), ctx)
		if res.is_empty():
			continue
		match String(res["kind"]):
			"signal":
				immediate.append(String(res["expr"]))
			"wait":
				blockers.append({"line": int(res["line"]), "expr": String(res["expr"])})
			"sync":
				immediate.append(String(res["stmt"]))
			"jump":
				jump = true

	if says > 1:
		ctx["errors"].append(
			"第 %d 行：同一拍里有两句台词。两个对话框会同时弹并互相覆盖，前一句永远看不到——用空行分开" % first_say_line
		)
		return

	for stmt in immediate:
		lines.append(_tab(indent) + stmt)

	# 跳转：动作已经启动了，但不再等它们（engine.js 的行为），直接收尾。
	if jump:
		lines.append(_tab(indent) + "finished.emit()")
		lines.append(_tab(indent) + "return")
		return

	if blockers.is_empty():
		return
	if blockers.size() == 1:
		lines.append("%sawait %s" % [_tab(indent), String(blockers[0]["expr"])])
		return

	# 多个阻塞动作：全部启动，一次等齐（对应 engine.js 的 Promise.all(blockers)）。
	var names: Array = []
	for b in blockers:
		var name := "_wait%d" % int(ctx["beat"])
		ctx["beat"] = int(ctx["beat"]) + 1
		lines.append("%svar %s := %s" % [_tab(indent), name, String(b["expr"])])
		names.append(name)
	lines.append("%sawait VNKit.join(self, [%s])" % [_tab(indent), ", ".join(names)])


static func _emit_choice(node: Dictionary, indent: int, lines: Array, ctx: Dictionary) -> void:
	var var_name := "_picked%d" % int(ctx["choice"])
	ctx["choice"] = int(ctx["choice"]) + 1

	var options: Array = node["options"]
	var labels: Array = []
	for opt in options:
		labels.append(_q(String(opt["label"])))

	lines.append("%svar %s := await VNKit.choice(self, [%s])" % [
		_tab(indent), var_name, ", ".join(labels)
	])
	lines.append("%smatch %s:" % [_tab(indent), var_name])

	for idx in options.size():
		var opt: Dictionary = options[idx]
		lines.append("%s%d:" % [_tab(indent + 1), idx])
		var body: Array = opt["body"]
		if body.is_empty():
			lines.append(_tab(indent + 2) + "pass")
		else:
			_emit_nodes(body, indent + 2, lines, ctx)


static func _emit_if(node: Dictionary, indent: int, lines: Array, ctx: Dictionary) -> void:
	var branches: Array = node["branches"]
	for branch in branches:
		var kind := String(branch["kind"])
		var keyword := "if"
		if kind == "elif":
			keyword = "elif"
		elif kind == "else":
			keyword = "else"

		if keyword == "else":
			lines.append("%s%s:" % [_tab(indent), keyword])
		else:
			var cond := _condition(String(branch["expr"]), int(branch["line"]), ctx)
			lines.append("%s%s %s:" % [_tab(indent), keyword, cond])

		var body: Array = branch["body"]
		if body.is_empty():
			lines.append(_tab(indent + 1) + "pass")
		else:
			_emit_nodes(body, indent + 1, lines, ctx)


## ---- 单条指令 ----

static func _command(raw: String, line: int, ctx: Dictionary) -> Dictionary:
	if raw == "":
		ctx["errors"].append("第 %d 行：[] 里是空的" % line)
		return {}

	# 停顿没有冒号：[停顿1.5s]，和 Web 版一致。它是阻塞类（engine.js BLOCKING 里的 wait）。
	var wait_re := RegEx.new()
	wait_re.compile("^停顿\\s*([0-9]*\\.?[0-9]+)\\s*s$")
	var wait_match := wait_re.search(raw)
	if wait_match != null:
		return {
			"kind": "wait",
			"line": line,
			"expr": "get_tree().create_timer(%s).timeout" % _num(wait_match.get_string(1).to_float()),
		}

	var colon := raw.find("：")
	if colon < 0:
		ctx["errors"].append("第 %d 行：指令缺少冒号（停顿除外）：[%s]" % [line, raw])
		return {}

	var name := raw.substr(0, colon).strip_edges()
	var args := raw.substr(colon + 1).strip_edges()

	match name:
		"背景":
			return _bg(args, line, ctx)
		"立绘":
			return _sprite(args, line, ctx)
		"参数":
			return _param(args, line, ctx)
		"跳转章节":
			if args == "":
				ctx["errors"].append("第 %d 行：跳转章节缺少章节名" % line)
				return {}
			ctx["warnings"].append(
				"第 %d 行：跳转到「%s」由导图决定，剧本只负责在这里收尾" % [line, args]
			)
			return {"kind": "jump", "line": line}
		_:
			ctx["errors"].append(
				"第 %d 行：未知指令 `%s`。当前支持：%s"
				% [line, name, " / ".join(command_names())]
			)
			return {}


static func _bg(args: String, line: int, ctx: Dictionary) -> Dictionary:
	var parts := args.split("—")
	var id := parts[0].strip_edges() if parts.size() > 0 else ""
	if id == "":
		ctx["errors"].append("第 %d 行：背景缺少名称" % line)
		return {}

	var fade := 0.4
	for i in range(1, parts.size()):
		var p := parts[i].strip_edges()
		if p == "":
			continue
		if p.begins_with("淡入："):
			fade = _float_arg(p.trim_prefix("淡入："), 0.4, line, "淡入", ctx)
		else:
			ctx["errors"].append("第 %d 行：背景不认识的参数 `%s`（只支持 淡入：秒）" % [line, p])

	return {
		"kind": "signal",
		"line": line,
		"expr": "VNKit.bg(self, %s, %s)" % [_q(id), _num(fade)],
	}


static func _sprite(args: String, line: int, ctx: Dictionary) -> Dictionary:
	var parts := args.split("—")
	var head := parts[0].strip_edges() if parts.size() > 0 else ""

	var who := head
	var slot := "center"
	var at := head.rfind("@")
	if at >= 0:
		who = head.substr(0, at).strip_edges()
		slot = _slot(head.substr(at + 1).strip_edges())
	if who == "":
		ctx["errors"].append("第 %d 行：立绘缺少角色名" % line)
		return {}

	var pose := "default"
	var fade := 0.2
	for i in range(1, parts.size()):
		var p := parts[i].strip_edges()
		if p == "":
			continue
		if p.begins_with("表情："):
			pose = p.trim_prefix("表情：").strip_edges()
			if pose == "":
				pose = "default"
		elif p.begins_with("淡入："):
			fade = _float_arg(p.trim_prefix("淡入："), 0.2, line, "淡入", ctx)
		else:
			ctx["errors"].append("第 %d 行：立绘不认识的参数 `%s`（只支持 表情：/ 淡入：）" % [line, p])

	return {
		"kind": "signal",
		"line": line,
		"expr": "VNKit.sprite(self, %s, %s, %s, %s)" % [_q(who), _q(pose), _q(slot), _num(fade)],
	}


static func _param(args: String, line: int, ctx: Dictionary) -> Dictionary:
	var re := RegEx.new()
	re.compile("^(.+?)\\s*([+\\-=])\\s*(.+)$")
	var m := re.search(args)
	if m == null:
		ctx["errors"].append("第 %d 行：参数要写成 `名字 +5` 或 `名字 = 值`" % line)
		return {}

	var key := m.get_string(1).strip_edges()
	var op := m.get_string(2)
	var value_text := m.get_string(3).strip_edges()

	if op == "=":
		return {
			"kind": "sync",
			"line": line,
			"stmt": "VNKit.set_param(self, %s, %s)" % [_q(key), _literal(value_text)],
		}

	var number := value_text.to_float()
	if not value_text.is_valid_float():
		ctx["errors"].append("第 %d 行：增减参数只能用数字（现在是 `%s`）" % [line, value_text])
		return {}
	if op == "-":
		number = -number
	return {
		"kind": "sync",
		"line": line,
		"stmt": "VNKit.add_param(self, %s, %s)" % [_q(key), _num(number)],
	}


## ---- 表达式 ----

## 判断只支持「变量 运算符 字面量」。这不是偷懒，是边界：
## 一旦允许任意表达式，编译器就要背一个求值器，那就成了第二个程序。
static func _condition(expr: String, line: int, ctx: Dictionary) -> String:
	if expr.contains("且") or expr.contains("或") or expr.contains("&&") or expr.contains("||"):
		ctx["errors"].append("第 %d 行：暂不支持复合条件（且/或），请拆成两层判断" % line)
		return "false"

	var re := RegEx.new()
	re.compile("^(.+?)\\s*(==|!=|>=|<=|>|<)\\s*(.+)$")
	var m := re.search(expr)
	if m == null:
		ctx["errors"].append(
			"第 %d 行：判断要写成 `变量 运算符 值`，例如 `好感 >= 50`" % line
		)
		return "false"

	var name := m.get_string(1).strip_edges()
	var op := m.get_string(2)
	var value := m.get_string(3).strip_edges()
	if name == "" or value == "":
		ctx["errors"].append("第 %d 行：判断缺少变量名或比较值" % line)
		return "false"

	return "VNKit.get_param(self, %s, %s) %s %s" % [
		_q(name), _fallback(value), op, _literal(value)
	]


## 参数不在表里时 get_param 返回的兜底值，按比较值的类型给。
## 不配 fallback 的话，没挂 StoryRunner 的剧本会在比较处崩掉。
static func _fallback(value: String) -> String:
	if _is_number(value):
		if value.contains("."):
			return "0.0"
		return "0"
	if value == "true" or value == "false":
		return "false"
	return "\"\""


static func _literal(value: String) -> String:
	if _is_number(value):
		return value
	if value == "true" or value == "false":
		return value
	if value.begins_with("\"") and value.ends_with("\"") and value.length() >= 2:
		return value
	if value.begins_with("「") and value.ends_with("」") and value.length() >= 2:
		return _q(value.substr(1, value.length() - 2))
	# 裸词当字符串：剧本里写 `名字 = 凛` 比强制加引号自然。
	return _q(value)


static func _is_number(value: String) -> bool:
	if value.is_valid_int():
		return true
	if value.is_valid_float():
		return value.contains(".")
	return false


## ---- 小工具 ----

static func _slot(raw: String) -> String:
	match raw:
		"中", "中央", "center":
			return "center"
		"左", "left":
			return "left"
		"右", "right":
			return "right"
		_:
			return raw


static func _float_arg(raw: String, default_value: float, line: int, label: String, ctx: Dictionary) -> float:
	var text := raw.strip_edges()
	if not text.is_valid_float():
		ctx["errors"].append("第 %d 行：%s 必须是数字（现在是 `%s`）" % [line, label, text])
		return default_value
	return text.to_float()


## 去掉浮点尾巴：0.400000 生成出来太脏，0.4 就够了。
static func _num(value: float) -> String:
	var text := String.num(value, 3)
	if text.contains("."):
		text = text.rstrip("0").rstrip(".")
	return "0" if text == "" else text


static func _q(text: String) -> String:
	return "\"" + text.replace("\\", "\\\\").replace("\"", "\\\"") + "\""


static func _tab(level: int) -> String:
	return TAB.repeat(level)

## 剧本 DSL 的结构解析：.script.txt → 节点树。
##
## 只做结构，不认识动作语义。「背景」「立绘」怎么变成 VNKit 调用是 dsl_emit 的事，
## 所以加一个动作不用动这个文件，改语法才动它。
##
## 合法写法只有四种，其余一律报错并给行号：
##   角色：「台词」
##   [指令：参数]
##   [选择项：提示  /  - 选项 + 正文  /  ]
##   [判断：表达式  /  - 否则判断：表达式  /  - 否则  /  ]
##
## 节点形态（Dictionary）：
##   beat    {kind, line, items: [say|command]}
##   say     {kind, line, speaker, text}
##   command {kind, line, raw}        raw = 方括号内的原文，交给 emit 解释
##   choice  {kind, line, prompt, options: [{label, line, body: [node]}]}
##   if      {kind, line, branches: [{kind: if|elif|else, expr, line, body: [node]}]}
##
## 空行是「拍」的边界：同一拍里的多条动作同时开始，不同拍按顺序等完再走。
class_name VNDslParser
extends RefCounted

const CHOICE_OPEN := "[选择项："
const IF_OPEN := "[判断："
const OPTION_PREFIX := "- "
const ELSE_IF := "- 否则判断："
const ELSE := "- 否则"
const CLOSE := "]"


## 解析全文。返回值永远是 {ok, errors, warnings, roots}，不抛异常——
## 调用方看 ok 决定要不要生成，看 errors 决定在面板里标哪一行。
static func parse(source: String) -> Dictionary:
	var errors: Array = []
	var warnings: Array = []
	var entries := _entries(source)
	var roots := _parse_range(entries, 0, entries.size(), errors, warnings)
	return {
		"ok": errors.is_empty(),
		"errors": errors,
		"warnings": warnings,
		"roots": roots,
	}


## ---- 行表 ----

## 保留原始行号。空行也要留着，它是拍的边界，不能在预处理阶段吃掉。
static func _entries(source: String) -> Array:
	var out: Array = []
	var normalized := source.replace("\r\n", "\n").replace("\r", "\n")
	var lines := normalized.split("\n")
	for i in lines.size():
		out.append({"text": String(lines[i]), "line": i + 1})
	return out


## ---- 区间解析 ----

## 把 entries[from, to) 解析成节点列表。块体递归调用时传自己的子数组。
static func _parse_range(entries: Array, from: int, to: int, errors: Array, warnings: Array) -> Array:
	var nodes: Array = []
	var i := from
	while i < to:
		var text := String(entries[i]["text"])
		var line := int(entries[i]["line"])

		if text.strip_edges() == "" or text.strip_edges().begins_with("#"):
			i += 1
			continue

		if _is_border(text):
			i = _skip_scene_block(entries, i, to, warnings)
			continue

		var kind := _block_kind(text)
		if kind != "":
			var res := _parse_block(entries, i, to, kind, errors, warnings)
			if res.has("node"):
				nodes.append(res["node"])
			i = int(res["next"])
			continue

		# 一拍：连续的非空行，直到空行或下一个块开始。
		var items: Array = []
		var beat_line := line
		while i < to:
			var t := String(entries[i]["text"]).strip_edges()
			if t == "" or _is_border(t):
				break
			if t.begins_with("#"):
				i += 1
				continue
			if _block_kind(t) != "":
				break
			var item := _parse_item(entries[i], errors)
			if not item.is_empty():
				items.append(item)
			i += 1
		if not items.is_empty():
			nodes.append({"kind": "beat", "line": beat_line, "items": items})

	return nodes


## ---- 单行 ----

static func _parse_item(entry: Dictionary, errors: Array) -> Dictionary:
	var text := String(entry["text"]).strip_edges()
	var line := int(entry["line"])

	if text.begins_with("["):
		if not text.ends_with("]"):
			errors.append("第 %d 行：指令没有用 ] 收尾" % line)
			return {}
		return {
			"kind": "command",
			"line": line,
			"raw": text.substr(1, text.length() - 2).strip_edges(),
		}

	var re := RegEx.new()
	re.compile("^([^：「」]+)：「(.*)」$")
	var m := re.search(text)
	if m != null:
		return {
			"kind": "say",
			"line": line,
			"speaker": m.get_string(1).strip_edges(),
			"text": m.get_string(2),
		}

	errors.append("第 %d 行：无法识别的行。台词写成 角色：「内容」，指令写成 [名称：参数]" % line)
	return {}


## ---- 块 ----

static func _block_kind(text: String) -> String:
	var t := text.strip_edges()
	if t.begins_with(CHOICE_OPEN) and not t.ends_with(CLOSE):
		return "choice"
	if t.begins_with(IF_OPEN) and not t.ends_with(CLOSE):
		return "if"
	return ""


## 从块起始行找到它自己的收尾 `]`。按嵌套深度数，不是「第一眼看到的 ]」——
## 选项正文里套判断时，那个 ] 属于内层，外层不能提前收工。
static func _find_block_end(entries: Array, start: int, to: int) -> int:
	var depth := 1
	var j := start + 1
	while j < to:
		var t := String(entries[j]["text"]).strip_edges()
		if _block_kind(t) != "":
			depth += 1
		elif t == CLOSE:
			depth -= 1
			if depth == 0:
				return j
		j += 1
	return to - 1


static func _parse_block(
	entries: Array, i: int, to: int, kind: String, errors: Array, warnings: Array
) -> Dictionary:
	if kind == "choice":
		return _parse_choice(entries, i, to, errors, warnings)
	return _parse_if(entries, i, to, errors, warnings)


static func _parse_choice(
	entries: Array, start: int, to: int, errors: Array, warnings: Array
) -> Dictionary:
	var line := int(entries[start]["line"])
	var text := String(entries[start]["text"]).strip_edges()
	var prompt := text.trim_prefix(CHOICE_OPEN).strip_edges()

	var options: Array = []
	var current: Dictionary = {}
	var j := start + 1
	var closed := false

	while j < to:
		var t := String(entries[j]["text"]).strip_edges()
		var ln := int(entries[j]["line"])
		if t == CLOSE:
			closed = true
			j += 1
			break
		# 嵌套块整体吞掉再交给递归：否则判断块里的 `- 否则` 会被
		# 外层选择项当成新选项，选项结构就串了。
		if _block_kind(t) != "":
			var end := _find_block_end(entries, j, to)
			if current.is_empty():
				errors.append("第 %d 行：选项正文前缺少 `- 选项`" % ln)
			else:
				for k in range(j, end + 1):
					current["entries"].append(entries[k])
			j = end + 1
			continue
		if t.begins_with(OPTION_PREFIX):
			if not current.is_empty():
				options.append(current)
			var label := t.substr(OPTION_PREFIX.length()).strip_edges()
			if label == "":
				errors.append("第 %d 行：选项文字为空" % ln)
			current = {"label": label, "line": ln, "entries": []}
			j += 1
			continue
		if current.is_empty():
			if t != "" and not t.begins_with("#"):
				errors.append("第 %d 行：选项正文前缺少 `- 选项`" % ln)
			j += 1
			continue
		# 选项正文保留空行：它同样是拍边界。
		current["entries"].append(entries[j])
		j += 1

	if not current.is_empty():
		options.append(current)
	if not closed:
		errors.append("第 %d 行：选择项没有用单独的 ] 收尾" % line)
	if options.size() < 2:
		errors.append("第 %d 行：选择项至少要有两个选项" % line)

	var built: Array = []
	for opt in options:
		var body := _parse_range(opt["entries"], 0, opt["entries"].size(), errors, warnings)
		built.append({"label": opt["label"], "line": opt["line"], "body": body})

	return {
		"next": j,
		"node": {"kind": "choice", "line": line, "prompt": prompt, "options": built},
	}


static func _parse_if(
	entries: Array, start: int, to: int, errors: Array, warnings: Array
) -> Dictionary:
	var line := int(entries[start]["line"])
	var text := String(entries[start]["text"]).strip_edges()
	var expr := text.trim_prefix(IF_OPEN).strip_edges()
	if expr == "":
		errors.append("第 %d 行：判断缺少表达式" % line)

	var branches: Array = []
	var current := {"kind": "if", "expr": expr, "line": line, "entries": []}
	var seen_else := false
	var j := start + 1
	var closed := false

	while j < to:
		var t := String(entries[j]["text"]).strip_edges()
		var ln := int(entries[j]["line"])
		if t == CLOSE:
			closed = true
			j += 1
			break

		# 判断体里套一个选择项时，它的 `]` 不能被当成外层判断的收尾。
		if _block_kind(t) != "":
			var end := _find_block_end(entries, j, to)
			for k in range(j, end + 1):
				current["entries"].append(entries[k])
			j = end + 1
			continue

		if t.begins_with(ELSE_IF):
			if seen_else:
				errors.append("第 %d 行：`- 否则` 之后不能再写分支" % ln)
			branches.append(current)
			var elif_expr := t.substr(ELSE_IF.length()).strip_edges()
			if elif_expr == "":
				errors.append("第 %d 行：否则判断缺少表达式" % ln)
			current = {"kind": "elif", "expr": elif_expr, "line": ln, "entries": []}
			j += 1
			continue

		if t.begins_with(ELSE):
			if seen_else:
				errors.append("第 %d 行：`- 否则` 只能出现一次" % ln)
			var rest := t.substr(ELSE.length()).strip_edges()
			if rest != "":
				errors.append("第 %d 行：`- 否则` 后面不能带条件" % ln)
			branches.append(current)
			current = {"kind": "else", "expr": "", "line": ln, "entries": []}
			seen_else = true
			j += 1
			continue

		current["entries"].append(entries[j])
		j += 1

	branches.append(current)
	if not closed:
		errors.append("第 %d 行：判断没有用单独的 ] 收尾" % line)

	var built: Array = []
	for branch in branches:
		var body := _parse_range(branch["entries"], 0, branch["entries"].size(), errors, warnings)
		built.append({
			"kind": branch["kind"],
			"expr": branch["expr"],
			"line": branch["line"],
			"body": body,
		})

	return {
		"next": j,
		"node": {"kind": "if", "line": line, "branches": built},
	}


## ---- 场景块 ----

## 场景块只在 Web 版有意义（播标题横幅）。这里认出来并跳过，
## 不报错、不生成代码，但给一条 warning——静默丢信息比报错更难查。
static func _skip_scene_block(entries: Array, start: int, to: int, warnings: Array) -> int:
	var line := int(entries[start]["line"])
	var j := start + 1
	while j < to:
		if _is_border(String(entries[j]["text"])):
			warnings.append("第 %d 行：场景块已忽略（Godot 侧没有对应动作，换背景请用 [背景：…]）" % line)
			return j + 1
		j += 1
	warnings.append("第 %d 行：场景块没有下边框，已忽略" % line)
	return j


static func _is_border(text: String) -> bool:
	var t := text.strip_edges()
	if t.length() < 3:
		return false
	return t.count("═") == t.length()

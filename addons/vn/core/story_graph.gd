## 章节级路由图：只回答「这一段播完了，下一段是谁」。
##
## 设计约束：
## - 不执行任何东西，只被查询。真正跑的是章节 .gd 里的代码。
## - guard 只能引用参数表，不能访问场景、不能调函数。这条限制保证图永远不会变成第二个程序。
## - 数据是 JSON：可手改、可 git diff、字段变了迁移便宜。pos 只给编辑器用，运行时忽略。
## - 不持有「当前片段」，那是 StoryRunner 的事。
class_name StoryGraph
extends RefCounted

## 两种片段类型。chapter 要播脚本，end 只表示「到此为止」。
## 只有这两种，是为了让图永远不可能变成第二个程序——没有分支片段、没有循环片段。
const TYPE_CHAPTER := "chapter"
const TYPE_END := "end"

## 数据格式版本。目前只记录、不参与判断，将来字段不兼容时用来做迁移。
var version := 1
## 起始片段 id。空 = 校验报错，图不启动。
var entry := ""
## id -> {id, type, chapter, pos, ...}
var states: Dictionary = {}
## from_id -> Array[Dictionary]，已按 priority 升序
var transitions: Dictionary = {}
## id -> {label, type, default}
var params: Dictionary = {}

## 致命问题：出现就不该启动
var errors: Array[String] = []
## 不影响运行的问题：孤立片段、未连线
var warnings: Array[String] = []

## 参数名列表，顺序固定。Expression.execute 按位置传参，靠它把 Dictionary 摊成 Array。
var _param_names: PackedStringArray = PackedStringArray()
## guard 文本 -> Expression（null 表示解析失败）。同一句 guard 只编译一次。
var _expr_cache: Dictionary = {}


## 从文件载入。任何一步失败都只往 errors 里塞一句话然后返回，
## 不抛异常、不返回 null —— 调用方永远拿到一个对象，看 errors 决定要不要播。
static func load_file(path: String) -> StoryGraph:
	var graph := StoryGraph.new()
	if path == "":
		graph.errors.append("图路径为空")
		return graph
	if not FileAccess.file_exists(path):
		graph.errors.append("文件不存在：%s" % path)
		return graph

	var text := FileAccess.get_file_as_string(path)
	if text == "":
		graph.errors.append("文件为空或无法读取：%s" % path)
		return graph

	var json := JSON.new()
	if json.parse(text) != OK:
		graph.errors.append("JSON 解析失败：第 %d 行 %s" % [json.get_error_line(), json.get_error_message()])
		return graph
	if not json.data is Dictionary:
		graph.errors.append("文件根必须是对象")
		return graph

	graph._build(json.data)
	return graph


## 直接从内存字典载入。编辑器用它做即时校验，不必先落盘。
static func load_dict(data: Dictionary) -> StoryGraph:
	var graph := StoryGraph.new()
	graph._build(data)
	return graph


## 参数表的初始值，StoryRunner 每局开始时复制一份。
func initial_params() -> Dictionary:
	var out := {}
	for key in params:
		out[key] = params[key]["default"]
	return out


func has_state(id: String) -> bool:
	return states.has(id)


## 取片段数据，不存在返回空字典（调用方判 is_empty 即可，不用先 has_state）。
func get_state(id: String) -> Dictionary:
	return states.get(id, {})


## 边总数。transitions 是按起点分组存的，所以要累加。
func transition_count() -> int:
	var total := 0
	for from_id in transitions:
		total += transitions[from_id].size()
	return total


## 按 priority 升序找第一条满足的边。返回 {} 表示无路可走。
func pick_transition(from_id: String, values: Dictionary) -> Dictionary:
	for tr in transitions.get(from_id, []):
		if eval_guard(String(tr["guard"]), values):
			return tr
	return {}


## 求一句 guard。空 guard 视为「恒真」，也就是默认边。
## 编译失败或求值失败一律当作不命中（返回 false），不会把异常抛给主循环。
func eval_guard(guard: String, values: Dictionary) -> bool:
	if guard.strip_edges() == "":
		return true
	var expr := _compile(guard)
	if expr == null:
		return false

	var args: Array = []
	for name in _param_names:
		args.append(values.get(name, params[name]["default"]))

	var result: Variant = expr.execute(args, null, false)
	if expr.has_execute_failed():
		push_error("[StoryGraph] guard 求值失败：%s（%s）" % [guard, expr.get_error_text()])
		return false
	return bool(result)


## ---- 内部 ----

## 把原始字典摊平成本类字段，最后统一跑编译和校验。
## 容错策略：单项坏（非对象、缺 id、id 重复）只记 errors 并跳过该项，
## 剩下的照常载入——这样一份手改出错的图还能打开看，不是整个打不开。
func _build(data: Dictionary) -> void:
	version = int(data.get("version", 1))
	entry = String(data.get("entry", ""))

	var raw_params: Dictionary = data.get("params", {})
	for key in raw_params:
		var p: Dictionary = raw_params[key]
		params[String(key)] = {
			"label": String(p.get("label", key)),
			"type": String(p.get("type", "int")),
			"default": _default_value(p),
		}
	_param_names = PackedStringArray(params.keys())

	var raw_states: Array = data.get("states", [])
	for item in raw_states:
		if not item is Dictionary:
			errors.append("states 里出现非对象项")
			continue
		var st: Dictionary = (item as Dictionary).duplicate(true)
		var id := String(st.get("id", ""))
		if id == "":
			errors.append("有片段缺少 id")
			continue
		if states.has(id):
			errors.append("片段 id 重复：%s" % id)
			continue
		st["id"] = id
		st["type"] = String(st.get("type", TYPE_CHAPTER))
		states[id] = st

	var raw_tr: Array = data.get("transitions", [])
	var order := 0
	for item in raw_tr:
		if not item is Dictionary:
			errors.append("transitions 里出现非对象项")
			continue
		var tr: Dictionary = (item as Dictionary).duplicate(true)
		var from_id := String(tr.get("from", ""))
		tr["to"] = String(tr.get("to", ""))
		tr["guard"] = String(tr.get("guard", ""))
		tr["priority"] = int(tr.get("priority", order + 1))
		tr["_order"] = order
		order += 1
		if not transitions.has(from_id):
			transitions[from_id] = []
		transitions[from_id].append(tr)

	for from_id in transitions:
		transitions[from_id].sort_custom(_compare_transition)

	_compile_guards()
	_validate()


## 排序：priority 小的先，同 priority 保持 JSON 里的书写顺序（_order），
## 这样加字段、换写法都不会让「默认边」意外换人。
func _compare_transition(a: Dictionary, b: Dictionary) -> bool:
	if int(a["priority"]) != int(b["priority"]):
		return int(a["priority"]) < int(b["priority"])
	return int(a["_order"]) < int(b["_order"])


## 声明了 type 就按 type 掰，缺省当 int。JSON 的数字一律是 float，
## 不做这一步的话 affection 会从 5 变成 5.0 再变成 5.0 加不完。
func _default_value(p: Dictionary) -> Variant:
	var t := String(p.get("type", "int"))
	var d: Variant = p.get("default", null)
	match t:
		"flag", "bool":
			return bool(d) if d != null else false
		"float":
			return float(d) if d != null else 0.0
		"string":
			return String(d) if d != null else ""
		_:
			return int(d) if d != null else 0


## 载入时把全部 guard 预编译一遍。好处是两个：拼错的 guard 在启动时就报，
## 不是走到那条边才报；运行时每次求值都命中缓存，不重复 parse。
func _compile_guards() -> void:
	for from_id in transitions:
		for tr in transitions[from_id]:
			_compile(String(tr["guard"]))


## 返回 null 表示「不编译或编译失败」。空 guard 走 eval_guard 的短路，不到这里。
func _compile(guard: String) -> Expression:
	if guard.strip_edges() == "":
		return null
	if _expr_cache.has(guard):
		return _expr_cache[guard]

	_check_guard_identifiers(guard)

	var expr := Expression.new()
	if expr.parse(guard, _param_names) != OK:
		errors.append("guard 无法解析：%s（%s）" % [guard, expr.get_error_text()])
		_expr_cache[guard] = null
		return null

	_expr_cache[guard] = expr
	return expr


## Expression.parse() 会放过未声明的标识符，于是拼错参数名的边会永远静默不命中。
## 这里做词法层白名单：允许参数名、字面量、函数调用（后跟括号），其余一律报错。
const _LITERAL_WORDS := ["true", "false", "null", "PI", "TAU", "INF", "NAN"]


func _check_guard_identifiers(guard: String) -> void:
	var text := _strip_string_literals(guard)
	var re := RegEx.new()
	re.compile("[A-Za-z_][A-Za-z0-9_]*")
	for m in re.search_all(text):
		var word := m.get_string()
		if _LITERAL_WORDS.has(word) or params.has(word):
			continue
		if text.substr(m.get_end()).strip_edges(true, false).begins_with("("):
			continue
		errors.append("guard 引用了未声明的参数：%s（guard: %s）" % [word, guard])


## 先把字符串字面量替换成 0，免得 "affection>=5" 里的单词被当成标识符扫出来。
func _strip_string_literals(text: String) -> String:
	var out := text
	var re := RegEx.new()
	if re.compile("\"[^\"]*\"") == OK:
		out = re.sub(out, "0", true)
	if re.compile("'[^']*'") == OK:
		out = re.sub(out, "0", true)
	return out


## 结构性校验。errors 决定「能不能播」，warnings 只提示、不拦。
func _validate() -> void:
	if entry == "":
		errors.append("缺少 entry")
	elif not states.has(entry):
		errors.append("entry 指向不存在的片段：%s" % entry)

	var has_incoming := {}
	for from_id in transitions:
		if not states.has(from_id):
			errors.append("transition 的 from 不存在：%s" % from_id)
			continue
		for tr in transitions[from_id]:
			var to_id: String = tr["to"]
			if not states.has(to_id):
				errors.append("%s -> %s：目标片段不存在" % [from_id, to_id])
				continue
			has_incoming[to_id] = true
			if to_id == from_id:
				errors.append("%s -> %s：自己指向自己，会无限循环" % [from_id, to_id])

	for id in states:
		var st: Dictionary = states[id]
		if String(st["type"]) == TYPE_CHAPTER and String(st.get("chapter", "")) == "":
			warnings.append("片段 %s 还没指定章节脚本（草稿态）" % id)
		if String(st["type"]) != TYPE_END and not transitions.has(id):
			warnings.append("片段 %s 是死路（没有任何出边）" % id)
		if id != entry and not has_incoming.has(id):
			warnings.append("片段 %s 不可达（没有入边）" % id)

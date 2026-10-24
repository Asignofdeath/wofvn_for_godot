## 章节级路由图：只回答「这一段播完了，下一段是谁」。
##
## 设计约束：
## - 不执行任何东西，只被查询。真正跑的是章节 .gd 里的代码。
## - guard 只能引用参数表，不能访问场景、不能调函数。这条限制保证图永远不会变成第二个程序。
## - 数据是 JSON：可手改、可 git diff、字段变了迁移便宜。pos 只给编辑器用，运行时忽略。
## - 不持有「当前状态」，那是 StoryRunner 的事。
class_name StoryGraph
extends RefCounted

const TYPE_CHAPTER := "chapter"
const TYPE_END := "end"

var version := 1
var entry := ""
## id -> {id, type, chapter, pos, ...}
var states: Dictionary = {}
## from_id -> Array[Dictionary]，已按 priority 升序
var transitions: Dictionary = {}
## id -> {label, type, default}
var params: Dictionary = {}

## 致命问题：出现就不该启动
var errors: Array[String] = []
## 不影响运行的问题：孤立节点、未连线
var warnings: Array[String] = []

var _param_names: PackedStringArray = PackedStringArray()
var _expr_cache: Dictionary = {}


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
		graph.errors.append("根节点必须是对象")
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


func get_state(id: String) -> Dictionary:
	return states.get(id, {})


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
			errors.append("有状态缺少 id")
			continue
		if states.has(id):
			errors.append("状态 id 重复：%s" % id)
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


func _compare_transition(a: Dictionary, b: Dictionary) -> bool:
	if int(a["priority"]) != int(b["priority"]):
		return int(a["priority"]) < int(b["priority"])
	return int(a["_order"]) < int(b["_order"])


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


func _strip_string_literals(text: String) -> String:
	var out := text
	var re := RegEx.new()
	if re.compile("\"[^\"]*\"") == OK:
		out = re.sub(out, "0", true)
	if re.compile("'[^']*'") == OK:
		out = re.sub(out, "0", true)
	return out


func _validate() -> void:
	if entry == "":
		errors.append("缺少 entry")
	elif not states.has(entry):
		errors.append("entry 指向不存在的状态：%s" % entry)

	var has_incoming := {}
	for from_id in transitions:
		if not states.has(from_id):
			errors.append("transition 的 from 不存在：%s" % from_id)
			continue
		for tr in transitions[from_id]:
			var to_id: String = tr["to"]
			if not states.has(to_id):
				errors.append("%s -> %s：目标状态不存在" % [from_id, to_id])
				continue
			has_incoming[to_id] = true
			if to_id == from_id:
				errors.append("%s -> %s：自己指向自己，会无限循环" % [from_id, to_id])

	for id in states:
		var st: Dictionary = states[id]
		if String(st["type"]) == TYPE_CHAPTER and String(st.get("chapter", "")) == "":
			warnings.append("状态 %s 还没指定章节脚本（草稿态）" % id)
		if String(st["type"]) != TYPE_END and not transitions.has(id):
			warnings.append("状态 %s 是死路（没有任何出边）" % id)
		if id != entry and not has_incoming.has(id):
			warnings.append("状态 %s 不可达（没有入边）" % id)

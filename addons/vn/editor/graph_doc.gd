## 编辑器侧的图数据：JSON <-> 内存，纯数据、不碰 UI、不碰 SceneTree。
##
## 与 StoryGraph 的分工：
##   VNGraphDoc = 读写 + 编辑（只在编辑器用，不进运行时）
##   StoryGraph = 载入 + 查询下一跳（运行时用，不依赖编辑器）
## 两者读同一份 JSON，字段定义只有一个真相：story_graph.json 本身。
@tool
class_name VNGraphDoc
extends RefCounted

## 保存时先写这个后缀的临时文件，再改名替换目标文件
const TMP_SUFFIX := ".vntmp"

var path := ""
var version := 1
var entry := ""
## 原样保留，编辑器不解释参数，只负责不丢
var params: Dictionary = {}
## [{id, type, chapter, pos: Vector2}]
var states: Array = []
## [{from, to, guard, priority}]
var transitions: Array = []


## 载入指定文件。失败时保持内存里的原数据不动——打开一个坏文件不该把当前画布清空。
func load_from(p: String) -> Array:
	var issues: Array = []

	if not FileAccess.file_exists(p):
		issues.append("文件不存在：%s" % p)
		return issues

	var text := FileAccess.get_file_as_string(p)
	if text == "":
		issues.append("文件为空或无法读取：%s" % p)
		return issues

	var json := JSON.new()
	if json.parse(text) != OK:
		issues.append("JSON 解析失败：第 %d 行 %s" % [json.get_error_line(), json.get_error_message()])
		return issues
	if not json.data is Dictionary:
		issues.append("根节点必须是对象")
		return issues

	reset()
	path = p
	from_dict(json.data)
	return issues


func reset() -> void:
	version = 1
	entry = ""
	params = {}
	states = []
	transitions = []


func from_dict(d: Dictionary) -> void:
	version = int(d.get("version", 1))
	entry = String(d.get("entry", ""))
	params = (d.get("params", {}) as Dictionary).duplicate(true)

	states = []
	for item in d.get("states", []):
		if not item is Dictionary:
			continue
		var raw_pos: Array = item.get("pos", [0, 0])
		states.append({
			"id": String(item.get("id", "")),
			"type": String(item.get("type", "chapter")),
			"chapter": String(item.get("chapter", "")),
			"pos": Vector2(
				float(raw_pos[0]) if raw_pos.size() > 0 else 0.0,
				float(raw_pos[1]) if raw_pos.size() > 1 else 0.0
			),
			# 原样留一份，保存时当底板用：手写在 JSON 里的额外字段不会丢
			"_raw": (item as Dictionary).duplicate(true),
		})

	transitions = []
	for item in d.get("transitions", []):
		if not item is Dictionary:
			continue
		transitions.append({
			"from": String(item.get("from", "")),
			"to": String(item.get("to", "")),
			"guard": String(item.get("guard", "")),
			"priority": int(item.get("priority", 1)),
			"_raw": (item as Dictionary).duplicate(true),
		})


func to_dict() -> Dictionary:
	var out_states: Array = []
	for st in states:
		# 以原始字段为底，再用编辑器认识的字段覆盖，未知字段照原样带回去
		var d: Dictionary = (st.get("_raw", {}) as Dictionary).duplicate(true)
		d["id"] = st["id"]
		d["type"] = st["type"]
		if String(st["type"]) == "chapter":
			d["chapter"] = st["chapter"]
		# 非章节类型不主动写 chapter，但原文件里有就照原样留着，不替用户删字段
		var pos: Vector2 = st["pos"]
		d["pos"] = [int(pos.x), int(pos.y)]
		out_states.append(d)

	var out_tr: Array = []
	for tr in transitions:
		var d: Dictionary = (tr.get("_raw", {}) as Dictionary).duplicate(true)
		d["from"] = tr["from"]
		d["to"] = tr["to"]
		d["guard"] = tr["guard"]
		d["priority"] = int(tr["priority"])
		out_tr.append(d)

	return {
		"version": version,
		"entry": entry,
		"params": params,
		"states": out_states,
		"transitions": out_tr,
	}


## 先写同目录临时文件，成功后再改名替换。
## 直接对目标文件 WRITE 会先截断，写到一半出错（崩溃、断电、被中断）图就没了。
func save_to(p: String) -> Error:
	var abs_path := ProjectSettings.globalize_path(p)
	var abs_tmp := abs_path + TMP_SUFFIX

	var f := FileAccess.open(abs_tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	# 末尾补换行：手改 + git diff 时不会出现 "No newline at end of file"
	f.store_string(JSON.stringify(to_dict(), "\t", false) + "\n")
	f.flush()
	f.close()

	var dir := DirAccess.open(abs_path.get_base_dir())
	if dir == null:
		DirAccess.remove_absolute(abs_tmp)
		return DirAccess.get_open_error()
	var err := dir.rename(abs_tmp.get_file(), abs_path.get_file())
	if err != OK:
		DirAccess.remove_absolute(abs_tmp)
		return err

	path = p
	return OK


## ---- 查询 ----

func find_state(id: String) -> int:
	for i in states.size():
		if String(states[i]["id"]) == id:
			return i
	return -1


func find_transition(from_id: String, to_id: String) -> int:
	for i in transitions.size():
		if String(transitions[i]["from"]) == from_id and String(transitions[i]["to"]) == to_id:
			return i
	return -1


func next_id(prefix: String = "ch") -> String:
	var i := 1
	while i < 1000:
		var candidate := "%s%02d" % [prefix, i]
		if find_state(candidate) < 0:
			return candidate
		i += 1
	return "%s%02d" % [prefix, randi_range(1000, 9999)]


## ---- 编辑 ----

func add_state(id: String, type: String, chapter: String, pos: Vector2) -> bool:
	if id.strip_edges() == "" or find_state(id) >= 0:
		return false
	states.append({"id": id, "type": type, "chapter": chapter, "pos": pos})
	return true


func remove_state(id: String) -> void:
	var i := find_state(id)
	if i >= 0:
		states.remove_at(i)
	var kept: Array = []
	for tr in transitions:
		if String(tr["from"]) != id and String(tr["to"]) != id:
			kept.append(tr)
	transitions = kept


func set_state_pos(id: String, pos: Vector2) -> void:
	var i := find_state(id)
	if i >= 0:
		states[i]["pos"] = pos


func set_state_chapter(id: String, chapter: String) -> void:
	var i := find_state(id)
	if i >= 0:
		states[i]["chapter"] = chapter


## 新增边时 priority 自动接在该节点已有边之后，避免新边抢在最前面。
func add_transition(from_id: String, to_id: String) -> bool:
	if from_id == "" or to_id == "" or from_id == to_id:
		return false
	if find_transition(from_id, to_id) >= 0:
		return false
	var priority := 1
	for tr in transitions:
		if String(tr["from"]) == from_id:
			priority = maxi(priority, int(tr["priority"]) + 1)
	transitions.append({"from": from_id, "to": to_id, "guard": "", "priority": priority})
	return true

## 剧本 DSL 编译器：.script.txt → .gd。
##
## 这个文件是唯一碰磁盘的地方。解析（dsl_parser）和生成（dsl_emit）都是纯函数，
## 所以它们能被 headless 测试直接喂字符串，不用建临时项目。
##
## 生成物是普通 GDScript 协程剧本，不是资源、不是中间格式：
## 删掉 addons/vn/ 之后文件依然能打开，只是调不到 VNKit。
class_name VNDslCompiler
extends RefCounted

## 用 preload 而不是全局类名：headless 首次运行时 .godot 里还没有 class_name 缓存，
## 全局名会解析失败。preload 不依赖缓存，克隆下来就能跑测试。
const Parser := preload("dsl_parser.gd")
const Emitter := preload("dsl_emit.gd")

const GENERATED_MARK := "## 由 VN 剧本编译器生成，请勿手改。"
const SOURCE_KEY := "## 源文件："
const SOURCE_HASH_KEY := "## 源哈希："
const PRODUCT_HASH_KEY := "## 产物哈希："
const HASH_LEN := 12


## 只编译，不落盘。面板预览和测试都走这里。
static func compile_text(source: String, source_path: String) -> Dictionary:
	var ast := Parser.parse(source)
	var errors: Array = []
	errors.append_array(ast["errors"])
	var warnings: Array = []
	warnings.append_array(ast["warnings"])

	if not errors.is_empty():
		return _failed(errors, warnings)

	var emitted := Emitter.emit(ast["roots"], {"source_path": source_path})
	errors.append_array(emitted["errors"])
	warnings.append_array(emitted["warnings"])
	if not errors.is_empty():
		return _failed(errors, warnings)

	var source_hash := _hash(source)
	var head_without_product: Array = [
		GENERATED_MARK,
		SOURCE_KEY + source_path,
		SOURCE_HASH_KEY + source_hash,
	]
	var body: Array = emitted["lines"]

	var base_lines: Array = head_without_product.duplicate()
	base_lines.append_array(body)
	var product_hash := _hash("\n".join(base_lines) + "\n")

	var final_lines: Array = head_without_product.duplicate()
	final_lines.insert(3, PRODUCT_HASH_KEY + product_hash)
	final_lines.append_array(body)

	return {
		"ok": true,
		"errors": errors,
		"warnings": warnings,
		"code": "\n".join(final_lines) + "\n",
		"source_hash": source_hash,
		"product_hash": product_hash,
	}


## 编译并写盘。out 已存在时做两道保护：
##   1. 不是本编译器生成的（没有头标记）→ 拒绝，绝不覆盖手写剧本
##   2. 是生成文件但正文被手改过 → 拒绝，除非 force
## 返回的 errors 是给面板直接显示的，不需要再加工。
static func compile_file(source_path: String, out_path: String, force := false) -> Dictionary:
	if not FileAccess.file_exists(source_path):
		return _failed(["源文件不存在：%s" % source_path], [])

	var source := FileAccess.get_file_as_string(source_path)
	if source.strip_edges() == "":
		return _failed(["源文件是空的：%s" % source_path], [])

	if FileAccess.file_exists(out_path) and not force:
		var old := FileAccess.get_file_as_string(out_path)
		if not is_generated(old):
			return _failed([
				"目标已存在且不是生成文件，拒绝覆盖：%s（换个输出路径，或先备份它）" % out_path
			], [])
		var recorded := _product_hash_of(old)
		var actual := _hash(_without_product_hash(old))
		if recorded != "" and recorded != actual:
			return _failed([
				"产物被手改过，拒绝覆盖：%s（要放弃手改就加 force，要保留就挪走它）" % out_path
			], [])

	var result := compile_text(source, source_path)
	if not result["ok"]:
		return result

	var dir := out_path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	var file := FileAccess.open(out_path, FileAccess.WRITE)
	if file == null:
		return _failed([
			"写不进 %s（%s）" % [out_path, error_string(FileAccess.get_open_error())]
		], [])
	file.store_string(result["code"])
	file.close()

	result["out_path"] = out_path
	return result


## res://story/ch01.script.txt → res://story/ch01.gd
static func out_path_for(source_path: String) -> String:
	var base := source_path
	if base.ends_with(".script.txt"):
		base = base.substr(0, base.length() - ".script.txt".length())
	elif base.ends_with(".txt"):
		base = base.substr(0, base.length() - ".txt".length())
	return base + ".gd"


static func is_generated(text: String) -> bool:
	return text.begins_with(GENERATED_MARK)


## 产物头里那 12 位源哈希。面板判断「产物是否过期」时用同一个算法，
## 不要在面板里另写一份 sha256_text().substr(0, 12)——改一处漏一处就永远对不上。
static func source_hash(text: String) -> String:
	return _hash(text)


## 生成物头里记录的「源文件」路径。没有头返回空串。
static func source_path_of(text: String) -> String:
	for line in text.split("\n"):
		if line.begins_with(SOURCE_KEY):
			return line.trim_prefix(SOURCE_KEY).strip_edges()
	return ""


static func _product_hash_of(text: String) -> String:
	for line in text.split("\n"):
		if line.begins_with(PRODUCT_HASH_KEY):
			return line.trim_prefix(PRODUCT_HASH_KEY).strip_edges()
	return ""


## 校验产物是否被手改：把头里的产物哈希行去掉再算，否则自己改自己。
static func _without_product_hash(text: String) -> String:
	var kept: Array = []
	for line in text.split("\n"):
		if line.begins_with(PRODUCT_HASH_KEY):
			continue
		kept.append(line)
	return "\n".join(kept)


static func _hash(text: String) -> String:
	return text.sha256_text().substr(0, HASH_LEN)


static func _failed(errors: Array, warnings: Array) -> Dictionary:
	return {
		"ok": false,
		"errors": errors,
		"warnings": warnings,
		"code": "",
		"source_hash": "",
		"product_hash": "",
	}

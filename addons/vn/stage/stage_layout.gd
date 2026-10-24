## 舞台数据：槽位定义 + 每个角色的微调，一份 JSON。
##
## 设计约束：
## - 纯数据 + 两个几何函数。不碰 SceneTree、不碰编辑器 API、不持有时序状态。
## - 编辑器和运行时读同一份，字段定义只有 JSON 一个真相。
## - 图片靠目录约定找（chara_dir/<who>/<pose>.png），没有注册表、没有导入流程。
## - 找不到图不是错误，是「还没画」：返回 null，由调用方用占位色块顶上。
class_name VNStageLayout
extends RefCounted

## 三个基础槽位一定存在，JSON 里没写就用这组。
## x 是画布宽度比例（0 = 最左，1 = 最右），scale 是该槽位的整体缩放。
const DEFAULT_SLOTS := {
	"left": {"x": 0.24, "scale": 1.0},
	"center": {"x": 0.50, "scale": 1.0},
	"right": {"x": 0.76, "scale": 1.0},
}
const DEFAULT_CANVAS := Vector2i(1920, 1080)
## 缺图时占位色块的尺寸（画布坐标下的像素）
const DEFAULT_PLACEHOLDER := Vector2(700, 1080)
## 找图时依次尝试的后缀
const IMAGE_EXTS := ["png", "webp", "jpg", "jpeg"]
## 保存时先写这个后缀的临时文件，再改名替换目标文件
const TMP_SUFFIX := ".vntmp"

var path := ""
## 原样保留的格式版本，目前只记录不判断
var version := 1
## 参考画布尺寸。槽位 x 是比例，所以只影响占位图大小与预览
var canvas := DEFAULT_CANVAS
var placeholder := DEFAULT_PLACEHOLDER
var chara_dir := "res://art/chara"
var bg_dir := "res://art/bg"
## name -> {x, scale, _raw}
var slots: Dictionary = {}
## who -> {offset: Vector2, scale: float, _raw}
var characters: Dictionary = {}

## 载入 / 校验时攒下的人话问题。空 = 没问题
var issues: Array[String] = []


## ---- 载入 / 保存 ----

## 载入指定文件。校验全过之后才 reset，打开一个坏文件不会清空当前画布。
func load_from(p: String) -> Array:
	issues = []
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


## 清空成「新建」状态。
func reset() -> void:
	version = 1
	canvas = DEFAULT_CANVAS
	placeholder = DEFAULT_PLACEHOLDER
	chara_dir = "res://art/chara"
	bg_dir = "res://art/bg"
	slots = {}
	characters = {}
	issues = []
	# 三个基础槽位先铺上，之后面板/运行时永远不会遇到「槽位不存在」
	for k in DEFAULT_SLOTS:
		slots[k] = (DEFAULT_SLOTS[k] as Dictionary).duplicate(true)
		slots[k]["_raw"] = {}


func from_dict(d: Dictionary) -> void:
	version = int(d.get("version", 1))
	canvas = _to_vec2i(d.get("canvas", [DEFAULT_CANVAS.x, DEFAULT_CANVAS.y]))
	placeholder = _to_vec2(d.get("placeholder", [DEFAULT_PLACEHOLDER.x, DEFAULT_PLACEHOLDER.y]))
	chara_dir = String(d.get("chara_dir", chara_dir))
	bg_dir = String(d.get("bg_dir", bg_dir))

	if slots.is_empty():
		for k in DEFAULT_SLOTS:
			slots[k] = (DEFAULT_SLOTS[k] as Dictionary).duplicate(true)
			slots[k]["_raw"] = {}
	var raw_slots: Dictionary = d.get("slots", {})
	for key in raw_slots:
		var raw: Dictionary = raw_slots[key] if raw_slots[key] is Dictionary else {}
		slots[String(key)] = {
			"x": float(raw.get("x", 0.5)),
			"scale": float(raw.get("scale", 1.0)),
			"_raw": raw.duplicate(true),
		}

	characters = {}
	var raw_chars: Dictionary = d.get("characters", {})
	for key in raw_chars:
		var raw: Dictionary = raw_chars[key] if raw_chars[key] is Dictionary else {}
		characters[String(key)] = {
			"offset": _to_vec2(raw.get("offset", [0, 0])),
			"scale": float(raw.get("scale", 1.0)),
			"_raw": raw.duplicate(true),
		}


## 手写字段原样带回去：以 _raw 为底，再覆盖本类认识的字段。
func to_dict() -> Dictionary:
	var out_slots := {}
	for name in slots:
		var s: Dictionary = slots[name]
		var d: Dictionary = (s.get("_raw", {}) as Dictionary).duplicate(true)
		d["x"] = float(s["x"])
		d["scale"] = float(s["scale"])
		out_slots[name] = d

	var out_chars := {}
	for who in characters:
		var c: Dictionary = characters[who]
		var d: Dictionary = (c.get("_raw", {}) as Dictionary).duplicate(true)
		var off: Vector2 = c["offset"]
		d["offset"] = [int(off.x), int(off.y)]
		d["scale"] = float(c["scale"])
		out_chars[who] = d

	return {
		"version": version,
		"canvas": [canvas.x, canvas.y],
		"placeholder": [int(placeholder.x), int(placeholder.y)],
		"chara_dir": chara_dir,
		"bg_dir": bg_dir,
		"slots": out_slots,
		"characters": out_chars,
	}


## 原子写：临时文件 + rename，中途崩掉不会留下半个文件。
func save_to(p: String) -> Error:
	var abs_path := ProjectSettings.globalize_path(p)
	var abs_tmp := abs_path + TMP_SUFFIX
	var f := FileAccess.open(abs_tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
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

func has_slot(slot_name: String) -> bool:
	return slots.has(slot_name)


func slot_names() -> PackedStringArray:
	return PackedStringArray(slots.keys())


## 取槽位。未知名字回退到 center（宁可站着也别消失），不在这里报警——运行时统一报。
func slot(slot_name: String) -> Dictionary:
	if slots.has(slot_name):
		return slots[slot_name]
	return slots.get("center", DEFAULT_SLOTS["center"])


## 取角色微调。没登记过的角色给一份全零，边播边攒，不需要先登记。
func character(who: String) -> Dictionary:
	if characters.has(who):
		return characters[who]
	return {"offset": Vector2.ZERO, "scale": 1.0, "_raw": {}}


func set_character(who: String, offset: Vector2, char_scale: float) -> void:
	var cur := character(who)
	characters[who] = {
		"offset": offset,
		"scale": char_scale,
		"_raw": cur.get("_raw", {}),
	}


func set_slot(slot_name: String, x: float, slot_scale: float) -> void:
	var cur := slot(slot_name)
	slots[slot_name] = {
		"x": clampf(x, 0.0, 1.0),
		"scale": maxf(slot_scale, 0.01),
		"_raw": cur.get("_raw", {}),
	}


## 立绘文件路径。按 pose -> default 的顺序退让；都没有返回空串。
func chara_path(who: String, pose: String) -> String:
	for candidate_pose in _pose_chain(pose):
		var base := "%s/%s/%s" % [chara_dir.trim_suffix("/"), who, candidate_pose]
		for ext in IMAGE_EXTS:
			var p := "%s.%s" % [base, ext]
			if FileAccess.file_exists(p):
				return p
	return ""


## 背景文件路径。id 本身就是路径时直接用；否则按 bg_dir/<id>.<ext> 找。
func bg_path(id: String) -> String:
	if id.begins_with("res://") or id.begins_with("user://"):
		return id
	var base := "%s/%s" % [bg_dir.trim_suffix("/"), id]
	for ext in IMAGE_EXTS:
		var p := "%s.%s" % [base, ext]
		if FileAccess.file_exists(p):
			return p
	return ""


## 立绘在画布上的像素尺寸。tex 为空（还没画）时用占位尺寸。
func sprite_px(tex: Texture2D, who: String, slot_name: String) -> Vector2:
	var base := placeholder
	if tex != null:
		base = Vector2(tex.get_size())
	var s := slot(slot_name)
	var c := character(who)
	return base * maxf(float(s["scale"]), 0.01) * maxf(float(c["scale"]), 0.01)


## ---- 几何（编辑器和运行时共用，别各写一套） ----

## 把控件按「槽位 x + 像素尺寸 + 角色偏移」摆到画布上。
##
## 用锚点而不是绝对坐标：父容器尺寸一变，立绘自己跟着走，不用监听 resized。
## 锚点定在底边中点，所以 offset_bottom 是「脚离地多少」。
static func place(ctrl: Control, slot_x: float, px_size: Vector2, offset: Vector2) -> void:
	ctrl.anchor_left = slot_x
	ctrl.anchor_right = slot_x
	ctrl.anchor_top = 1.0
	ctrl.anchor_bottom = 1.0
	ctrl.offset_left = -px_size.x * 0.5 + offset.x
	ctrl.offset_right = px_size.x * 0.5 + offset.x
	ctrl.offset_top = -px_size.y + offset.y
	ctrl.offset_bottom = offset.y


## ---- 资源 ----

## 读贴图。路径为空或读不到都返回 null，调用方决定怎么降级。
static func load_texture(p: String) -> Texture2D:
	if p == "" or not ResourceLoader.exists(p):
		return null
	var res := ResourceLoader.load(p)
	if res is Texture2D:
		return res
	return null


## 生成占位色块。没画立绘也能先把流程和站位跑通，这是灰盒阶段的主要用法。
static func make_placeholder(size_px: Vector2i, tint: Color) -> Texture2D:
	var w := maxi(size_px.x, 2)
	var h := maxi(size_px.y, 2)
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(tint)
	# 画一圈深色边框，让轮廓和背景分得开
	var edge := tint.darkened(0.45)
	for x in w:
		img.set_pixel(x, 0, edge)
		img.set_pixel(x, h - 1, edge)
	for y in h:
		img.set_pixel(0, y, edge)
		img.set_pixel(w - 1, y, edge)
	return ImageTexture.create_from_image(img)


## ---- 内部 ----

## pose -> default -> 空（空只用来让 chara_path 提前返回）
func _pose_chain(pose: String) -> Array[String]:
	var chain: Array[String] = []
	var p := pose.strip_edges()
	if p != "":
		chain.append(p)
	if p != "default":
		chain.append("default")
	return chain


static func _to_vec2(v: Variant) -> Vector2:
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO


static func _to_vec2i(v: Variant) -> Vector2i:
	if v is Array and (v as Array).size() >= 2:
		return Vector2i(int(v[0]), int(v[1]))
	return DEFAULT_CANVAS

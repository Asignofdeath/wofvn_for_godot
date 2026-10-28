## .script.txt 的着色。逐字符扫，不用 CodeHighlighter。
##
## 为什么不用 CodeHighlighter：它的关键词表按「ASCII 标识符」分词，
## `[背景：教室]` 里的中文既不在符号表里、也不被当成标识符，
## add_keyword_color("背景") 永远不会命中（实测整行不变色）。
## add_color_region 更不行——它要求起止是「符号」（单字符在符号表里），
## 全角「」不在其中，调用直接报错。
##
## 所以这里自己扫：一次只认五种片段，够用且没有歧义。
## 只影响显示，不参与任何解析；删掉它只是没颜色。
@tool
extends SyntaxHighlighter

const T := preload("res://addons/vn/editor/vn_theme.gd")
const Emitter := preload("res://addons/vn/editor/dsl/dsl_emit.gd")

## 被着色的那个文本框。反向引用只是为了读当前行内容，
## 比继承里唯一能拿到文本的 get_text() 更直接（后者在 4.7 上语义不明确）。
var _code: TextEdit

## 指令关键词。加一条指令，表里多一行，这里自动跟上。
var _kw: PackedStringArray = PackedStringArray()


func _init() -> void:
	for s in Emitter.SNIPPETS:
		var kw := String(s["kw"])
		if kw != "" and not _kw.has(kw):
			_kw.append(kw)


func bind(code: TextEdit) -> void:
	_code = code


func _get_line_syntax_highlighting(line: int) -> Dictionary:
	var out: Dictionary = {}
	if _code == null:
		return out
	var text := _code.get_line(line)
	if text.is_empty():
		return out

	# 整行注释：一律压到最弱
	if text.strip_edges().begins_with("#"):
		out[0] = {"color": T.FAINT}
		return out

	# 说话人：`凛：「…」` 里冒号前的名字加粗强调
	var colon := text.find("：")
	if colon > 0 and text.find("「", colon) == colon + 1:
		var start := 0
		while start < colon and (text[start] == " " or text[start] == "\t"):
			start += 1
		out[start] = {"color": T.ACCENT, "bold": true}

	# 行首 `- ` 是选项正文标记
	var stripped := text.strip_edges()
	if stripped.begins_with("-"):
		var dash := text.find("-")
		out[dash] = {"color": T.ACCENT}

	var n := text.length()
	var i := 0
	while i < n:
		var ch := text[i]
		if ch == "#":
			out[i] = {"color": T.FAINT}
			break
		if ch == "[":
			var close := text.find("]", i)
			if close < 0:
				close = n
			out[i] = {"color": T.FAINT}
			# 关键词取到冒号为止（`[停顿1.5s]` 没有冒号，整段跟着染色）
			var kw_end := close
			var c := text.find("：", i)
			if c >= 0 and c < close:
				kw_end = c
				out[c] = {"color": T.FAINT}
			if kw_end > i + 1:
				out[i + 1] = {"color": T.ACCENT}
			if close < n:
				out[close] = {"color": T.FAINT}
			i = close + 1
			continue
		if ch == "「":
			var q := text.find("」", i + 1)
			out[i] = {"color": T.SCRIPT}
			i = (q + 1) if q >= 0 else n
			continue
		i += 1
	return out

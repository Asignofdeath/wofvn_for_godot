# 剧本 DSL

> 用空行表达「顺序 / 并行」，编译成普通 GDScript 协程。

---

## 1. 产物

输入是 `.script.txt`，输出是一份普通章节脚本：`extends Node` + `signal finished` + `play()`。和手写剧本放在一起，`StoryRunner` 分不出来谁生成的。

```gdscript
## 由 VN 剧本编译器生成，请勿手改。
func play() -> void:
	VNKit.bg(self, "教室", 0.4)
	await VNKit.say(self, "凛", "你还没走？")
	finished.emit()
```

它能省掉的活：并行演出要拆 Signal、选项要手搓 `match`、判断要手抄 `get_param`。

产物跟着项目走，编译器不跟：删掉 `addons/vn/`，`.gd` 照样解析（只是调不到 `VNKit`）。

---

## 2. 边界

| 判据 | 结果 |
|---|---|
| **可删性** | 生成物是 `.gd`；删掉 `addons/vn/` 仍能解析，只是调不到 VNKit |
| **可绕过性** | 手写 `.gd` 完全等价，编译器不提供任何独占能力 |
| **可替换性** | 不动四组契约，不新增资源类型，不引入 autoload |

代价：

- 多一步编译；
- 源文件与产物两份，改错地方会白改；
- 手改产物会被覆盖保护拦住。

出现下面任何一条，它就不再是编译器了：

1. **指令要注册**——`register("xxx", func)` 那是解释器。
2. **能写 `label` / `jump` / `while`**——那就图灵完备了，手写 `.gd` 更合适。
3. **生成了 `VNKit` 没有的东西**——指令集与 `VNKit` 方法一一对应，否则产物离开插件就跑不了。

---

## 3. 语法

只有四条规则。

| 规则 | 写法 |
|---|---|
| 一拍 | 空行分隔 |
| 台词 | `角色：「内容」` |
| 指令 | `[名称：参数]` |
| 块 | `[选择项：…` / `[判断：…`，`]` 单独一行收尾 |

### 空行 = 分拍；不空行 = 同一拍

同一行段（中间没有空行）= 同一拍 = 玩家的一次点击。
**一拍里所有动作立即启动，但只有台词和停顿会被等待**——
背景 / 立绘启动后不等，淡入继续放，剧情照走。

> 本节语义的唯一 oracle 是 Web 版运行时
> `GameProject/_template/js/engine.js` 的 `_runStep`（:456）与 `BLOCKING` 集合（:4）。
> 本文档只是它的转述；两者冲突时以 engine.js 为准，改的是文档。

```
[背景：教室 — 淡入：0.8]
[立绘：凛 @中 — 表情：平静]

凛：「你还没走？」
```

第一拍背景和立绘一起启动（不等淡入完）；第二拍出字幕，等点击。
想让背景完全淡入后再出字幕，中间加一行 `[停顿0.8]`。

三条规则：

- **同一拍里两句台词会报错**——两个对话框同时弹会互相覆盖，前一句永远看不到。Web 版对此静默覆盖，这里有意收紧；
- **选择项和判断各占一拍**——它们是结构，不是动作；
- **参数是同步语句**——瞬间生效，不参与等待。

台词和动作可以写在同一拍（很常见）：

```
[背景：教室]
凛：「换个地方说话。」
```

背景淡入和字幕同时出现，点一下进下一拍。

### 指令表

| DSL | 生成 | 说明 |
|---|---|---|
| `[背景：教室]` | `VNKit.bg(self, "教室", 0.4)` | 默认淡入 0.4；不带 `await`，淡入在后台放 |
| `[背景：教室 — 淡入：0.8]` | `VNKit.bg(self, "教室", 0.8)` | |
| `[立绘：凛 @中 — 表情：平静]` | `VNKit.sprite(self, "凛", "平静", "center", 0.2)` | 槽位：左/中/右；同样不 `await` |
| `[立绘：凛 @左 — 表情：微笑 — 淡入：0.4]` | `VNKit.sprite(self, "凛", "微笑", "left", 0.4)` | |
| `[参数：affection +5]` | `VNKit.add_param(self, "affection", 5)` | 增减用数字 |
| `[参数：affection = 10]` | `VNKit.set_param(self, "affection", 10)` | 值可是数字/字符串/布尔 |
| `[停顿1.5s]` | `get_tree().create_timer(1.5).timeout` | 引擎原生，不经插件 |
| `[跳转章节：第二章]` | `finished.emit()` + `return` | **去哪一章由导图决定** |

### 选择项

选项下面直接跟正文，不要求缩进；下一个 `- ` 或 `]` 结束当前选项。

```
[选择项：怎么回答？
- 我在等你。
  凛：「……笨蛋。」
- 只是忘了时间。
]
```

选项里的正文可以和外面一样写拍、写判断，任意嵌套。

### 判断

```
[判断：好感 >= 50
凛：「受欢迎呢。」
- 否则判断：好感 >= 20
凛：「还行。」
- 否则
凛：「再努力吧。」
]
```

条件只支持 `变量 运算符 值`（`== != >= <= > <`）。
变量自动翻成 `VNKit.get_param(self, "好感", 0)`，兜底值按比较值的类型给（数字 `0`、浮点 `0.0`、字符串 `""`、布尔 `false`）。

条件只支持单个比较。`且` / `或` 暂不支持——允许任意表达式，编译器就要背一个求值器，那就成了第二个程序。

---

## 4. 生成示例

输入：

```
[背景：教室]
[立绘：凛 @中 — 表情：平静]

凛：「你还没走？」

[选择项：怎么回答？
- 我在等你。
  [参数：affection +5]

  凛：「……笨蛋。」
- 只是忘了时间。
  凛：「那就快点。」
]
```

输出：

```gdscript
func play() -> void:
	VNKit.bg(self, "教室", 0.4)
	VNKit.sprite(self, "凛", "平静", "center", 0.2)

	await VNKit.say(self, "凛", "你还没走？")

	var _picked0 := await VNKit.choice(self, ["我在等你。", "只是忘了时间。"])
	match _picked0:
		0:
			VNKit.add_param(self, "affection", 5)
			await VNKit.say(self, "凛", "……笨蛋。")
		1:
			await VNKit.say(self, "凛", "那就快点。")

	finished.emit()
```

（上面按书写顺序排版便于阅读；实际产物里背景、立绘是裸调用、不带 `await`，
且台词排在动作**之后**——非阻塞动作必须先生成，
否则排在 `await` 台词后面的背景要等玩家点击后才启动。）

### 为什么背景不被 await

对齐 Web 版 `engine.js` 的 `_runStep`：同一拍所有命令立即启动，
但只有 `BLOCKING` 集合（`say` / `wait` / `effect` / `choice`…）里的命令会被
`Promise.all(blockers)` 等待。`bg` / `sprite` 不在集合里——**启动了就不等**。
所以 `[背景：教室 — 淡入：0.8]` 单独一拍时，下一拍立刻开始，
背景还在淡；想等它淡完，加 `[停顿0.8]`（对应 engine.js 的 `wait`，是阻塞类）。

多个阻塞动作同拍（台词 + 停顿）时才需要合流：

```gdscript
var _wait0 := get_tree().create_timer(1.5).timeout
var _wait1 := VNKit.say(self, "凛", "……")
await VNKit.join(self, [_wait0, _wait1])
```

`VNKit.join` 对应 engine.js 的 `Promise.all(blockers)`，只做信号合流，
不持有状态、不进场景树。

为什么不能「逐个 await」：`Tween.finished` 只发一次。
先完成的那个在后一个 `await` 时早已发过，再去 await 会**永久挂起**，
所以必须一次监听全部信号。它是**协程**（返回 `void`）而非返回 Signal 的工厂：
计数器必须留在协程栈上，否则 `RefCounted` 在 `await` 挂起时就被回收
（第一版写成返回 Signal，被 `tools/test_join.gd` 当场抓出来）。

---

## 5. 错误与保护

- 所有错误都带 `.script.txt` 的行号，不是生成物的行号；
- 编译失败不写盘，旧产物原样保留；
- 覆盖保护两道：
  1. 目标不是本编译器生成的（没有头标记）→ **绝不覆盖**手写剧本；
  2. 产物正文被手改过（头里的产物哈希对不上）→ 拒绝覆盖，`force` 才放行。

产物头四行：

```
## 由 VN 剧本编译器生成，请勿手改。
## 源文件：res://story/ch01.script.txt
## 源哈希：8060a9dc3a3a
## 产物哈希：0d5953e63a33
```

---

## 6. 用法

```bash
# 批量编译一个目录（默认 res://story）
godot --headless --path . --script res://tools/compile_dsl.gd -- res://demo/story
```

代码里：

```gdscript
var r := VNDslCompiler.compile_file("res://story/ch01.script.txt", "res://story/ch01.gd")
if not r["ok"]:
	for e in r["errors"]:
		push_error(e)
```

`compile_text()` 不碰磁盘，面板预览和测试都走它。

---

## 7. 还没接的

| 项 | 状态 |
|---|---|
| 循环 | 暂不支持。VN 里少见，有 `if` 就够；真需要就手写 `.gd` |
| 段内跳转 / `label` | 暂不支持。段间归导图，段内是嵌套结构，用不上 |
| 立绘消失 / 音效 / 动画 / 画面效果 | `VNKit` 还没包这些动作，所以这里也写不了。在那之前这段手写 `.gd`，或先在生成物里补一行；包成 `VNKit` 方法之后，DSL 跟着加 |
| 场景块 | 识别后忽略并给 warning（Godot 侧没有标题横幅动作） |
| 复合条件 | 见 §3 |
| 双向同步 | 不做。生成物是产物，不是另一个源。要改就改 `.script.txt` |

---

## 8. 文件与测试

| 文件 | 职责 |
|---|---|
| `addons/vn/editor/dsl/dsl_parser.gd` | 行 → 结构树，不认识动作 |
| `addons/vn/editor/dsl/dsl_emit.gd` | 结构树 → GDScript 文本，纯函数；指令片段表 `SNIPPETS` 也在这里 |
| `addons/vn/editor/dsl/dsl_compile.gd` | 管线 + 磁盘 + hash 保护 |
| `addons/vn/editor/dsl/dsl_screen.gd` | 剧本面板（编辑 + 反馈）。删掉它，下面全部照常工作 |
| `addons/vn/editor/dsl/dsl_highlighter.gd` | `.script.txt` 着色。只是显示，删掉只是没颜色 |
| `tools/compile_dsl.gd` | 命令行批量编译 |
| `tools/test_dsl.gd` | 解析 / 生成 / 语法 / 覆盖保护 / 指令表 |
| `tools/test_screen.gd` | 面板的插入模板与光标落点（headless，不测画出来的样子） |

```bash
godot --headless --path . --script res://tools/test_dsl.gd
godot --headless --path . --script res://tools/test_screen.gd
```

---

## 9. 剧本面板靠什么保持可删

面板（`dsl_screen.gd`）是视图。Godot 没有能编辑 `.script.txt` 的界面（它不是可导入资源），这是补缺，不是替代（对照：立绘摆位器替代了更好的 2D 视图，所以删了）。

三条都可以当场验证：

| # | 约定 | 具体做法 | 怎么验 |
|---|---|---|---|
| 1 | **零草稿层** | 缓冲区就是文件内容，编译前一定先落盘；面板不写任何「已保存但没进文件」的私有副本 | 关掉面板，未保存的改动就该消失 |
| 2 | **不提供独占能力** | 没有「只有面板才能编译 / 跳错 / 预览」的功能，命令行 `compile_dsl.gd` 等价 | 删掉 `dsl_screen.gd`，全量编译产物逐字节相同 |
| 3 | **不增加 DSL 的语义** | 按钮只做「在光标处插入文本」，插的模板全部来自 `dsl_emit.gd` 的 `SNIPPETS`，并且每条 `sample` 都被测试编译过 | `test_dsl.gd` 里「每条片段都能编译」那组用例 |

第 3 条是结构性的，不靠自觉：按钮、补全候选、错误文案里那句「当前支持：…」**三处都从 `SNIPPETS` 派生**。所以「界面里有个按钮，但编译器不认」这件事不可能发生；反过来说，**要在界面上加一个动作，必须先让它成为 DSL 指令**，而不是先做个按钮。

### 编辑器原生能力直接用

打字、换行、缩进、撤销/重做、多光标、中文 IME、行号、补全弹窗的控件本身，都是 `CodeEdit` 现成的，**一行都不自己实现**。自己写的只有与 DSL 语义绑定的那层：插入模板的光标落点、补全候选、错误行标色、当前拍的生成预览。

# VN Toolkit for Godot 4

Godot 的 VN 工具集，附一份可 F5 运行的项目模板。插件是可选工具箱，删掉不影响项目启动。

工程形态 = **项目模板 + 插件（可选工具箱）+ 代码库**：`addons/vn/` 是插件，也是代码库（发布边界）；`demo/` 是模板（能 F5 跑的最小 VN 骨架）；`tools/` 是回归脚本。**都是本工程的交付内容**，都要维护。

> **工具箱现状：导图（章节路由）、剧本 DSL 编译器。** 全部条目见文末「进度」。
> 立绘摆位曾做成工具，已删：摆放是 Godot 2D 视图的强项，重做只会更差。见 [docs/DESIGN.md](docs/DESIGN.md)。

---

## 它是什么

| | |
|---|---|
| 解决的问题 | VN 的流程（这一段播完接哪一段）在纯代码里写会很快变成一片 `if`，看不见全貌 |
| 提供的方案 | 章节级路由图（JSON）+ GraphEdit 编辑器 + 可选路由器节点 |
| 交给引擎原生的 | 布局 / 摆位用 Godot 的 2D 视图；运行时框架、UI 组件库、剧本 DSL **运行时**、项目管理面板都不在范围内 |

剧本仍然是 `.gd` 协程：

```gdscript
extends Node
signal finished

func play() -> void:
	VNKit.bg(self, "教室", 0.8)
	VNKit.sprite(self, "凛", "平静", "center", 0.4)
	await VNKit.say(self, "凛", "你还没走？")

	var picked: int = await VNKit.choice(self, ["我在等你。", "只是忘了时间。"])
	if picked == 0:
		VNKit.add_param(self, "affection", 5)

	finished.emit()
```

背景和立绘不 `await`——启动就往下走，淡入在后台放；台词要 `await`，等玩家点击。想等淡入结束，就自己 `await` 它的返回值，两种写法都合法。

图只回答「下一段是谁」，脚本回答「这一段怎么演」。两者互不知道对方存在。

---

## 八条禁止线

出现任意一条，说明它已经开始变成框架，该停下来看是哪一步走偏了。

1. 用户代码必须 `extends` 插件的某个基类才能跑
2. 插件引入 autoload / 全局单例
3. 使用前必须「向注册表登记」角色 / 图层 / 资源
4. 插件的资源格式成为唯一真相（删掉插件，项目打不开）
5. 游戏必须「跑在」插件的某个节点里（路由器当根节点）
6. 图里能表达循环或任意逻辑（图灵完备倾向）
7. 加一个新玩法必须先扩展插件的指令集或节点类型
8. 编辑器里出现「项目管理」式总入口面板

### 终极验收

删掉 `addons/vn/` 之后，项目仍然是能跑的 Godot 游戏。已验证：

```
$ mv addons/vn /tmp/ && godot --headless --path .
ERROR: res://demo/stage.tscn:167 - Parse Error: [ext_resource] referenced non-existent resource at: res://addons/vn/core/story_runner.gd.
[Stage] ready
```

进程不崩、场景正常加载。代价是场景里那个 `StoryRunner` 节点失去脚本，删掉它即可。模板依赖插件是应该的；插件不能依赖模板。

判据、踩过的坑、依赖方向、加功能前的五问 —— 见 [docs/DESIGN.md](docs/DESIGN.md)。两者冲突时以代码和测试为准。

---

## 快速开始

### 1. 拷插件

把 `addons/vn/` 整个拷进项目，在 项目设置 → 插件 里启用「VN Toolkit」。

顶部主屏幕会出现「VN」标签，里面两页：**导图**、**剧本**。

### 2. 实现三个协作节点

运行时呈现是**你的**：任意场景里放节点，加进对应的组，实现对应的方法。

| 组名 | 需要实现 | 用在哪 |
|---|---|---|
| `vn_stage` | `set_bg(id, fade) -> Signal`<br>`set_sprite(who, pose, slot, fade) -> Signal` | 背景、立绘 |
| `vn_dialogue_box` | `show_line(speaker, text) -> Signal` | 对话 |
| `vn_choice_box` | `present(options) -> int` | 选项 |

不需要继承任何基类，不需要注册。**不实现也能跑**，对应动作会降级为「等一帧然后跳过」，并在启动时警告缺了哪个。

不想从零写，就把模板里那三个节点拷走（`demo/ui/backdrop.gd`、`sprite_slot.gd`、`dialogue_box.gd`）——它们**不在** `addons/` 里，是模板的肉，不是插件的骨。想自己实现就整份无视，契约只认组名和方法名。

| 节点 | 进哪个组 | 干什么 |
|---|---|---|
| `VNBackdrop` | `vn_stage` | 两层背景交叉淡入 + 缺图降级。**不算坐标**，anchors 决定多大 |
| `VNSpriteSlot` | —（槽位，不是契约节点） | 一块矩形里站一个角色。`@tool` 让编辑器里直接看见立绘 |
| `VNDialogueBox` | `vn_dialogue_box` | 打字机 + 点击推进 |

背景和立绘都进 `vn_stage` 组是**合法的**：`VNKit` 找协作节点时会校验方法名，各找各的。见 [docs/STAGE.md](docs/STAGE.md)。

### 3. 写剧本 + 画图

- 剧本：一个 `extends Node` 的 `.gd`，有 `play()` 和 `signal finished`
- 图：`res://story/story_graph.json`，或在「VN · 导图」标签里点「＋ 片段」画出来
- 场景里放一个 `StoryRunner` 节点，把 `graph_path` 指向那份 JSON
- 立绘站位：在 `Slots` 下摆 `VNSpriteSlot` 节点（用 Godot 自己的 2D 视图，勾上 `preview_who` 就能看见立绘）

想少写代码，就在「VN · 剧本」标签里写 `.script.txt`，点「编译」生成同名 `.gd`（语法见 [docs/DSL.md](docs/DSL.md)）。**这层完全是可选的**：不打开面板，用任何编辑器写 `.script.txt` 再跑 `tools/compile_dsl.gd`，产物逐字节相同。

详细说明见 [docs/](docs/)。

---

## 契约速查

插件认的全部东西就是 **4 个组名 + 4 个方法签名**：

```
vn_stage         → set_bg(id, fade) / set_sprite(who, pose, slot, fade)
vn_dialogue_box  → show_line(speaker, text) -> Signal
vn_choice_box    → present(options) -> int
vn_story         → StoryRunner（可选的参数表持有者）
```

没有基类、没有注册表、没有自定义资源类型。这四个名字之外的任何东西都是你自己的。

---

## 目录

```
addons/vn/                  ← 发布边界，可整体拷到别的项目
├── vn_kit.gd               静态动作库（say / bg / sprite / choice / add_param / set_param / get_param / join）
├── plugin.cfg
├── core/
│   ├── story_graph.gd      图数据 + guard 求值（运行时可读，不依赖编辑器）
│   └── story_runner.gd     可选路由器节点
└── editor/
    ├── vn_editor_plugin.gd 插件入口，挂主屏幕（「导图」「剧本」两个标签）
    ├── vn_theme.gd         两个面板共用的配色与底板样式
    ├── flow_screen.gd      图编辑器面板（GraphEdit + 交互 + 契约探测）
    ├── graph_doc.gd        图的 JSON ↔ 内存，原子写
    └── dsl/
        ├── dsl_parser.gd   .script.txt → 结构树（不认识动作）
        ├── dsl_emit.gd     结构树 → GDScript 文本（纯函数 + 指令片段表）
        ├── dsl_compile.gd  管线 + 磁盘 + 覆盖保护（唯一碰 IO 的地方）
        ├── dsl_screen.gd   剧本面板（编辑 + 反馈；删掉它其他照常工作）
        └── dsl_highlighter.gd  .script.txt 着色（只是显示）

demo/                       ← 项目模板：能 F5 跑的最小 VN 骨架（工程组成内容）
├── stage.tscn / stage.gd   舞台根：把 set_sprite 分派到点位
└── ui/
    ├── backdrop.gd         VNBackdrop   背景层（vn_stage 组）
    ├── sprite_slot.gd      VNSpriteSlot 立绘点位（@tool 预览）
    ├── dialogue_box.gd     VNDialogueBox 对话框（vn_dialogue_box 组）
    └── choice_box.gd       选项框（vn_choice_box 组）

tools/                      ← 回归脚本
docs/                       ← 文档
```

工程由这几部分组成，都是交付物：**插件**（`addons/`，也是代码库）、**模板**（`demo/`）、**回归脚本**（`tools/`）、**文档**（`docs/`）。

模板要维护——打不开、脚本报错、引用缺失、跳转断裂都是真缺陷。规模以 `tools/smoke.gd` 能跑通完整分支为准；美术与文案不设要求。

---

## 测试

```bash
GODOT=/path/to/godot

# 运行时冒烟：走完 ch01 → ch02 → end
$GODOT --headless --path . --script res://tools/smoke.gd

# 换另一条分支（选项 1）
VN_PICK=1 $GODOT --headless --path . --script res://tools/smoke.gd

# 编辑器面板布局回归（模拟拖控制台分隔条等父容器改尺寸）
$GODOT --headless --path . --script res://tools/test_layout.gd

# 舞台呈现：接线 / 背景 / 立绘 / 对话框
$GODOT --headless --path . --script res://tools/test_stage.gd

# 剧本 DSL：解析 / 生成 / 生成物语法 / 覆盖保护 / 指令表
$GODOT --headless --path . --script res://tools/test_dsl.gd

# 剧本面板：插入模板、光标落点、默认值选中、脏标记（不测长相）
$GODOT --headless --path . --script res://tools/test_screen.gd

# 阻塞动作合流：等齐、不提前、不挂死（对应 engine.js 的 Promise.all）
$GODOT --headless --path . --script res://tools/test_join.gd

# 把目录里的 .script.txt 编译成同名 .gd
$GODOT --headless --path . --script res://tools/compile_dsl.gd -- res://demo/story
```

改布局或改编辑器面板后必须跑 `test_layout.gd`。它用 `VBoxContainer` 镜像编辑器的 `MainScreen`，在 8 种尺寸下断言面板撑满、画布等于面板减顶栏底栏。

改过模板的呈现节点后必须跑 `test_stage.gd`（33 项）。

---

## 进度

| 工具 | 状态 |
|---|---|
| **导图（章节路由）** | **完成**（图数据 + guard + 路由器 + 编辑器 + 校验） |
| **剧本 DSL 编译器** | **完成**（解析 / 生成 / 覆盖保护 / CLI / 剧本面板） |
| 立绘摆位 | **不提供**（摆放归 Godot 的 2D 视图；背景 / 立绘点位 / 对话框是模板自带的普通节点） |
| 动效 / 转场编辑器 | 未开始 |
| 存档 / 回退 | 未开始（rollback 粒度方案 A/B/C 未定） |
| 翻译抽取 | 未开始 |
| 音频调度（BGM 交叉淡入 / 语音） | 未开始，需新增 `vn_audio` 组 |

### 已知真缺口

**单入口。** `StoryRunner.start()` 只能从 `graph.entry` 开始播，无法指定起始片段。所以「读档直达第 5 章」「章节选择」目前做不到。改法是给 `start()` 加一个可选的起始片段参数，属于扩展接口。

**动作库偏薄。** 现在只有 `say / bg / sprite / choice / param`，外加 `join`（阻塞动作合流，对应 Web 版 engine.js 的 `Promise.all(blockers)`；手写也可以直接调）。`wait`、`hide_sprite`、`shake`、`bgm` 都没加——按 DESIGN.md 的规矩，同一个调用在真实剧本里写第三遍才提为方法。

---

## 文档

| 文件 | 内容 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | 三个判据、动作 vs 结构、依赖方向、加功能前的五问（含第 0 问）、踩过的坑 |
| [docs/CONTRACT.md](docs/CONTRACT.md) | 运行时契约：四个组的完整签名、Signal 语义、降级与自检 |
| [docs/GRAPH.md](docs/GRAPH.md) | 图数据格式：JSON 字段、guard 语法与限制、校验规则 |
| [docs/EDITOR.md](docs/EDITOR.md) | 图编辑器面板：每个按钮做什么、片段卡片怎么读、保存行为 |
| [docs/STAGE.md](docs/STAGE.md) | 模板里的呈现节点：`VNBackdrop` / `VNSpriteSlot` / `VNDialogueBox` / `ChoiceBox`，槽位=子节点 |
| [docs/DSL.md](docs/DSL.md) | 剧本 DSL：语法、指令表、拍语义（对齐 engine.js）、覆盖保护、还没接的项 |

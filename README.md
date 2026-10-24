# VN Toolkit for Godot 4

给通用游戏引擎补一块 VN 开发用的工具，**不是**做一个 VN 专属运行时。

> **当前只包含一个工具：VN 运行时流程组织。**
> 立绘摆位、动效编辑、存档、翻译抽取等都没有做，见文末「进度」。

---

## 它是什么

| | |
|---|---|
| 解决的问题 | VN 的流程（这一段播完接哪一段）在纯代码里写会很快变成一片 `if`，看不见全貌 |
| 提供的方案 | 一张章节级路由图（JSON）+ 一个 GraphEdit 编辑器 + 一个可选的路由器节点 |
| 不提供的 | 运行时框架、UI 组件库、剧本 DSL、指令系统、项目管理面板 |

剧本仍然是 `.gd` 协程：

```gdscript
extends Node
signal finished

func play() -> void:
	await VNKit.bg(self, "教室", 0.8)
	await VNKit.say(self, "凛", "你还没走？")
	await VNKit.sprite(self, "凛", "平静", "center", 0.4)

	var picked: int = await VNKit.choice(self, ["我在等你。", "只是忘了时间。"])
	if picked == 0:
		VNKit.add_param(self, "affection", 5)

	finished.emit()
```

图只回答「下一段是谁」，脚本回答「这一段怎么演」。两者互不知道对方存在。

---

## 八条禁止线

出现任意一条，说明它已经开始变成框架，必须停下重设计。

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
ERROR: res://demo/stage.tscn:19 - [ext_resource] referenced non-existent resource
[Stage] ready
```

进程不崩、场景正常加载。代价是场景里那个 `StoryRunner` 节点失去脚本，删掉它即可。**这是 demo 自己选择使用插件的结果，不是插件强制的。**

判据、越界信号、已裁决的边界、加功能前的五问 —— 见 [docs/DESIGN.md](docs/DESIGN.md)。那份文档是这份 README 的展开版；两者冲突时以 `DESIGN.md` 为准。

---

## 快速开始

### 1. 拷插件

把 `addons/vn/` 整个拷进项目，在 项目设置 → 插件 里启用「VN Toolkit」。

顶部主屏幕会出现「VN 图」标签。

### 2. 加三个协作节点

任意场景里放三个节点，加进对应的组，实现对应的方法：

| 组名 | 需要实现 | 用在哪 |
|---|---|---|
| `vn_stage` | `set_bg(id, fade) -> Signal`<br>`set_sprite(who, pose, slot, fade) -> Signal` | 背景、立绘 |
| `vn_dialogue_box` | `show_line(speaker, text) -> Signal` | 对话 |
| `vn_choice_box` | `present(options) -> int` | 选项 |

不需要继承任何基类，不需要注册。**不实现也能跑**，对应动作会降级为「等一帧然后跳过」，并在启动时警告缺了哪个。

### 3. 写剧本 + 画图

- 剧本：一个 `extends Node` 的 `.gd`，有 `play()` 和 `signal finished`
- 图：`res://story/story_graph.json`，或在「VN 图」面板里点「＋ 节点」画出来
- 场景里放一个 `StoryRunner` 节点，把 `graph_path` 指向那份 JSON

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
├── vn_kit.gd               静态动作库（say / bg / sprite / choice / param）
├── plugin.cfg
├── core/
│   ├── story_graph.gd      图数据 + guard 求值（运行时可读，不依赖编辑器）
│   └── story_runner.gd     可选路由器节点
└── editor/
    ├── vn_editor_plugin.gd 插件入口，挂主屏幕面板
    ├── flow_screen.gd      GraphEdit 图编辑器（面板 UI + 交互 + 契约探测）
    └── graph_doc.gd        JSON ↔ 内存，原子写

demo/                       ← 契约的可运行验证物，不属于项目开发范围
tools/                      ← 回归脚本
docs/                       ← 文档
```

`demo/` 只做到「能证明契约跑得通」的程度，不追求完整度，也不参与质量评审。

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
```

改布局或改编辑器面板后必须跑 `test_layout.gd`。它用 `VBoxContainer` 镜像编辑器的 `MainScreen`，在 8 种尺寸下断言面板与画布都等于父容器可用区域。

---

## 进度

| 工具 | 状态 |
|---|---|
| **VN 运行时流程组织** | **完成**（图数据 + guard + 路由器 + 编辑器 + 校验） |
| 立绘摆位器 | 未开始 |
| 动效 / 转场编辑器 | 未开始 |
| 存档 / 回退 | 未开始（rollback 粒度方案 A/B/C 未定） |
| 翻译抽取 | 未开始 |

### 已知真缺口

**单入口。** `StoryRunner.start()` 只能从 `graph.entry` 开始播，无法指定起始状态。所以「读档直达第 5 章」「章节选择」目前做不到。改法是给 `start()` 加一个可选的起始状态参数，属于扩展接口。

---

## 文档

| 文件 | 内容 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | **设计的底线**：三个判据、动作 vs 结构、DSL 化信号、依赖方向、加功能前的五问、裁决记录 |
| [docs/CONTRACT.md](docs/CONTRACT.md) | 运行时契约：四个组的完整签名、Signal 语义、降级与自检 |
| [docs/GRAPH.md](docs/GRAPH.md) | 图数据格式：JSON 字段、guard 语法与限制、校验规则 |
| [docs/EDITOR.md](docs/EDITOR.md) | 编辑器面板：每个按钮做什么、节点卡片怎么读、保存行为 |

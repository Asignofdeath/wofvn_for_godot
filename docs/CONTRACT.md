# 运行时契约

插件和你的游戏之间只有这一份约定。全部内容是 **4 个组名 + 4 个方法签名**。

没有基类、没有注册表、没有自定义资源类型。

---

## 查找方式

`VNKit` 每次调用时做两件事：

```gdscript
static func _find(host: Node, group: String, method: String) -> Node:
	if host == null or not host.is_inside_tree():
		return null
	for n in host.get_tree().get_nodes_in_group(group):
		if n != null and n.has_method(method):
			return n
	return null
```

1. 从 `host`（你传给 `VNKit.xxx()` 的第一个参数，通常是章节脚本自己）拿到场景树
2. 在整棵树里找**第一个**属于该组、**并且实现了要找的那个方法**的节点

然后调用它，把它返回的 `Signal` 交回去给你 `await`。

**这意味着：节点放在树的哪个位置都行，只要在同一个场景树里。** 不需要是 `host` 的子节点。

### 为什么按方法名挑，而不是只按组

同一个组允许放多个节点。典型情况：背景和立绘分属两个节点，都加进 `vn_stage`——
一个实现 `set_bg`，一个实现 `set_sprite`。只按组找的话，
`get_first_node_in_group()` 返回谁全看场景树顺序，等于靠运气；
按方法名挑之后，「一个组拆成几个节点」就变成合法用法，谁先谁后都不影响。

模板里的 `Stage` 根和 `Backdrop` 子节点就是这么用的。

> 同一个组的**同一个方法**仍然只能有一个实现。两个节点都实现 `set_bg` 时，先遍历到的那个生效。

---

## `vn_stage` — 背景与立绘

```gdscript
func set_bg(id: String, fade: float = 0.4) -> Signal
func set_sprite(who: String, pose: String, slot: String = "center", fade: float = 0.2) -> Signal
```

| 参数 | 说明 |
|---|---|
| `id` | 背景标识，由你定义（demo 里是 `"教室"` / `"夜晚"`） |
| `who` | 角色名。同一个 `who` 复用同一个立绘实例 |
| `pose` | 表情 / 姿态标识。**插件不解释它**，随你用在贴图切换、动画切换或忽略 |
| `slot` | 槽位标识。插件不限定取值；模板把它当「立绘点位的名字」用 |
| `fade` | 淡入时长（秒）。实现可以忽略它 |

**返回的 Signal 在「视觉上完成」后 emit。** 手写剧本可以 `await` 它，等淡入结束再往下；DSL 生成的不 `await`（对齐 Web 版 `engine.js`：`bg` / `sprite` 启动即继续，台词照出）。两种都合法。

```gdscript
await VNKit.bg(self, "教室", 0.8)                    # 手写：等淡入播完
VNKit.bg(self, "教室", 0.8)                          # 不等：淡入在后台放
await VNKit.sprite(self, "凛", "平静", "center", 0.4)
```

### 现成的实现（在模板里，不在 `addons/`）

契约只规定「组名 + 方法签名」，不规定实现。这几个节点是**模板的肉**——
它们不在 `addons/` 里，不是插件的一部分，想拷就拷，想无视就无视：

| 节点 | 文件 | 特点 |
|---|---|---|
| `VNBackdrop` | `demo/ui/backdrop.gd` | 两层背景交叉淡入，缺图降级为底色。**不算坐标** |
| `VNSpriteSlot` | `demo/ui/sprite_slot.gd` | 一块矩形站一个角色。`@tool`，编辑器里直接看见立绘 |
| `VNDialogueBox` | `demo/ui/dialogue_box.gd` | 打字机 + 两次点击推进 |
| `VNChoiceBox` | `demo/ui/choice_box.gd` | 按 `options` 现场生成按钮，返回选中下标 |

详情见 [STAGE.md](STAGE.md)。

**三者都可以整个删掉换自己的。** 你自己实现的节点甚至不必是 `Control`——
只要在组里、方法签名对得上，`Node` 再往下任何类型都行。

> **摆位不归插件管。** 立绘放在哪、多大，由 `VNSpriteSlot` 的 anchors 决定，用 Godot 自己的 2D 视图调。曾经做过一个「立绘摆位面板」，已删除——见 [DESIGN.md](DESIGN.md)。

---

## `vn_dialogue_box` — 对话

```gdscript
func show_line(speaker: String, text: String) -> Signal
```

| 参数 | 说明 |
|---|---|
| `speaker` | 说话人。空字符串表示旁白，实现里通常隐藏名字框 |
| `text` | 正文。可以含 BBCode（由你的实现决定） |

返回的 Signal 必须在**玩家看完这一句**后 emit：

```gdscript
await VNKit.say(self, "凛", "你还没走？")
# 玩家点击推进后才走到这里
```

`show_line` 返回的信号就是「这一句播完了」，插件不关心你怎么判定播完（点击、自动播放、语音结束）。

---

## `vn_choice_box` — 选项

```gdscript
func present(options: Array) -> int        # 协程返回值；await 它才拿到下标
```

| 参数 | 说明 |
|---|---|
| `options` | 选项文案数组，元素由你决定类型（demo 用 String，`present` 里 `str()` 转换） |

返回**选中项的下标**（从 0 开始）：

```gdscript
var picked: int = await VNKit.choice(self, ["我在等你。", "只是忘了时间。"])
if picked == 0:
	VNKit.add_param(self, "affection", 5)
```

`present()` 内部必须 `await` 到玩家做出选择再 `return`，否则 `VNKit.choice` 会拿到一个还没选完的值。

---

## `vn_story` — 参数表

由 `StoryRunner` 自己加进这个组。剧本通过 `VNKit` 读写，不需要知道 `StoryRunner` 这个类存在：

```gdscript
VNKit.add_param(self, "affection", 5)          # 数值累加
VNKit.set_param(self, "has_key", true)         # 直接赋值（flag 用这个）
var v = VNKit.get_param(self, "affection", 0)  # 读，第二参是缺省值
```

参数只能有四种类型：`int` / `float` / `flag`（bool）/ `string`。它们在图的 `params` 里声明，`guard` 只能读这些。

`add_param` 会按声明的类型归一化，`int` 参数加浮点数后仍然是 `int`。

---

## 找不到协作节点时会怎样

**不会中断游戏。** 每种动作有明确的降级行为：

| 动作 | 协作节点缺失时 |
|---|---|
| `say` | `push_error` + 等一帧然后返回（对白一闪而过） |
| `bg` | 同上 |
| `sprite` | 同上 |
| `choice` | `push_error` + **返回 0**（永远选第一项） |
| `add_param` / `set_param` | 只 `push_warning`，静默忽略 |
| `get_param` | 返回你给的缺省值，不报错 |

这样设计是为了让「只想先跑通剧情、UI 待补」的阶段不被卡住。

### 启动自检

`StoryRunner` 开播前会检查三个组，缺了一次列清：

```
WARNING: [StoryRunner] 缺少协作节点，用到时会跳过：
  - vn_dialogue_box（需要 show_line(speaker, text) -> Signal）
  - vn_choice_box（需要 present(options) -> int）
```

三组齐全时完全静默。

---

## 章节脚本的契约

放进图里的 `chapter` 片段，其脚本必须满足三条：

| 要求 | 检查方式 |
|---|---|
| 能 `new()` 出 Node | 「VN 图」面板会探测并标红 |
| 有 `play()` 方法 | 同上 |
| 有 `finished` 信号 | 同上 |

```gdscript
extends Node            # 任何 Node 派生类型都行
signal finished

func play() -> void:
	# 这一段的流程
	finished.emit()      # 必须 emit，否则整场永久挂住
```

`StoryRunner` 的跑法是：`new()` → `add_child()` → `play()` → `await finished` → `queue_free()`。所以：

- **每进入一个片段就新建一个脚本实例**，播完销毁
- 跨片段要保留的东西，放进参数表或你自己的存档，不要指望实例变量

---

## 怎么替换掉 demo 的实现

`demo/` 里的对话框、选项框、舞台只是契约的可运行证明。换成你自己的：

1. 新建一个 `Control`（或任何 `Node` 派生），实现上表里的方法
2. 加进对应组（编辑器右侧 Node 面板 → 群组，或 `add_to_group()`）
3. 把 `demo/` 里的文件删掉，或干脆整个 `demo/` 目录删掉

插件不会有任何察觉——它只认名字。

---

## 常见错误

| 症状 | 原因 |
|---|---|
| 剧情跑到某一章永久卡住 | 那一章的 `play()` 忘了 `finished.emit()` |
| 对白一闪而过 | 对话框没加进 `vn_dialogue_box` 组，或方法名拼错 |
| 选项永远选第一项 | 选项框缺失或 `present()` 没 `await` 就 `return` |
| `guard` 永远不命中 | 参数名拼错（编辑器会在问题条报「引用了未声明的参数」） |
| 背景停在旧图 / 不淡入 | `set_bg` 返回的信号在动画开始时就 emit 了，应在结束时 emit |

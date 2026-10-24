# 舞台节点

`VNSpriteStage` —— `vn_stage` 契约的**一个参考实现**。不是 UI 框架，不是必须用的舞台，也**不负责摆位**。

摆位归 Godot：在场景里拖 Control、设 anchors、按 F5 看。这个节点只补引擎没有的三件事：

| 补什么 | 为什么需要 |
|---|---|
| 两个契约方法 | `set_bg` / `set_sprite` 是鸭子类型接口，得有人实现 |
| 缺图占位 | 图还没画时用占位色块顶上，流程不阻断 |
| 两层背景交叉淡入 | 换景不先黑一下，是每个 VN 都要写两遍才写对的代码 |

不带美术资源，一张图都不进 `addons/`。

---

## 30 秒用法

```
VNSpriteStage (Control，铺满全屏)
├── left      (Control，自己摆 anchors)
├── center    (Control)
└── right     (Control)
```

1. 场景里放一个 `VNSpriteStage`，铺满你要显示的区域。
2. 底下建任意个 `Control` 当槽位，**节点名就是剧本里写的 `slot`**。位置、大小、锚点全用编辑器调。
3. 剧本里不用改：它 `_ready()` 时自己 `add_to_group("vn_stage")`。

```gdscript
await VNKit.bg(self, "教室", 0.4)
await VNKit.sprite(self, "凛", "平静", "center", 0.2)
```

一个槽位都不建也能用：立绘直接铺满整个舞台（单人场景的常见情况），并给一条警告。

不想用这个节点？删了，自己写：

```gdscript
extends Control
func _ready() -> void:
	add_to_group("vn_stage")
func set_bg(id: String, fade: float) -> Signal:
	return get_tree().process_frame
func set_sprite(who: String, pose: String, slot: String, fade: float) -> Signal:
	# 你的实现
	return get_tree().process_frame
```

---

## 属性

| 属性 | 默认 | 作用 |
|---|---|---|
| `chara_dir` | `res://art/chara` | 立绘目录约定 |
| `bg_dir` | `res://art/bg` | 背景目录约定 |
| `placeholder_size` | `(420, 700)` | 槽位尺寸还是 0 时，占位色块用多大 |

---

## 目录约定

```
res://art/
├── chara/
│   ├── 凛/
│   │   ├── default.png
│   │   └── 平静.png
│   └── 葵/
│       └── default.png
└── bg/
    ├── 教室.png
    └── 夜晚.png
```

找图顺序：**请求的 pose → `default` → 占位色块**，扩展名试 `png / webp / jpg / jpeg`。

找不到图时：按角色名取色的占位图 + 一条 `push_warning`，流程照常推进，`await` 时间不变。这就是灰盒阶段的正常用法。

**这是约定，不是注册表。** 没有导入流程、没有资源清单、没有必须登记的 id。

---

## 运行时行为

| 行为 | 说明 |
|---|---|
| 槽位 = 子节点 | `slot` 参数匹配子节点名；没有同名子节点就退回整个舞台并警告一次 |
| 立绘铺满槽位 | 立绘是槽位节点的子节点，`PRESET_FULL_RECT`，保持比例居中 |
| 一个槽位一个角色 | 后来者顶替先来者，被顶替的节点立刻移除 |
| 换槽位不重建 | 同一个 `who` 的节点 `reparent` 到新槽位，不重播淡入 |
| 换表情不闪 | 已经在台上的角色只换贴图 |
| 背景两层交替 | 淡入淡出交叉进行，不会先黑一下 |
| 两个方法都有返回值 | 返回 `Tween.finished`，`await` 它拿到的就是「真的走完」那一帧 |
| `set_bg("教室")` 两种传法 | 短名走 `bg_dir` 拼路径，`res://...` 完整路径直接用 |

`has_sprite(who)` / `sprite_node(who)` 是给项目自己用的查询，不属于契约。

---

## 想加一个角色消失？

契约里**没有** `hide_sprite`。现在能做的：

```gdscript
# 方案一：换场（set_bg 前自己清）
stage.sprite_node("凛").queue_free()

# 方案二：自己实现一个 hide 方法，自己调用
# 新增方法是兼容变更，但要不要进 VNKit 得先讨论——见 docs/DESIGN.md 的组名/方法数红线
```

**不要**指望某个「空 pose」或 `set_sprite("凛", "", ...)` 代表消失：那是隐式约定，下一个人看不懂。

---

## 和契约的边界

| | 状态 |
|---|---|
| 新增组名 | **没有**。只实现已有的 `vn_stage` |
| 改已有方法签名 | **没有**。`set_bg` / `set_sprite` 一字未动 |
| 必须用它 | **不必**。加组 + 实现两个方法的任何节点都能顶替 |
| 自建资源格式 | **没有**。没有任何 JSON/布局文件 |
| 算坐标 | **不算**。一个 position/size 都不写，全交给场景里的 anchors |
| 删掉它 | 场景里那个节点失去脚本，删掉节点即可；项目仍是普通 Godot 游戏 |

---

## 常见问题

| 现象 | 原因 |
|---|---|
| 立绘铺满全屏了 | 没有同名的槽位子节点，退回了舞台自身。在 `VNSpriteStage` 下建 `left` / `center` / `right` |
| 立绘大小不对 | 槽位节点的 `size` 就是立绘的框，用编辑器调它，不要指望代码缩放 |
| 两个角色只剩一个 | 它们被放到同一个槽位了，槽位互斥。给第二个角色换 `slot` |
| 换角色时闪一下 | 那个角色第一次出现，属于正常淡入 |
| 图明明在却不显示 | 大小写与目录层级：`chara/<角色>/<表情>.png`，表情名要和剧本里传的一字不差 |
| 想微调某张画的站位 | 有两种做法：调槽位节点的 anchors（所有用这个槽位的角色一起变），或给那张画单独留一个槽位。**不要**为它加偏移字段 |

---

## 测试

```bash
GODOT=/path/to/godot
$GODOT --headless --path . --script res://tools/test_stage.gd
```

覆盖 20 项：契约时序（`await` 之后必须真的可见）、槽位映射、槽位互斥、换槽位不重建、缺图降级、路径查找。

它**不测几何**——因为这里没有几何。

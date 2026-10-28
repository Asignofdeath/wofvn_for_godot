# 模板的三个呈现节点

`demo/ui/` 下的节点实现 `vn_stage`、`vn_dialogue_box`、`vn_choice_box` 三份契约。

**它们不是插件的一部分。** 它们在 `demo/`，不在 `addons/`。删了、改了、整份换掉，插件都察觉不到——契约只认组名 + 方法名。

共同点是都能在 Godot 编辑器里直接看见画面（`@tool`），不用按 F5。这是它们存在的理由，省代码是顺带的。

---

## 节点树

```
Stage          (Control，铺满)  ← demo/stage.gd，实现 set_sprite
├── Backdrop   (VNBackdrop)      ← vn_stage 组，实现 set_bg
├── Slots      (Control)
│   ├── left   (VNSpriteSlot)    ← 节点名就是剧本里的 slot
│   ├── center (VNSpriteSlot)
│   └── right  (VNSpriteSlot)
├── Dialogue   (VNDialogueBox)   ← vn_dialogue_box 组，实现 show_line
├── ChoiceBox  (Control)         ← vn_choice_box 组，实现 present
└── StoryRunner (Node)           ← 插件的可选路由器
```

`Stage` 和 `Backdrop` **都在 `vn_stage` 组里**，各实现一个方法。合法，因为 `VNKit` 按方法名找节点。见 [CONTRACT.md](CONTRACT.md) 的「为什么按方法名挑」。

---

## 三个节点

| 节点 | 管什么 | 不管什么 |
|---|---|---|
| `VNBackdrop` | 两层 TextureRect 交叉淡入；缺图降级为底色 | 位置、大小（anchors 决定） |
| `VNSpriteSlot` | 一块矩形里站一个角色；换表情不重播淡入；缺图占位 | 自己叫什么（节点名或 `slot_name`）、站哪 |
| `VNDialogueBox` | 打字机、两次点击推进（先补完、再放行） | 长什么样（子节点在场景里，随便改） |

### `VNBackdrop`

为什么它不能自己就是 `TextureRect`：交叉淡入需要两张图同时可见，一张 `TextureRect` 只有一个 `texture`，换图就是硬切，中间必然闪黑。

两层是 internal child（`Node.INTERNAL_MODE_FRONT`）：不出现在编辑器场景树面板里，也不会被存进 `.tscn`。

| 属性 | 默认 | 作用 |
|---|---|---|
| `bg_dir` | `res://art/bg` | 背景目录约定 |
| `preview_id` | 空 | **仅编辑器**：预览哪张背景。留空只显示底色 + 虚线框 |
| `base_color` | 暗色 | 没有背景图时的底色 |

### `VNSpriteSlot`

它不是契约节点。契约的 `set_sprite` 在舞台根上，根负责把角色分派到某个点位。

| 属性 | 默认 | 作用 |
|---|---|---|
| `slot_name` | 空 | 剧本里写的 slot 名。**留空就用节点名**（推荐留空，改名即改槽位） |
| `chara_dir` | `res://art/chara` | 立绘目录约定 |
| `preview_who` | 空 | **仅编辑器**：预览哪个角色。留空只画虚线框 + 点位名 |
| `preview_pose` | `default` | **仅编辑器**：预览哪个表情 |
| `stretch_mode` | `KEEP_ASPECT_CENTERED` | 贴图怎么填这块矩形 |

一个点位只站一个角色，后来者顶替先来者。要两人同屏就建两个点位。

### `VNDialogueBox`

子节点结构（`Panel` / `Name` / `Text` / `Hint`）写在 `demo/stage.tscn` 里，不在脚本里造。要改字体、圆角、位置，**改场景**，别改脚本。

两次点击模型：

| 状态 | 点击后 |
|---|---|
| 还在打字 | 立刻补完这一句，不放行 |
| 已经打完 | `emit line_finished`，剧本继续 |

### `ChoiceBox`

`demo/ui/choice_box.gd`，`class_name VNChoiceBox`，进 `vn_choice_box` 组，实现 `present(options) -> int`。

| 事项 | 说明 |
|---|---|
| 返回值 | 选中项下标，从 0 开始 |
| 按钮 | 按 `options` 现场生成，字号 28、高 68，容器是场景里的 `Center/List` |
| 选中之后 | 按钮设为不可见，框体隐藏，返回下标 |
| 再次调用 | 先清空上一批按钮，再生成新的 |
| 缺失时 | `VNKit` 打 `push_error` 并返回 0（永远第一项） |

和对话框一样是普通 `Control`：加组 + 实现方法就能顶替，甚至不必是 `Control`。

---

## 摆位怎么摆

**在 Godot 的 2D 视图里拖 `VNSpriteSlot`，一个坐标都不用写。**

1. 选中 `Slots/left`，在 Inspector 里调 anchors / offsets
2. 勾上 `preview_who`，填个角色名 → 编辑器里立刻显示立绘（没图就是占位色块）
3. 按 F5，同一块矩形就是运行时立绘的框

`preview_*` 只在 `Engine.is_editor_hint()` 下生效，运行时完全忽略，不会污染存档或逻辑。

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
| 背景两层交替 | 淡入淡出交叉进行，不会先黑一下 |
| 立绘铺满点位 | 立绘是点位的 internal 子节点，`PRESET_FULL_RECT` |
| 一个点位一个角色 | 后来者顶替先来者 |
| 换点位不留下分身 | `Stage` 遍历所有点位，把同一个 `who` 清空 |
| 换表情不闪 | 已经在台上的角色只换贴图，不重播淡入 |
| 点位名对不上 | 退回第一个点位并警告一次，不中断剧情 |
| 两个方法都有返回值 | 返回 `Tween.finished`，`await` 它拿到的就是「真的走完」那一帧 |
| `set_bg("教室")` 两种传法 | 短名走 `bg_dir` 拼路径，`res://...` 完整路径直接用 |

---

## 和契约的边界

| | 状态 |
|---|---|
| 新增组名 | **没有**。只实现已有的 `vn_stage` / `vn_dialogue_box` |
| 改已有方法签名 | **没有**。一字未动 |
| 必须用它们 | **不必**。加组 + 实现方法的任何节点都能顶替，甚至不必是 `Control` |
| 自建资源格式 | **没有**。没有任何 JSON/布局文件 |
| 算坐标 | **不算**。一个 position/size 都不写，全交给 anchors |
| 在 `addons/` 里 | **不在**。属于模板，不属于发布边界 |
| 删掉它们 | 项目仍是普通 Godot 游戏，只是失去这层呈现 |

---

## 常见问题

| 现象 | 原因 |
|---|---|
| 立绘跑到画面外/尺寸不对 | 点位的 anchors / offsets 不对，用 2D 视图调它，不要指望代码缩放 |
| 编辑器里看不见立绘 | `preview_who` 留空了。填上角色名（没图也会显示占位色块） |
| 改了点位名但剧本还走老名字 | 剧本里的 `slot` 参数是字面量，改节点名要同步改剧本 |
| 两个角色只剩一个 | 它们被放到了同一个点位。给第二个角色换 `slot` |
| 换角色时闪一下 | 那个角色第一次出现，属于正常淡入 |
| 图明明在却不显示 | 大小写与目录层级：`chara/<角色>/<表情>.png`，表情名要和剧本里传的一字不差 |
| 想微调某张画的站位 | 调点位的 anchors（这个点位上的所有角色一起变），或给它单独开一个点位。**不要**为它加偏移字段 |
| 对话框字体不对 | `stage.gd` 的 `_apply_cjk_theme()` 用的是系统字体，发布前换成项目内 `FontFile` |

---

## 测试

```bash
GODOT=/path/to/godot
$GODOT --headless --path . --script res://tools/test_stage.gd
```

覆盖 33 项：接线（同组两节点靠方法名各找各的）/ 背景时序与降级 / 点位分派与顶替 / 换表情不重播淡入 / 对话框契约 / internal child 不污染子节点列表。

它**不测几何**——因为这里没有几何，摆位是场景数据，不是代码。

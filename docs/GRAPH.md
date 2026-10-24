# 图数据格式

一张图 = 一份 JSON。**存 JSON 不存 `.tres`**，因为要能手改、能 git diff、字段变了迁移便宜。

---

## 完整示例

```json
{
	"version": 1,
	"entry": "ch01",
	"params": {
		"affection": { "label": "好感", "type": "int", "default": 0 },
		"has_key":   { "label": "拿到钥匙", "type": "flag", "default": false }
	},
	"states": [
		{ "id": "ch01", "type": "chapter", "chapter": "res://story/ch01.gd", "pos": [80, 180] },
		{ "id": "ch02", "type": "chapter", "chapter": "res://story/ch02.gd", "pos": [420, 180] },
		{ "id": "end",  "type": "end",     "chapter": "",                     "pos": [760, 180] }
	],
	"transitions": [
		{ "from": "ch01", "to": "ch02", "guard": "affection >= 5", "priority": 1 },
		{ "from": "ch01", "to": "end",  "guard": "",               "priority": 2 },
		{ "from": "ch02", "to": "end",  "guard": "",               "priority": 1 }
	]
}
```

---

## 字段

### 顶层

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `version` | int | 否 | 默认 `1` |
| `entry` | string | **是** | 起始片段 id。缺失或指向不存在的片段都是错误 |
| `params` | object | 否 | 参数表，见下 |
| `states` | array | 否 | 片段列表（键名沿用 `states`，不改，老文件才读得回来） |
| `transitions` | array | 否 | 边列表 |

### `params.<id>`

| 字段 | 说明 |
|---|---|
| `label` | 显示名。**中文放这里** |
| `type` | `int` / `float` / `flag`（或 `bool`）/ `string`，缺省 `int` |
| `default` | 初始值，按 `type` 转换 |

**参数 id 必须是 ASCII 标识符**（`affection`、`has_key`）。因为 `guard` 用 Godot 的 `Expression` 求值，它不支持中文标识符。中文写在 `label` 里。

### `states[]`

| 字段 | 说明 |
|---|---|
| `id` | 唯一标识。同时是编辑器里片段卡片的节点名（会自动做 `validate_node_name()`，非法字符不会破坏连线） |
| `type` | `chapter` 或 `end`，缺省 `chapter` |
| `chapter` | 章节脚本路径。`end` 类型不需要 |
| `pos` | `[x, y]`，**只给编辑器用，运行时忽略** |

### `transitions[]`

| 字段 | 说明 |
|---|---|
| `from` | 源片段 id |
| `to` | 目标片段 id |
| `guard` | 条件表达式，空字符串 = 恒真（默认边） |
| `priority` | 数字，**小的先命中**。同 priority 按文件里的书写顺序 |

**`_raw` 字段（仅内存）**：编辑器载入时会把每个 state / transition 的原始字典存进 `_raw`，保存时以它为底板，所以你在 JSON 里手加的额外字段（备注、颜色、自定义标记）不会丢。落盘时不会写出 `_raw` 本身给别人看——它会被展开回原字段。

---

## `guard` 语法

用 Godot 的 `Expression` 求值，输入只有参数表里的 id。

### 能写的

```text
affection >= 5
has_key and affection > 3
not has_key
affection >= 5 or has_key
min(affection, 10) > 6          # 函数调用允许
```

### 不能写的

| 写法 | 结果 |
|---|---|
| 访问场景 / 节点 / autoload | 词法白名单直接报错 |
| 调用你自己的函数 | 会被当作未声明标识符报错 |
| 中文标识符 | `Expression` 不支持 |
| 赋值、多条语句 | `Expression` 只接受单个表达式 |

### 词法白名单

`Expression.parse()` 有个坑：**它会放过未声明的标识符**。参数名拼成 `affecton`，解析成功、编译成功，但运行时那个输入永远拿不到值，于是这条边**永远静默不命中**——没有任何报错。

所以 `StoryGraph` 在编译前先做一遍词法扫描：

1. 剥掉字符串字面量内容（避免把 `"affection"` 里的词当标识符）
2. 用正则抓出所有 `[A-Za-z_][A-Za-z0-9_]*`
3. 允许三类：参数表里有的、字面量关键字（`true` / `false` / `null` / `PI` / `TAU` / `INF` / `NAN`）、后面紧跟 `(` 的（函数调用）
4. 其余全部报错

所以拼错参数名会在打开图的时候就被抓出来，而不是等到运行时发现分支不走。

---

## 运行时怎么用这张图

`StoryRunner` 的主循环：

```text
id = entry
loop:
    进入片段 id，emit state_entered
    如果是 end → 结束
    await 章节的 play() / finished
    按 priority 升序找第一条 guard 为真的边
    没有可走的边 → push_error 并停止
    id = 那条边的 to
    超过 1000 跳 → 判定死循环，强制停止
```

关键点：

- **一条边都没有并且不是 `end`** → 运行时直接停止（编辑器里报「死路」警告）
- **gurad 全为假** → 同样停止（编辑器查不出来，因为它是数据相关的）
- **A → B → A** 是允许的（会正常循环播放，由 `MAX_HOPS` 兜底）
- **A → A** 被编辑器直接判为错误

---

## 校验规则

打开或保存图时，编辑器会用 `StoryGraph` 全量校验一遍，结果进底部问题条。

### 错误（图不能跑）

| 消息 |
|---|
| `states 里出现非对象项` |
| `有片段缺少 id` |
| `片段 id 重复：<id>` |
| `transitions 里出现非对象项` |
| `guard 引用了未声明的参数：<word>（guard: <expr>）` |
| `guard 无法解析：<expr>（<原因>）` |
| `缺少 entry` |
| `entry 指向不存在的片段：<id>` |
| `transition 的 from 不存在：<id>` |
| `<from> -> <to>：目标片段不存在` |
| `<id> -> <id>：自己指向自己，会无限循环` |

### 提示（能跑，但可能是没写完）

| 消息 | 触发条件 |
|---|---|
| `片段 <id> 还没指定章节脚本（草稿态）` | `type` 是 `chapter` 但 `chapter` 为空 |
| `片段 <id> 是死路（没有任何出边）` | 非 `end` 且没有出边 |
| `片段 <id> 不可达（没有入边）` | 不是 `entry` 且没有任何入边 |

「草稿态」被降级成提示而不是错误，是为了让你可以先画骨架再填内容。

---

## 手改这份 JSON 要注意

1. **`entry` 不能忘**，缺了整张图不启动
2. **参数 id 只写 ASCII**，中文放 `label`
3. **`chapter` 路径写 `res://` 开头的完整路径**
4. **`pos` 随便写**，打开图后拖一下片段就会按实际位置更新
5. 编辑器保存是**原子写**（先写 `.vntmp` 再改名），写到一半崩溃不会毁掉原文件

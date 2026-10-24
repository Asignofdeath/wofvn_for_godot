## 第一章。剧本即代码：await 一个动作就是「停在这里等它做完」。
##
## 注意这里没有 extends 任何插件基类。Runner 只认两件事：
## 有 play()，有 finished 信号。缺了插件，这段代码仍然是普通 Godot 脚本。
extends Node

signal finished


func play() -> void:
	await VNKit.bg(self, "教室", 0.8)
	await VNKit.say(self, "旁白", "放学后的教室，只剩下夕阳和粉笔灰。")
	await VNKit.sprite(self, "凛", "平静", "center", 0.4)
	await VNKit.say(self, "凛", "你还没走？")

	var picked: int = await VNKit.choice(self, ["我在等你。", "只是忘了时间。"])
	if picked == 0:
		VNKit.add_param(self, "affection", 5)
		await VNKit.say(self, "凛", "……笨蛋。")
	else:
		await VNKit.say(self, "凛", "那就快点。")

	finished.emit()

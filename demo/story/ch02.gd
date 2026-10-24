## 第二章。同样不继承任何东西。
extends Node

signal finished


func play() -> void:
	await VNKit.bg(self, "夜晚", 0.8)
	await VNKit.say(self, "旁白", "天黑了。教室里只剩两个人。")
	await VNKit.sprite(self, "凛", "微笑", "left", 0.4)
	await VNKit.sprite(self, "葵", "困倦", "right", 0.4)
	await VNKit.say(self, "葵", "你们两个……能不能小声点。")
	await VNKit.say(self, "凛", "她睡着了。")
	finished.emit()

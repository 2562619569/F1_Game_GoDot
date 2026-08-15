extends Node
## 全工程脚本编译检查（秒级回归）：
##   godot --headless --path . res://game/testing/script_check.tscn
## 强制编译 game/ 与 config/ 下全部 .gd，类型/解析错误立即暴露；
## 比整场冒烟测试快一个数量级，重构过程中先用本脚本快速回归，
## 最终再跑完整冒烟测试（smoke_test.tscn）。

const SCAN_ROOTS := ["res://game", "res://config"]

var failed: Array[String] = []

func _ready() -> void:
	var total := 0
	for root in SCAN_ROOTS:
		total += _scan(root)
	if failed.is_empty():
		print("[SCRIPTS] ALL OK (%d scripts)" % total)
	else:
		for p in failed:
			print("[SCRIPTS] FAIL | %s" % p)
		print("[SCRIPTS] %d/%d failed" % [failed.size(), total])
	get_tree().quit(0 if failed.is_empty() else 1)

func _scan(dir_path: String) -> int:
	var n := 0
	var d := DirAccess.open(dir_path)
	if d == null:
		return 0
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		var path := dir_path.path_join(entry)
		if d.current_is_dir():
			if not entry.begins_with("."):
				n += _scan(path)
		elif entry.ends_with(".gd"):
			n += 1
			_check(path)
		entry = d.get_next()
	d.list_dir_end()
	return n

func _check(path: String) -> void:
	if path == get_script().resource_path:
		return  # 检查器自身正在运行，跳过
	var s: GDScript = load(path)
	# 解析/编译失败的脚本 load 时即打印 SCRIPT ERROR，且无法实例化
	if s == null or not s.can_instantiate():
		failed.append(path)

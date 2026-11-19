class_name PerfOverlay
extends Label
## Performance overlay (03 §14), dev builds only: fps, frame time, draw
## calls, primitives, video and static memory, and the per-system times
## that systems report with `PerfOverlay.record`. Refreshes twice a second.

const REFRESH_S := 0.5

## system name -> last reported milliseconds
static var system_ms: Dictionary = {}

var _since := 0.0


static func record(system: String, ms: float) -> void:
	system_ms[system] = ms


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	hide()


func _process(delta: float) -> void:
	_since += delta
	if visible and _since >= REFRESH_S:
		_since = 0.0
		text = stats_text()


## Shows or hides the overlay; returns the console reply.
func toggle() -> String:
	visible = not visible
	if visible:
		text = stats_text()
	return "perf overlay %s" % ("on" if visible else "off")


func stats_text() -> String:
	var lines: PackedStringArray = [
		(
			"fps %d  frame %.1f ms"
			% [
				Performance.get_monitor(Performance.TIME_FPS),
				Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			]
		),
		(
			"draw calls %d  primitives %d"
			% [
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			]
		),
		(
			"video %.0f MB  static %.0f MB"
			% [
				Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
				Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
			]
		),
	]
	for system: String in system_ms:
		lines.append("%s %.2f ms" % [system, system_ms[system]])
	return "\n".join(lines)

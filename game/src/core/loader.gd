class_name Loader
extends RefCounted
## Loads a batch of resources on worker threads (03 §15.4: meshes and scenes
## are loaded only this way, so pipelines compile off the main thread).
## Call `poll()` once per frame until `is_done()`; then `take(path)`.

## Paths that were missing or failed to load.
var failed: PackedStringArray = []
## path -> last progress (0..1)
var _progress := {}
## path -> loaded resource
var _loaded := {}


## Starts loading `paths` (already requested paths are kept).
func request(paths: PackedStringArray) -> void:
	for path in paths:
		if _progress.has(path):
			continue
		if not ResourceLoader.exists(path):
			failed.append(path)
			continue
		# Sub-threads off: with them the engine left an object behind at exit.
		var err := ResourceLoader.load_threaded_request(path, "", false)
		if err != OK:
			failed.append(path)
			continue
		_progress[path] = 0.0


## Updates progress and collects finished resources.
func poll() -> void:
	for path: String in _progress:
		if _loaded.has(path):
			continue
		var p := []
		var status := ResourceLoader.load_threaded_get_status(path, p)
		match status:
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				_progress[path] = float(p[0]) if not p.is_empty() else 0.0
			ResourceLoader.THREAD_LOAD_LOADED:
				_loaded[path] = ResourceLoader.load_threaded_get(path)
				_progress[path] = 1.0
			_:
				failed.append(path)
				_progress[path] = 1.0
				_loaded[path] = null


## Mean progress of all requested paths, 0..1 (1 when nothing is requested).
func progress() -> float:
	if _progress.is_empty():
		return 1.0
	var total := 0.0
	for path: String in _progress:
		total += float(_progress[path])
	return total / _progress.size()


func is_done() -> bool:
	return _loaded.size() == _progress.size()


## The loaded resource for `path`, or null if it failed or is not done.
func take(path: String) -> Resource:
	return _loaded.get(path)

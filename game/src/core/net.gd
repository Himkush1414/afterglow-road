extends Node
## Autoload "Net". Every world mutation is a request (03 §5): gameplay code
## calls `request(&"name", args)`, and the owning system's handler
## `_req_<name>` runs on the authority. Handlers validate their arguments.
## Single-player is a host without clients, so requests run in the same frame.

const PREFIX := "_req_"

## name -> {"call": Callable, "min": int, "max": int}
var _handlers := {}


## True where world state may change: single-player or the host.
func is_authority() -> bool:
	return multiplayer.is_server()


## Registers every `_req_<name>` method of `owner` as request `name`.
## Returns false (and registers nothing) if any name is already taken.
func register_handlers(owner: Object) -> bool:
	var found := {}
	for m: Dictionary in owner.get_method_list():
		var method: String = m.name
		if not method.begins_with(PREFIX):
			continue
		var name := StringName(method.trim_prefix(PREFIX))
		if _handlers.has(name):
			Log.error("net", "request %s already has a handler" % name)
			return false
		var args: int = (m.args as Array).size()
		found[name] = {
			"call": Callable(owner, method),
			"min": args - (m.default_args as Array).size(),
			"max": args,
		}
	_handlers.merge(found)
	return true


## Removes the handlers that belong to `owner`.
func unregister_handlers(owner: Object) -> void:
	for name: StringName in _handlers.keys():
		if (_handlers[name].call as Callable).get_object() == owner:
			_handlers.erase(name)


func has_handler(name: StringName) -> bool:
	return _handlers.has(name)


## Runs request `name` with `args` and returns the handler's result, or null
## when the request is unknown, has the wrong argument count, or this peer is
## not the authority.
func request(name: StringName, args: Array = []) -> Variant:
	var h: Dictionary = _handlers.get(name, {})
	if h.is_empty():
		Log.error("net", "no handler for request %s" % name)
		return null
	if args.size() < int(h.min) or args.size() > int(h.max):
		Log.error(
			"net", "request %s: %d arguments, expected %d-%d" % [name, args.size(), h.min, h.max]
		)
		return null
	if not is_authority():
		# shortcut: clients refuse requests; phase P20 sends them to the host as an RPC.
		Log.warn("net", "request %s refused: not the authority" % name)
		return null
	return (h.call as Callable).callv(args)

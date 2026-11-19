extends TestCase
## Net shim: handler registry, request dispatch and authority.


class Owner:
	extends RefCounted
	var calls: Array = []

	func _req_add(a: int, b: int) -> int:
		calls.append([a, b])
		return a + b

	func _req_greet(who: String, punct: String = "!") -> String:
		return who + punct

	func not_a_handler() -> void:
		calls.append("wrong")


class Rival:
	extends RefCounted

	func _req_add(_a: int, _b: int) -> int:
		return 0


var _o: Owner


func before_each() -> void:
	_o = Owner.new()
	check(Net.register_handlers(_o), "registered")


func after_each() -> void:
	Net.unregister_handlers(_o)


func test_requests_run_their_handler_in_the_same_call() -> void:
	check(Net.is_authority(), "single-player is the authority")
	check_eq(Net.request(&"add", [2, 3]), 5)
	check_eq(_o.calls, [[2, 3]])
	check_eq(Net.request(&"greet", ["hi"]), "hi!", "default argument")
	check_eq(Net.request(&"greet", ["hi", "?"]), "hi?")
	check(not Net.has_handler(&"not_a_handler"), "only _req_ methods register")


func test_bad_requests_are_refused() -> void:
	check(Net.request(&"nope", []) == null, "unknown request")
	check(Net.request(&"add", [1]) == null, "too few arguments")
	check(Net.request(&"add", [1, 2, 3]) == null, "too many arguments")
	check_eq(_o.calls, [], "handler not run")


func test_a_name_has_one_handler() -> void:
	var rival := Rival.new()
	check(not Net.register_handlers(rival), "duplicate refused")
	check_eq(Net.request(&"add", [1, 1]), 2, "first owner kept")
	Net.unregister_handlers(_o)
	check(not Net.has_handler(&"add"), "unregistered")
	check(Net.register_handlers(rival), "free name can be taken")
	check_eq(Net.request(&"add", [1, 1]), 0)
	Net.unregister_handlers(rival)


func test_a_client_does_not_run_requests() -> void:
	var peer := ENetMultiplayerPeer.new()
	check_eq(peer.create_client("127.0.0.1", 9), OK)
	Net.multiplayer.multiplayer_peer = peer
	check(not Net.is_authority(), "client is not the authority")
	check(Net.request(&"add", [1, 2]) == null, "refused on a client")
	check_eq(_o.calls, [], "handler not run")
	peer.close()
	Net.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	check(Net.is_authority(), "back to single-player")

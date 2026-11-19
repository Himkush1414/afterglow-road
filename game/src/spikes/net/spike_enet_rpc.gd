extends SceneTree
## Spike P1-10 (decision D-12): two ENet peers in one process exchange an RPC
## on localhost; each side must see the other's peer id as the sender.
## Prints RESULT PASS or RESULT FAIL and exits 0 or 1.

const PORT := 24565


class Peer:
	extends Node
	var received: Array[String] = []

	@rpc("any_peer", "call_remote", "reliable")
	func hello(text: String) -> void:
		received.append("%s from %d" % [text, multiplayer.get_remote_sender_id()])


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var server_root := Peer.new()
	server_root.name = "Peer"
	var client_root := Peer.new()
	client_root.name = "Peer"
	var a := Node.new()
	a.name = "Host"
	var b := Node.new()
	b.name = "Guest"
	root.add_child(a)
	root.add_child(b)
	a.add_child(server_root)
	b.add_child(client_root)
	var host_api := SceneMultiplayer.new()
	var guest_api := SceneMultiplayer.new()
	set_multiplayer(host_api, a.get_path())
	set_multiplayer(guest_api, b.get_path())
	var server := ENetMultiplayerPeer.new()
	var client := ENetMultiplayerPeer.new()
	server.set_bind_ip("127.0.0.1")
	var e1 := server.create_server(PORT, 4)
	var e2 := client.create_client("127.0.0.1", PORT)
	host_api.multiplayer_peer = server
	guest_api.multiplayer_peer = client
	var t0 := Time.get_ticks_msec()
	while not _is_connected(client) and Time.get_ticks_msec() - t0 < 5000:
		host_api.poll()
		guest_api.poll()
		await process_frame
	var connected := _is_connected(client)
	# Let the host register the peer before the first RPC.
	for i in 5:
		host_api.poll()
		guest_api.poll()
		await process_frame
	if connected:
		client_root.hello.rpc_id(1, "ping")
		server_root.hello.rpc("pong")
	t0 = Time.get_ticks_msec()
	while (
		(server_root.received.is_empty() or client_root.received.is_empty())
		and Time.get_ticks_msec() - t0 < 5000
	):
		host_api.poll()
		guest_api.poll()
		await process_frame
	var ms := Time.get_ticks_msec() - t0
	print(
		(
			"create_server=%s create_client=%s connected=%s"
			% [error_string(e1), error_string(e2), connected]
		)
	)
	print("host got %s; guest got %s; %d ms" % [server_root.received, client_root.received, ms])
	var guest_id := guest_api.get_unique_id()
	var ok := (
		server_root.received == ["ping from %d" % guest_id]
		and client_root.received == ["pong from 1"]
	)
	print("RESULT %s" % ("PASS" if ok else "FAIL"))
	server.close()
	client.close()
	quit(0 if ok else 1)


func _is_connected(peer: ENetMultiplayerPeer) -> bool:
	return peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

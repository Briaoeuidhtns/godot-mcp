@tool
extends Node
class_name MCPWebSocketServer

signal command_received(client: WebSocketPeer, id: String, command: String, params: Dictionary)
signal client_connected()
signal client_disconnected()

const DEFAULT_PORT := 6550
const SETTING_ALLOW_MULTIPLE_CLIENTS := "godot_mcp/allow_multiple_clients"
const STALE_CONNECTION_TIMEOUT_MSEC := 45000
# Upper bound on how long a rejected newcomer is kept around while we hand it a
# clean 4001 close. Caps the whole reject lifecycle (handshake + close flush) so
# a peer that never upgrades or never finishes closing can't leak.
const REJECT_TIMEOUT_MSEC := 5000
const CLOSE_CODE_STALE := 4002
const CLOSE_REASON_STALE := "Connection timed out (no activity)"
const CLOSE_CODE_ALREADY_CONNECTED := 4001
const CLOSE_REASON_ALREADY_CONNECTED := "Another client is already connected"

class Client:
	var tcp: StreamPeerTCP
	var ws := WebSocketPeer.new()
	var connected := false
	var last_activity_msec := Time.get_ticks_msec()

var _server: TCPServer
var _clients: Array[Client] = []
# Newcomers that arrived while a live client already held the bridge. Each entry
# is { "ws": WebSocketPeer, "tcp": StreamPeerTCP, "since_msec": int, "close_sent": bool }.
# They are handshaked just far enough to receive a clean 4001 close, then dropped.
var _rejecting_peers: Array = []


func _process(_delta: float) -> void:
	if not _server:
		return

	if _server.is_connection_available():
		_accept_connection()

	for i in range(_clients.size() - 1, -1, -1):
		_process_client(_clients[i])

	if not _rejecting_peers.is_empty():
		_process_rejecting_peers()


func start_server(port: int = DEFAULT_PORT, bind_address: String = "127.0.0.1") -> Error:
	_server = TCPServer.new()
	var err := _server.listen(port, bind_address)
	if err != OK:
		_server = null
		MCPLog.error("Failed to start server on %s:%d: %s" % [bind_address, port, error_string(err)])
		return err

	return OK


func stop_server() -> void:
	for client in _clients:
		client.ws.close()
		client.tcp.disconnect_from_host()
	_clients.clear()

	for entry in _rejecting_peers:
		var rej_ws: WebSocketPeer = entry.get("ws")
		if rej_ws:
			rej_ws.close()
		var rej_tcp: StreamPeerTCP = entry.get("tcp")
		if rej_tcp:
			rej_tcp.disconnect_from_host()
	_rejecting_peers.clear()

	if _server:
		_server.stop()
		_server = null


func get_connected_host() -> String:
	for client in _clients:
		if client.connected:
			return client.tcp.get_connected_host()
	return ""


func get_connected_port() -> int:
	for client in _clients:
		if client.connected:
			return client.tcp.get_connected_port()
	return 0


func send_response(response: Dictionary, client: WebSocketPeer) -> void:
	# Async commands retain their original peer, never whichever client connected last.
	if client.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	client.send_text(JSON.stringify(response))


func _accept_connection() -> void:
	var incoming := _server.take_connection()
	if not incoming:
		return

	# Read on admission: disabling the setting protects existing clients but rejects
	# newcomers until the bridge is free. It never kicks off an active client.
	if not ProjectSettings.get_setting(SETTING_ALLOW_MULTIPLE_CLIENTS, false):
		for i in range(_clients.size() - 1, -1, -1):
			var client := _clients[i]
			if _is_stale_connection(client):
				_drop_client(client)
		if not _clients.is_empty():
			MCPLog.warn("Rejecting new connection from %s:%d: another client is already connected" % [incoming.get_connected_host(), incoming.get_connected_port()])
			_begin_reject(incoming)
			return

	var client := Client.new()
	client.tcp = incoming
	client.ws.outbound_buffer_size = 16 * 1024 * 1024  # 16MB for screenshot data
	var err := client.ws.accept_stream(incoming)
	if err != OK:
		MCPLog.error("Failed to accept WebSocket stream: %s" % error_string(err))
		incoming.disconnect_from_host()
		return
	_clients.append(client)
	MCPLog.info("TCP connection received from %s:%d, awaiting WebSocket handshake..." % [incoming.get_connected_host(), incoming.get_connected_port()])


func _begin_reject(incoming: StreamPeerTCP) -> void:
	# Complete just enough of the WebSocket handshake on a throwaway peer to send
	# a proper coded close frame (4001), so the rejected client gets a clear
	# diagnostic rather than an opaque TCP reset. The incumbent's peer is never
	# touched. Driven to completion in _process_rejecting_peers().
	var ws := WebSocketPeer.new()
	var err := ws.accept_stream(incoming)
	if err != OK:
		# Can't speak WebSocket to this peer; just drop the raw TCP connection.
		incoming.disconnect_from_host()
		return
	_rejecting_peers.append({
		"ws": ws,
		"tcp": incoming,
		"since_msec": Time.get_ticks_msec(),
		"close_sent": false,
	})


func _process_rejecting_peers() -> void:
	var keep: Array = []
	var now := Time.get_ticks_msec()
	for entry in _rejecting_peers:
		var ws: WebSocketPeer = entry["ws"]
		ws.poll()
		var state := ws.get_ready_state()

		# Hard lifecycle cap: a reject peer should resolve in milliseconds.
		# Anything still around past the timeout (never upgraded, or stuck
		# mid-close because the client vanished) gets dropped so it can't leak.
		if now - int(entry["since_msec"]) > REJECT_TIMEOUT_MSEC:
			_drop_rejecting_peer(entry)
			continue

		match state:
			WebSocketPeer.STATE_OPEN:
				if not entry["close_sent"]:
					ws.close(CLOSE_CODE_ALREADY_CONNECTED, CLOSE_REASON_ALREADY_CONNECTED)
					entry["close_sent"] = true
				# Keep polling so the close frame is actually flushed.
				keep.append(entry)
			WebSocketPeer.STATE_CLOSED:
				_drop_rejecting_peer(entry)
			_:
				# STATE_CONNECTING (awaiting handshake) or STATE_CLOSING
				# (flushing the close frame) - keep polling until the cap.
				keep.append(entry)
	_rejecting_peers = keep


func _drop_rejecting_peer(entry: Dictionary) -> void:
	var tcp: StreamPeerTCP = entry.get("tcp")
	if tcp:
		tcp.disconnect_from_host()
	entry["ws"] = null
	entry["tcp"] = null


func _process_client(client: Client) -> void:
	client.ws.poll()
	var state := client.ws.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		_drop_client(client)
		return
	if state == WebSocketPeer.STATE_CLOSING:
		return
	if _is_stale_connection(client):
		client.ws.close(CLOSE_CODE_STALE, CLOSE_REASON_STALE)
		return
	if state != WebSocketPeer.STATE_OPEN:
		return

	if not client.connected:
		var was_connected := not get_connected_host().is_empty()
		client.connected = true
		client.last_activity_msec = Time.get_ticks_msec()
		if not was_connected:
			client_connected.emit()
		MCPLog.info("WebSocket handshake complete")

	while client.ws.get_available_packet_count() > 0:
		client.last_activity_msec = Time.get_ticks_msec()
		_handle_packet(client.ws.get_packet(), client.ws)


func _drop_client(client: Client) -> void:
	client.ws.close()
	client.tcp.disconnect_from_host()
	_clients.erase(client)
	# The status panel describes whether any client is connected, not each socket.
	if client.connected and get_connected_host().is_empty():
		client_disconnected.emit()


func _is_stale_connection(client: Client) -> bool:
	return client.tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED or Time.get_ticks_msec() - client.last_activity_msec > STALE_CONNECTION_TIMEOUT_MSEC


func _handle_packet(packet: PackedByteArray, client: WebSocketPeer) -> void:
	var text := packet.get_string_from_utf8()

	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		MCPLog.error("Failed to parse command: %s" % json.get_error_message())
		_send_error_response("", "PARSE_ERROR", "Invalid JSON: %s" % json.get_error_message(), client)
		return

	if not json.data is Dictionary:
		MCPLog.error("Invalid command format: expected JSON object")
		_send_error_response("", "INVALID_FORMAT", "Expected JSON object", client)
		return

	var data: Dictionary = json.data
	if not data.has("id") or not data.has("command"):
		MCPLog.error("Invalid command format")
		_send_error_response(str(data.get("id", "")), "INVALID_FORMAT", "Missing 'id' or 'command' field", client)
		return

	var id: String = str(data.get("id"))
	var command: String = data.get("command")
	var params: Dictionary = data.get("params", {})

	command_received.emit(client, id, command, params)


func _send_error_response(id: String, code: String, message: String, client: WebSocketPeer) -> void:
	send_response({
		"id": id,
		"status": "error",
		"error": {
			"code": code,
			"message": message
		}
	}, client)

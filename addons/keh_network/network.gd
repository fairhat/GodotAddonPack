###############################################################################
# Copyright (c) 2019 Yuri Sarudiansky
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
###############################################################################

extends Node
class_name Network

# TODO:
# - (Re)Incorporate delta snapshot compression
# - Method to "cull" objects from snapshots which may lead to *some* bandwidth
#   savings. One such case would be to eliminate every object that is relatively
#   far from the client and maybe even impossible to be seen.
# - Some way to get raw snapshot data so it can be used in a save game system.
#   Obviously a function must be provided to allow restoring from this data.
# - If possible, separate data exchange into network channels. In this case, create
#   channels for: snapshot, chat, input and ping/pong data
# - Better communicate (with warning or something) whenever there are non replicable
#   properties defined within SnapEntityBase derived classes
# - A function to "whisper" a message to the specified player in a way that the
#   message goes through the server first. This can be useful for logging purposes
# - One way to allow error margins to be used during the comparison of snapshot entities,
#   more specifically when comparing floating point numbers.
# - Replicated event system.


# Limitations:
# - The integrated input system makes it almost impossible to mix local
#   multiplayer with networked multiplayer in a single game instance
# - The integrated input system encodes boolean actions into a single integer of
#   either 8, 16 or 32 bits, meaning that "only" 32 boolean actions can be used
#   with this system.
# - The various signatures (input, snapshot...) are using 32 bit integers
#   meaning that if the game is set to 60 frames per second then after
#   slightly more than 4 years and a half of continuously running, the
#   the game will break, forcing a restart to occur periodically.
# - The replicated event system packs the event code (ID) using 16 bits, meaning
#   that only 65536 different event types can be used with this sytem.

# One thing to note:
# Originally this system did include "delta compression", that is, only encode
# into snapshots what has been changed. However, doing so requires a bunch of
# extra upkeep (which will probably be noticed across the system as "left-overs")
# What happened is that dealing with this kind of compression requires a lot
# more work (and debugging) than anticipated. When the system was "working"
# (there were some bugs to be solved but mostly working), measuring the bandwidth
# showed that it was actually using more data than dealing with only full
# snapshots! Because of that, delta has been removed (but not completely).
# from the code. At a later date it **may** be reincorporated into the addon,
# as there is a really high probability that the extra data usage was caused
# by an error (AKA bug) in the implementation.


# When trying to create a server the result is not instant. Because of that,
# signals are required. The next two are for success of failure, respectively.
signal server_created
signal server_creation_failed

# Whenever a new player is added into the internal list (registered) or removed
# (unregistered) a signal will be emitted, with the ID of that player.
signal player_added(id)
signal player_removed(id)

# If the credential system is being used this signal will be emitted only on
# client machines trying to join the server, indicating that the server is
# requesting the credential data.
signal credentials_requested

# Joining a server can fail, be accepted or rejected. The following signals
# indicate those, respectively. In the rejection case, an string is given
# with the rejection reason.
signal join_fail
signal join_accepted
signal join_rejected(reason)

# A client will get this signal whenever disconnected from the server
signal disconnected

# This will be given whenever the measured ping value of a player is changed.
# The arguments are the peer id and the measured value, respectively.
signal ping_updated(peer, value)

# A client gets this signal when kicked from the server, with the reason as argument.
signal kicked(reason)

# This signal is emitted whenever a chat message is received. The first argument is
# the message itself, while the second argument is the peer ID of the sender.
signal chat_message_received(msg, sender)

# This signal is emitted whenever a custom user property has been updated through
# the automatic replication system. The arguments are, player ID owning the property,
# property name and the new value.
signal custom_property_changed(pid, pname, value)


# This inner class will be used to control the overall update flow. It holds the
# snapshot that is being built. When the "start snapshot" gets called from game code
# the interface code will relay the call to the instance of this class, which will
# take care of setting up a deferred call to the function that will perform the
# final tasks of "post game update", which is finishing the snapshot, encoding and
# sending to the clients as well as dispatching all accumulated events
class UpdateControl:
	var sig: int              # The signature of the snapshot being built. Probably redundant property
	var snap: NetSnapshot     # Snapshot being built
	var events: Array         # Accumulate events in this array
	var edec: EncDecBuffer    # To encode/decode network data (snapshots and events)
	var sfinished: FuncRef    # Will be called during the finish() function, meant to perform the snapshot finished actions
	var evtdispatch: FuncRef  # Will be called during finish(), meant to dispatch accumulated events
	
	func _init() -> void:
		sig = 0
		snap = null
		events = []
		edec = EncDecBuffer.new()
	
	func get_signature() -> int:
		assert(snap)
		return snap.signature
	
	func start(info: Dictionary) -> void:
		sig += 1
		snap = NetSnapshot.new(sig)
		for k in info.keys():
			snap.add_type(k)
		
		# Defer the call to the finish() function so the physics tick can finish updating the game state
		call_deferred("finish")
	
	func finish() -> void:
		if (!snap):
			return
		
		# Call the finish snapshot function
		sfinished.call_func(snap)
		# Dispatch events
		evtdispatch.call_func(events)
		
		snap = null




# Holds player data information
var player_data: NetPlayerData setget noset

## Holds information about the server
##var server_info: NetServerInfo setget noset


# As part of this system, the server will request credentials from a connecting client. Since the credentials
# themselves can change from project to project, a function will be called by the server (and must be run there)
# when the credentials from the client arrive. That function will get the network ID of the client as well as
# credentials dictionary that have arrived and based on that information it must return true to accept the
# connection and false to reject it. Said function will be pointed by this FuncRef and if it's invalid the
# connection will be automatically accepted.
var credential_checker: FuncRef = null


# This object holds the snapshot data as well as provide functionality to automate encoding and decoding
# to and from low level byte arrays representing the snapshots. While only the server will contain a history
# of snapshots, all machines must have this object in a valid state in order to properly decode the data.
var snapshot_data: NetSnapshotData setget noset

# This object will be used to help build new snapshots as well as keep updates across the network
var _update_control: UpdateControl setget noset


### Some options retrieved from the ProjectSettings
# It's *not* a good idea to provide this as a setting to players because the value must be equal on all
# machines otherwise the connection will fail.
var _compression: int = NetworkedMultiplayerENet.COMPRESS_RANGE_CODER setget noset

# If this is enabled then when the server gets a ping answer it will broadcast to other peers the measured
# value. For some projects this may not be desireable but is on by default.
var _broadcast_ping_value: bool = true setget noset

# If the amount of snapshots generated by the server reaches this amount without getting any acknowledgement
# then the newest full snapshot object will be sent to that client
var _full_snap_threshold: int = 12 setget noset

# Determines the maximum amount of snapshots within the history
var _max_history_size: int = 120 setget noset

# Key = event code ID
# Value = instance of the NetEventInfo class
var _event_info: Dictionary = {} setget noset


# Most of the unique IDs within the snapshots can be simply incrementing integers.
# Often that can be easily done through an auto-load script. Taking advantage of
# the fact that this script is already an auto-load one, this dictionary is used
# to hold multiple of those IDs. The key specify the type of entity while the
# value is the actual ID. When the network.reset_system() is called all of the
# IDs will also be reset. Some functions are provided to access the contents of
# this dictionary so avoid directly using it.
var _incrementing_id: Dictionary setget noset


func _ready() -> void:
	# Create the objects
	player_data = NetPlayerData.new()
	snapshot_data = NetSnapshotData.new()
	_update_control = UpdateControl.new()
	
	_update_control.sfinished = funcref(self, "_on_snapshot_finished")
	_update_control.evtdispatch = funcref(self, "_on_dispatch_events")
	
	# Set the func refs within the player data - the local player will automatically get the correct refs
	player_data.ping_signaler = funcref(self, "_ping_signaler")
	player_data.cprop_signaler = funcref(self, "_custom_property_signaler")
	player_data.cprop_broadcaster = funcref(self, "_custom_prop_broadcast_requester")
	
	# Local player should always be part of the tree - even for single player
	add_child(player_data.local_player)
	player_data.local_player.set_network_id(1)
	
	### The availability of the project settings must be tested because if they are set to the
	### default values they will not be present
	# Obtain compression mode from ProjectSettings
	if (ProjectSettings.has_setting("keh_addons/network/compression")):
		_compression = ProjectSettings.get_setting("keh_addons/network/compression")
	
	
	# Obtain the preference for broadcasting measured ping values
	if (ProjectSettings.has_setting("keh_addons/network/broadcast_measured_ping")):
		_broadcast_ping_value = ProjectSettings.get_setting("keh_addons/network/broadcast_measured_ping")
	
	if (ProjectSettings.has_setting("keh_addons/network/full_snapshot_threshold")):
		_full_snap_threshold = ProjectSettings.get_setting("keh_addons/network/full_snapshot_threshold")
	
	# Obtain the preference for maximum snapshot history size
	if (ProjectSettings.has_setting("keh_addons/network/max_snapshot_history")):
		_max_history_size = ProjectSettings.get_setting("keh_addons/network/max_snapshot_history")
		### The commented lines bellow are "leftovers" related to the delta compression, which will be
		### re-implemented later.
		# The maximum history size cannot be smaller than the threshold to send full snapshot data
#		if (_max_history_size < _full_snap_threshold + 1):
#			var w: String = "The desired max snapshot history (%d) is smaller than the full snapshot threshold, so setting it to %d."
#			push_warning(w % [_max_history_size, _full_snap_threshold + 1])
#			_max_history_size = _full_snap_threshold + 1
	
	
	# Connect to the high level networking signals
	# warning-ignore:return_value_discarded
	get_tree().connect("network_peer_connected", self, "_on_player_connected")
	# warning-ignore:return_value_discarded
	get_tree().connect("network_peer_disconnected", self, "_on_player_disconnected")
	
	# warning-ignore:return_value_discarded
	get_tree().connect("connection_failed", self, "_on_connection_failed")
	# warning-ignore:return_value_discarded
	get_tree().connect("server_disconnected", self, "_on_disconnected")


func reset_system() -> void:
	_update_control.sig = 0
	_update_control.snap = null
	_update_control.events.clear()
	snapshot_data.reset()
	player_data.local_player.reset_data()
	
	# Reset the incrementing IDs
	for iid in _incrementing_id:
		_incrementing_id[iid] = 0
	
	# Clear all the event handlers
	for eid in _event_info:
		_event_info[eid].clear_handlers()


# Tells if the machine has authority or not. In a single player this should always be true.
# In the case of multiplayer, this should only return true if the machine is the host/server.
func has_authority() -> bool:
	return (!get_tree().has_network_peer() || get_tree().is_network_server())


func is_single_player() -> bool:
	return !get_tree().has_network_peer()


# Returns true if the provided ID corresponds to the local player
func is_id_local(pid: int) -> bool:
	return player_data.local_player.net_id == pid



# Allows to registration of input within the system. One thing to note is that the specified
# action must be part of the input settings (check the ProjectSettings -> Input Map tab). This
# fact will be checked and if the map does not exist a warning will be output.
func register_action(action: String, is_analog: bool) -> void:
	if (InputMap.has_action(action)):
		player_data.input_info.register_action(action, is_analog, false)
	
	else:
		var w: String = "Trying to register %s input action but it's not mapped. Please check Project Settings -> Input Map tab."
		push_warning(w % action)

# Allows registration of custom input data within the input system. This will register either
# a custom analog (is_analog = true) or a custom boolean state (is_analog = false)
func register_custom_action(action: String, is_analog: bool) -> void:
	player_data.input_info.register_action(action, is_analog, true)


func register_custom_input_vec2(vec_name: String) -> void:
	player_data.input_info.register_vec2(vec_name)

func register_custom_input_vec3(vec_name: String) -> void:
	player_data.input_info.register_vec3(vec_name)


func reset_input() -> void:
	player_data.input_info.reset_actions()


func set_use_mouse_relative(use: bool) -> void:
	player_data.input_info.set_use_mouse_relative(use)

func set_use_mouse_speed(use: bool) -> void:
	player_data.input_info.set_use_mouse_speed(use)


# Obtain input data for the specified player. If local, the data will be polled. If for
# a client, data will be retrieved from the input cache if this code is running on the
# server.
func get_input(player_id: int) -> InputData:
	var is_authority: bool = has_authority()
	
	if (!is_id_local(player_id) && !is_authority):
		return null
	
	var pnode: NetPlayerNode = player_data.get_pnode(player_id)
	var retval: InputData = pnode.get_input(_update_control.sig) if pnode else null
	
	return retval



### Server...
func create_server(port: int, _server_name: String, max_players: int) -> void:
	# Create the network API object
	var net: NetworkedMultiplayerENet = NetworkedMultiplayerENet.new()
	net.compression_mode = _compression
	
	# Try to create the server
	if (net.create_server(port, max_players) != OK):
		emit_signal("server_creation_failed")
		return
	
	# Assign it into the tree
	get_tree().set_network_peer(net)
	# Indicate that the server has been created
	emit_signal("server_created")
	# Ensure the local_player variable is holding the correct net_id value
	player_data.local_player.set_network_id(1)
	
	
	# TODO: build server info


# This should be called whenever the server is about to close, either the player quitting to
# the main menu or closing the game window
func close_server(_message: String = "Server is closing") -> void:
	if (!get_tree().has_network_peer()):
		return
	if (!get_tree().is_network_server()):
		return
	
	# Normal iteration through the player_list can't be done because at each one a
	# disconnect_peer() will be called, which will remove that player info from the
	# list. So, first retrieving the list of keys and then iterating through that
	var keys: Array = player_data.remote_player.keys()
	for k in keys:
		kick_player(k, _message)
	
	# Cleanup the network object
	get_tree().set_network_peer(null)


func kick_player(id: int, reason: String) -> void:
	# First remote call the function that will give the reason to the kicked player
	rpc_id(id, "kicked", reason)
	# Then remove the player
	get_tree().network_peer.disconnect_peer(id)


func _on_player_connected(id: int) -> void:
	if (get_tree().is_network_server()):
		if (credential_checker):
			# Tell the client that credentials are necessary
			rpc_id(id, "request_credentials")
		else:
			# If the credential checker is not set then assume this feature is not desired
			# and automatically accept the new player
			rpc_id(id, "on_join_accepted")


func _on_player_disconnected(id: int) -> void:
	if (get_tree().is_network_server()):
		# Unregister the player from the server's list
		_unregister_player(id)
		# And from everyone else
		rpc("_unregister_player", id)


# Clients call this function to send credentials to servers
remote func server_receive_credentials(cred: Dictionary) -> void:
	if (!get_tree().is_network_server()):
		return
	
	var id: int = get_tree().get_rpc_sender_id()
	
	# If the credential_checker funcref is invalid then automatically accept the new player.
	# Otherwise, only if the referenced function returns true
	if (!credential_checker || credential_checker.call_func(id, cred).length() == 0):
		rpc_id(id, "on_join_accepted")
	else:
		rpc_id(id, "on_join_rejected")



### Client...
func join_server(_ip: String, _port: int) -> void:
	var net: NetworkedMultiplayerENet = NetworkedMultiplayerENet.new()
	net.compression_mode = _compression
	
	if (net.create_client(_ip, _port) != OK):
		emit_signal("join_fail")
		return
	
	# And set the network API
	get_tree().set_network_peer(net)

func disconnect_from_server() -> void:
	if (!get_tree().has_network_peer()):
		return
	if (get_tree().is_network_server()):
		return
	
	get_tree().get_network_peer().close_connection()
	

func _on_connection_failed() -> void:
	emit_signal("join_fail")
	# Clear the network object
	get_tree().set_network_peer(null)
	# At this point the local player info is likely still correct, but it doesn't hurt to ensure this fact
	player_data.local_player.set_network_id(1)


func _on_disconnected() -> void:
	# Inform outside code about this event
	emit_signal("disconnected")
	# This is a client that got disconnected. Clear the remote player list
	player_data.clear_remote()
	# And ensure the local player is holding the correct data
	player_data.local_player.set_network_id(1)
	
	# As of Godot 3.2 beta (from one of the release candidates) directly setting
	# the peer network to null (reset) results in error (object being destroyed
	# while emitting a signal), so deferring the call to avoid that.
	get_tree().call_deferred("set_network_peer", null)



remote func request_credentials() -> void:
	# The server is requesting credentials. Since this changes from project to project, emit a signal so
	# game specific code can deal with this
	emit_signal("credentials_requested")


# Client code directly use this function in order to send credentials (stored in the cred dictionary)
# to the server. The contents of the dictionary are project dependent.
func dispatch_credentials(cred: Dictionary) -> void:
	if (get_tree().is_network_server()):
		return
	
	rpc_id(1, "server_receive_credentials", cred)


remote func on_join_accepted() -> void:
	# This will be called by the server if the connection attempt is allowed
	# Notify the local machine about the success
	emit_signal("join_accepted")
	# Joined the server. Now must ensure the local_player data corresponds to the
	# assigned network id
	var new_id: int = get_tree().get_network_unique_id()
	player_data.local_player.set_network_id(new_id)
	# Register the server within the remote player list
	_register_player(1)
	# Request the server to register the new player within everyone's list
	# This will also make the server send everyone's data to this new player
	rpc_id(1, "_register_player", new_id)
	
	# Some custom properties may have been modified before connecting to the server.
	# Must ensure the correct values are given to the server
	player_data.local_player.initial_custom_sync()



remote func on_join_rejected(reason: String) -> void:
	# Just notify about this. Further cleanup will be done from the _on_disconnected_from_server
	# because technically speaking this peer has been disconnected.
	emit_signal("join_rejected", reason)


# Server call this before forcefully disconnecting a client
remote func kicked(reason: String) -> void:
	# Tell outside code about this
	emit_signal("kicked", reason)


### Player Data management
remote func _register_player(pid: int) -> void:
	var is_server: bool = get_tree().is_network_server()
	
	# Create the player node - it's not registered (within the container) yet
	var player: NetPlayerNode = player_data.create_player(pid)
	
	# The player node must be part of the tree
	add_child(player)
	
	if (is_server):
		# Start the "ping/pong" loop
		player.start_ping()
		
		# Server only section is meant to "distribute players" to the new player as well as the new
		# player to the already connected ones
		for cid in player_data.remote_player:
			# Send currently iterated remote player to the new player
			rpc_id(pid, "_register_player", cid)
			# Send new player to currently iterated player
			rpc_id(cid, "_register_player", pid)
			
			# Synchronize currently iterated player's custom data with the new player
			player_data.remote_player[cid].sync_custom_with(pid)
			# New player's data will be synchronized at a later moment, when the correct
			# data arrives
	
	# "Register" within the container
	player_data.add_remote(player)
	
	# Outside code might need to do something when a new player is registered
	emit_signal("player_added", pid)



remote func _unregister_player(_id: int) -> void:
	var pnode: NetPlayerNode = player_data.remote_player.get(_id)
	if (pnode):
		# Outside code might need to do something when a player leaves the game
		emit_signal("player_removed", _id)
		# Mark the NetPlayerNode for removal from the tree
		pnode.queue_free()
		# And remove the reference from the internal container
		# warning-ignore:return_value_discarded
		player_data.remote_player.erase(_id)


#### Incrementing ID system
func register_incrementing_id(id_name: String) -> void:
	_incrementing_id[id_name] = 0

func get_incrementing_id(id_name: String) -> int:
	assert(_incrementing_id.has(id_name))
	_incrementing_id[id_name] += 1
	return _incrementing_id[id_name]


#### Snapshot system
func init_snapshot() -> void:
	_update_control.start(snapshot_data._entity_info)


# Return the signature of the snapshot being built
func get_snap_building_signature() -> int:
	return _update_control.get_signature()


# Add the provided entity into the snapshot that is being built
func snapshot_entity(entity: SnapEntityBase) -> void:
	assert(_update_control.snap)
	assert(snapshot_data._entity_name.has(entity.get_script()))
	
	var ehash: int = snapshot_data._entity_name.get(entity.get_script()).hash
	_update_control.snap.add_entity(ehash, entity)


# Used to correct the state of an entity within the local snapshot. This may be useful
# when a player controlled entity is corrected and replayed. The correction is
# meant to (try to) avoid triggering further corrections.
func correct_entity(entity: SnapEntityBase, snap_sig: int) -> void:
	assert(snapshot_data._entity_name.has(entity.get_script()))
	
	var snap: NetSnapshot = snapshot_data.get_snapshot(snap_sig)
	if (snap):
		var ehash: int = snapshot_data._entity_name.get(entity.get_script()).hash
		snap.add_entity(ehash, entity)




# This function will be automatically called whenever the snapshot is actually finished,
# through the deferred call. This function is meant to iterate through connected players
# and send them snapshots when necessary. The server must "decide" when it's necessary
# to send full snapshot data or batches of delta snapshots. The "rules" are as follow:
# 1 - When simulating, if the player in question does not contain input data then it will
#     trigger a "full snapshot flag".
# 2 - Amount of non acknowledged snapshots reaches a certain threshold will trigger a
#     "full snapshot flag".
# 3 - If the "full snapshot flag" is not triggered, then send a batch of delta snapshots.
func _on_snapshot_finished(snap: NetSnapshot) -> void:
	# Although irrelevant on authority machines, it's much easier to just "attach" the
	# local input signature to the snapshot
	snap.input_sig = player_data.local_player.get_last_input_signature()
	snapshot_data._history.push_back(snap)
	
	if (!has_authority()):
		return
	
	while (snapshot_data._history.size() > _max_history_size):
		snapshot_data._history.pop_front()
	
	# Iterate through remote players and update as required
	for pid in player_data.remote_player:
		var player: NetPlayerNode = player_data.remote_player[pid]
		
		if (!player.is_ready()):
			continue
		
		# Obtain the list of non acknowledged snapshots for this client, including the
		# corresponding input signatures
		var non_ack_count: int = player.get_non_acked_snap_count()
		# Ensure the byte array buffer is empty
		_update_control.edec.buffer = PoolByteArray()
		
		# Retrieve input signature used when the snapshot was generated.
		var isig: int = player.get_used_input_in_snap(snap.signature)
		
		snapshot_data.encode_full(snap, _update_control.edec, isig)
		rpc_unreliable_id(pid, "_client_receive_full_snapshot", _update_control.edec.buffer)

### The commented code bellow is a "left over" of the delta compression. Since reimplementing
### the delta system is in the TODO, this code will remain until the system is reworked.
		# if (non_ack_count > _full_snap_threshold || player.has_snap_with_no_input()):
		# 	# If here, then full snapshot data must be sent to the client. In this
		# 	# case, send the newest one (the one given as argument here)
		# 	snapshot_data.encode_full(snap, _update_control.edec, isig)
		# 	rpc_unreliable_id(pid, "_client_receive_full_snapshot", _update_control.edec.buffer)
		
		# else:
		# 	# func encode_delta(ref: NetSnapshot, snap: NetSnapshot, into: EncDecBuffer, isig: int) -> void:
		# 	# And here, a delta snapshot must be sent.
		# 	var refsig: int = player.get_last_acked_snap_sig()
		# 	if (snapshot_data.encode_delta(refsig, snap, _update_control.edec, isig)):
		# 		rpc_unreliable_id(pid, "_client_receive_delta_snapshot", _update_control.edec.buffer)



# Clients directly use this function in order to notify the server they are
# ready to receive snapshot data.
func notify_ready() -> void:
	if (!has_authority()):
		rpc_id(1, "server_client_is_ready")


# Server will only send snapshot data to a client when this function is called
# by that peer.
remote func server_client_is_ready() -> void:
	assert(has_authority())
	
	# Retrieve the unique ID of the player that called this
	var pid: int = get_tree().get_rpc_sender_id()
	var player: NetPlayerNode = player_data.remote_player.get(pid)
	if (player):
		player.set_ready(true)


# This is called by the client in order to acknowledge that snapshot
# data has been received and processed.
remote func server_acknowledge_snapshot(sig: int) -> void:
	assert(has_authority())
	
	var pid: int = get_tree().get_rpc_sender_id()
	var player: NetPlayerNode = player_data.remote_player.get(pid)
	if (player):
		player.server_acknowledge_snapshot(sig)



# Server calls this when sending full snapshot data
remote func _client_receive_full_snapshot(encoded: PoolByteArray) -> void:
	assert(!has_authority())
	_update_control.edec.buffer = encoded
	var decoded: NetSnapshot = snapshot_data.decode_full(_update_control.edec)
	if (decoded):
		# Acknowledge to the server the received snapshot
		rpc_unreliable_id(1, "server_acknowledge_snapshot", decoded.signature)
		
		# Check this snapshot comparing to the predicted one. This function also
		# updates the internal _server_state property, which must match the most
		# recent received data.
		snapshot_data.client_check_snapshot(decoded)
		
		# The snapshot may contain input signature, which serves as an acknowledgement
		# from the server about the input data. So, perform clearing of internal
		# input cache so this data (and older) doesn't get sent to the server again
		if (decoded.input_sig > 0):
			player_data.local_player.client_acknowledge_input(decoded.input_sig)



### Replicated event system
func register_event_type(code: int, param_types: Array) -> void:
	_event_info[code] = NetEventInfo.new(code, param_types)


func attach_event_handler(evt_code: int, obj: Object, funcname: String) -> void:
	# If the assert fails then trying to attach an event handler to a non registered event type
	assert(_event_info.has(evt_code))
	# Object must be valid and it must contain the "funcname" function
	assert(obj && obj.has_method(funcname))
	
	var evt_info: NetEventInfo = _event_info.get(evt_code)
	evt_info.attach_handler(obj, funcname)


# Accumulate an event to be sent to the clients
func send_event(code: int, params: Array) -> void:
	# Ensure the requested event type code has been registered
	assert(_event_info.has(code))
	
	# Only the authority can replicate events
	if (!has_authority()):
		return
	
	_update_control.events.push_back({"code": code, "params": params})

# This will be (internally) called whenever the physics update ends and should be
# used to encode the accumulated events then sent to all clients
func _on_dispatch_events(events: Array) -> void:
	# Only authority can dispatch events. And if there are no events, no need
	# to continue here
	if (!has_authority() || events.size() == 0):
		return
	
	if (player_data.remote_player.size() > 0):
		_update_control.edec.buffer = PoolByteArray()
		# Write the amount of events - 16 bits should be way more than enough
		_update_control.edec.write_ushort(events.size())
	
	# Iterate through each accumulated event
	for evt in events:
		var evtinfo: NetEventInfo = _event_info.get(evt.code)
		
		if (player_data.remote_player.size() > 0):
			# Write the type code using 16 bits
			_update_control.edec.write_ushort(evt.code)
			# Encode the parameters - this will also call the event handlers so server can
			# do something with this event
			evtinfo.encode(_update_control.edec, evt.params)
		
		evtinfo.call_handlers(evt.params)
	
	# Dispatch the encoded events - using the reliable channel
	if (!is_single_player()):
		rpc("_on_receive_net_event", _update_control.edec.buffer)
	
	# Clear event accumulation
	_update_control.events.clear()


remote func _on_receive_net_event(encoded: PoolByteArray) -> void:
	_update_control.edec.buffer = encoded
	# Obtain the event count
	var evtcount: int = _update_control.edec.read_ushort()
	for _i in evtcount:
		# Read the code
		var ecode: int = _update_control.edec.read_ushort()
		# Obtain the event info
		var evtinfo: NetEventInfo = _event_info.get(ecode)
		# Decode the event - this will also call the event handlers with the decoded parameters
		evtinfo.decode(_update_control.edec)


#### Chat system
# In this function the sender is part of the argument because it corresponds to
# the original message sender. When the server broadcasts this, obtaining this
# value from get_rpc_sender_id() will not be correct if message came from a client.
remote func chat_message(sender: int, msg: String, broadcast: bool) -> void:
	if (get_tree().is_network_server()):
		if (broadcast):
			# This message is meant to be sent to everyone, iterate through every connected player
			# However, skip the sender, which should handle the message locally
			for pid in player_data.remote_player:
				if (sender != pid):
					rpc_id(pid, "chat_message", sender, msg, broadcast)
		
		# Check if the sender is the server's player, in which case return from here otherwise
		# the message may be handled twice - in a way, skip the sender.
		if (sender == 1):
			return
	
	# This is "everyone code". Just emit a signal indicating that a new chat
	# message has arrived
	emit_signal("chat_message_received", msg, sender)



# This is a "wrapper" function used to send chat messages without having to deal with
# the rpc() function. If the second argument is set to 0, then the message will be
# broadcast, otherwise it will be sent to the specified peer id.
func send_chat_message(msg: String, send_to: int = 0) -> void:
	# The "sender" here corresponds to the local machine. So, obtain the unique ID
	var sender: int = get_tree().get_network_unique_id()
	if (send_to != 0):
		rpc_id(send_to, "chat_message_received", sender, msg, false)
	else:
		if (sender != 1):
			rpc_id(1, "chat_message_received", sender, msg, true)
		else:
			chat_message(1, msg, true)


### Custom player property system
# This function is meant to be called by clients and only run on the server. It should
# broadcast the specified property to all connected clients skipping the one that
# called it.
remote func _server_broadcast_custom_prop(pname: String, value) -> void:
	if (!has_authority()):
		return
	
	var caller: int = get_tree().get_rpc_sender_id()
	for pid in player_data.remote_player:
		if (pid != caller):
			player_data.remote_player[pid].rpc_id(pid, "_rem_set_custom_property", pname, value)

# When a property is changed within the player node, it may require to broadcast
# the value through the server. To make things easier, each player node will hold a
# FuncRef pointing to this function, which in turn remotely calls the server's
# 'server_broadcast_custom_prop()' function.
func _custom_prop_broadcast_requester(pname: String, value) -> void:
	if (has_authority()):
		return
	
	rpc_id(1, "_server_broadcast_custom_prop", pname, value)



### "Signalers"
### Rather than "forcing" this class to connect functions to signals of the various
### subsystems and then emitting yet another signal, those subsystems will use FuncRef
### to call the "signalers" here, which will then emit the signals to the outside code
func _ping_signaler(pid: int, ping: float) -> void:
	emit_signal("ping_updated", pid, ping)

func _custom_property_signaler(pid: int, pname: String, value) -> void:
	emit_signal("custom_property_changed", pid, pname, value)


#### Setter/Getter
func noset(_v) -> void:
	pass

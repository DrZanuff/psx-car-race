extends Node

class_name RaceController

@onready var _player : CarController = self.get_parent()

var _active_event: RaceEvent = null
var _active_nodes: Array[RaceNode] = []
var _current_index: int = -1

func _ready() -> void:
	_hide_gps()
	_sync_active_event()

func _process(_delta: float) -> void:
	_sync_active_event()

func _sync_active_event() -> void:
	if _player.current_event == _active_event:
		return
	_stop_active_race()
	if not _is_event_valid(_player.current_event):
		return
	_start_race_event(_player.current_event)

func _is_event_valid(event: RaceEvent) -> bool:
	if event == null or event.race_nodes.size() < 2:
		return false
	for node in event.race_nodes:
		if node == null:
			return false
	return true

func _start_race_event(event: RaceEvent) -> void:
	_active_event = event
	_active_nodes = event.race_nodes.duplicate()
	_current_index = 0
	_set_nodes_controller(self)
	_show_only_node(_current_index)
	_set_gps_target(_current_index)

func _stop_active_race() -> void:
	_set_nodes_controller(null)
	_hide_all_nodes()
	_hide_gps()
	_active_event = null
	_active_nodes.clear()
	_current_index = -1

func _finish_race() -> void:
	_stop_active_race()
	_player.current_event = null
	if _player.car_ui != null:
		_player.car_ui.show_race_finished()

func advance_current_event_from_node(node: RaceNode) -> void:
	if _current_index < 0 or _current_index >= _active_nodes.size():
		return
	if node != _active_nodes[_current_index]:
		return
	_current_index += 1
	if _current_index >= _active_nodes.size():
		_finish_race()
		return
	_show_only_node(_current_index)
	_set_gps_target(_current_index)

func _show_only_node(index: int) -> void:
	for i in _active_nodes.size():
		var node: RaceNode = _active_nodes[i]
		if node == null:
			continue
		node.visible = i == index

func _hide_all_nodes() -> void:
	for node in _active_nodes:
		if node == null:
			continue
		node.visible = false

func _set_gps_target(index: int) -> void:
	if _player.gps == null:
		return
	var node: RaceNode = _active_nodes[index]
	if node == null:
		return
	_player.gps.visible = true
	_player.gps.set_point_target(node.global_position)

func _set_nodes_controller(controller: RaceController) -> void:
	for node in _active_nodes:
		if node == null:
			continue
		node.set_race_controller(controller)

func _hide_gps() -> void:
	if _player.gps == null:
		return
	_player.gps.visible = false

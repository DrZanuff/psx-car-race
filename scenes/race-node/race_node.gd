extends Area3D

class_name RaceNode

const CAR_COLLISION_LAYER_BIT: int = 2

var _race_controller: RaceController = null

func _ready() -> void:
	monitoring = true
	monitorable = true
	collision_mask |= CAR_COLLISION_LAYER_BIT
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)

func set_race_controller(race_controller: RaceController) -> void:
	_race_controller = race_controller

func _on_body_entered(body: Node3D) -> void:
	if not body is CarController:
		return
	if _race_controller == null:
		return
	_race_controller.advance_current_event_from_node(self)

extends Marker3D

class_name GPSArrow

@onready var _pivot: Marker3D = %Pivot

var _current_target: Vector3 = Vector3.ZERO

func set_point_target(global_target_position: Vector3) -> void:
	_current_target = global_target_position


func _process(delta: float) -> void:
	var y_only_target: Vector3 = _current_target
	y_only_target.y = _pivot.global_position.y
	_pivot.look_at(y_only_target)

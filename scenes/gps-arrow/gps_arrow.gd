extends Marker3D

class_name GPSArrow

@onready var _pivot: Marker3D = %Pivot

var _current_target: Vector3 = Vector3.ZERO

func set_point_target(global_target_position: Vector3) -> void:
	_current_target = global_target_position


func _process(_delta: float) -> void:
	var to_target: Vector3 = _current_target - _pivot.global_position
	to_target.y = 0.0
	if to_target.length_squared() <= 0.0001:
		return
	_pivot.global_rotation.y = atan2(-to_target.x, -to_target.z)

extends MarginContainer

class_name CarUI

@onready var _speed_label: Label = %SpeedLabel

func set_speed_label(value: float) -> void:
	_speed_label.text = "%dkm" % int(value)

extends MarginContainer

class_name CarUI

@onready var _speed_label: Label = %SpeedLabel
@onready var _race_finish_label = %RaceFinishLabel
@onready var _animation: AnimationPlayer = %AnimationPlayer

func set_speed_label(value: float) -> void:
	_speed_label.text = "%dkm" % int(value)

func show_race_finished() -> void:
	_animation.play("show_finish_label")

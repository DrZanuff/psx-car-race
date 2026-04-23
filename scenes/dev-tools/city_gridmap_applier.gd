@tool
extends Node
## Editor tool that fills two [GridMap] nodes with a generated city.
##
## Road generation works in module coordinates, then writes GridMap cell coordinates.
## A road module is one square road tile of [member road_stride_cells] by
## [member road_stride_cells] cells.
## Road meshes are expected to have their X/Z pivot at the tile center.
## Buildings are placed only in modules that are not roads and whose occupied
## footprint does not overlap roads or previously placed buildings.

class_name CityGridMapApplier

const DIR_N := 1
const DIR_E := 2
const DIR_S := 4
const DIR_W := 8

const ROAD_STRAIGHT_MASK := DIR_N | DIR_S
const ROAD_CORNER_MASK := DIR_E | DIR_S
const ROAD_TJUNCTION_MASK := DIR_N | DIR_E | DIR_S
const ROAD_JUNCTION_MASK := DIR_N | DIR_E | DIR_S | DIR_W

## GridMap that receives road tiles. Its MeshLibrary must contain the named road items below.
@export var roads_grid_map: GridMap
## GridMap that receives building tiles. Buildings are placed after roads so they can avoid road occupancy.
@export var buildings_grid_map: GridMap

@export_group("City")
## Number of road/building modules along GridMap X. Bigger values make the city wider.
@export_range(1, 128, 1) var module_width: int = 9
## Number of road/building modules along GridMap Z. Bigger values make the city deeper.
@export_range(1, 128, 1) var module_depth: int = 9
## Base spacing between main grid roads, measured in modules. Lower values make more roads and fewer building lots.
@export_range(1, 8, 1) var road_interval_modules: int = 3
## Size of one generated road tile in GridMap cells. This must match the visual footprint of a centered-pivot road mesh.
@export_range(1, 64, 1) var road_stride_cells: int = 8
## Empty cells reserved around road footprints before placing buildings. Too high leaves no buildable land.
@export_range(0, 16, 1) var building_clearance_cells: int = 1
## If true, offsets the generated city so its tile area is centered around the GridMap origin.
@export var center_city_on_origin: bool = true
## Seed used for repeatable road variation, building choices, building rotations, and building positions.
@export var random_seed: int = 12345

@export_group("Road Variation")
## Chance to remove eligible road modules from the base grid. Higher values make a less perfect grid but can create dead areas.
@export_range(0.0, 1.0, 0.01) var road_gap_chance: float = 0.08
## Chance to add stair-step road paths between main grid intersections. Higher values add more jogged, organic streets.
@export_range(0.0, 1.0, 0.01) var stair_step_chance: float = 0.28
## Number of modules near the city edge that should not be removed by road_gap_chance.
@export_range(0, 4, 1) var protected_border_modules: int = 1
## If true, keeps a horizontal and vertical main road through the city center.
@export var keep_center_cross: bool = true
## If true, keeps each base-grid intersection and its immediate arms so 4-way junctions are not accidentally pruned.
@export var preserve_main_intersections: bool = true

@export_group("Road Item Names")
## MeshLibrary item name for a road corner. The base orientation is configured by ROAD_CORNER_MASK in this script.
@export var road_corner_item_name: StringName = &"road_1_corner"
## MeshLibrary item name for a 4-way road junction.
@export var road_junction_item_name: StringName = &"road_1_junction"
## MeshLibrary item name for a straight road. Its base orientation is vertical on GridMap Z.
@export var road_straight_item_name: StringName = &"road_1_straight"
## MeshLibrary item name for a T-junction road. The base orientation points right, connecting north/east/south.
@export var road_tjunction_item_name: StringName = &"road_1_Tjunction"
## Extra quarter-turns applied to every corner road after connection matching. Use this if the mesh import orientation differs.
@export_range(0, 3, 1) var road_corner_rotation_offset: int = 0
## Extra quarter-turns applied to every straight road after connection matching. Use this if vertical/horizontal roads are swapped.
@export_range(0, 3, 1) var road_straight_rotation_offset: int = 0
## Extra quarter-turns applied to every T-junction after connection matching. Use this if T-roads face the wrong way.
@export_range(0, 3, 1) var road_tjunction_rotation_offset: int = 0

@export_group("Building Placement")
## Chance per placement attempt to try a building. At 1.0 every attempt is used, but placement can still fail due to occupancy.
@export_range(0.0, 1.0, 0.01) var building_density: float = 0.78
## Placement attempts per non-road module. Higher values fill more buildings, especially with small footprints.
@export_range(1, 16, 1) var building_attempts_per_block: int = 4
## If true, stops after placing one building in a module. Keep enabled for city blocks with one main building footprint.
@export var one_building_per_module: bool = true
## If true, buildings are placed at the center of their module. If false, placement is randomized inside the module.
@export var center_buildings_in_module: bool = true
## Fallback building footprint width in GridMap cells when mesh AABB sizing is disabled or unavailable.
@export_range(1, 64, 1) var default_building_width_cells: int = 4
## Fallback building footprint depth in GridMap cells when mesh AABB sizing is disabled or unavailable.
@export_range(1, 64, 1) var default_building_depth_cells: int = 4
## Empty cells reserved around each placed building before trying another building.
@export_range(0, 16, 1) var building_spacing_cells: int = 1
## Upper limit for generated building occupancy in GridMap cells. Set to 0 to use the full measured or fallback footprint.
@export_range(0, 32, 1) var max_building_footprint_cells: int = 0
## If true, estimates each centered building footprint from its mesh AABB before applying the max footprint cap.
@export var use_mesh_aabb_for_building_size: bool = true
## Optional allow-list of building MeshLibrary item names. Empty means any building item may be used.
@export var allowed_building_item_names: PackedStringArray = PackedStringArray()

@export_group("Actions")
## Clears both GridMaps and applies a newly generated city with the current inspector settings.
@export_tool_button("Apply City", "GridMap") var apply_city_action = _apply_city
## Clears both target GridMaps.
@export_tool_button("Clear City", "Clear") var clear_city_action = _clear_city

var _rng := RandomNumberGenerator.new()
var _road_modules := {}


func _apply_city() -> void:
	if not _validate_grid_maps():
		return

	_rng.seed = random_seed
	_clear_city()

	var road_ids := _resolve_road_items()
	if road_ids.is_empty():
		return

	var origin := _city_origin()
	var road_modules := _build_road_module_set()
	_road_modules = road_modules
	var occupied := {}

	_apply_roads(road_modules, road_ids, origin, occupied)
	_apply_buildings(origin, occupied)
	_push_status("Applied city: %d road modules, %d occupied cells." % [road_modules.size(), occupied.size()])


func _clear_city() -> void:
	if roads_grid_map != null:
		roads_grid_map.clear()
	if buildings_grid_map != null:
		buildings_grid_map.clear()
	_push_status("Cleared city GridMaps.")


func _validate_grid_maps() -> bool:
	if roads_grid_map == null:
		_push_status("roads_grid_map is not assigned.")
		return false
	if buildings_grid_map == null:
		_push_status("buildings_grid_map is not assigned.")
		return false
	if roads_grid_map.mesh_library == null:
		_push_status("roads_grid_map has no MeshLibrary.")
		return false
	if buildings_grid_map.mesh_library == null:
		_push_status("buildings_grid_map has no MeshLibrary.")
		return false
	return true


func _resolve_road_items() -> Dictionary:
	var ids := {
		"corner": _find_item_id(roads_grid_map.mesh_library, road_corner_item_name),
		"junction": _find_item_id(roads_grid_map.mesh_library, road_junction_item_name),
		"straight": _find_item_id(roads_grid_map.mesh_library, road_straight_item_name),
		"tjunction": _find_item_id(roads_grid_map.mesh_library, road_tjunction_item_name),
	}

	for key in ids:
		if int(ids[key]) == -1:
			_push_status("Could not find road item '%s'." % key)
			return {}
	return ids


func _build_road_module_set() -> Dictionary:
	var roads := {}
	var interval := maxi(road_interval_modules, 1)

	for x in range(module_width):
		for z in range(module_depth):
			if x % interval == 0 or z % interval == 0:
				roads[Vector2i(x, z)] = true

	_prune_roads(roads)
	_repair_main_intersections(roads, interval)
	_add_stair_steps(roads, interval)

	return roads


func _add_stair_steps(roads: Dictionary, interval: int) -> void:
	var chance := _float_or(stair_step_chance, 0.28)
	if chance <= 0.0 or module_width < 3 or module_depth < 3:
		return

	for x in range(interval, module_width - interval, interval):
		for z in range(interval, module_depth - interval, interval):
			if _rng.randf() > chance:
				continue

			var horizontal_first := _rng.randf() < 0.5
			var x_dir := -1 if _rng.randf() < 0.5 else 1
			var z_dir := -1 if _rng.randf() < 0.5 else 1
			var start := Vector2i(x, z)
			var end := start + Vector2i(x_dir * interval, z_dir * interval)

			_add_stair_path(roads, start, end, horizontal_first)


func _add_stair_path(roads: Dictionary, from_pos: Vector2i, to_pos: Vector2i, horizontal_first: bool) -> void:
	var step := Vector2i(_int_sign(to_pos.x - from_pos.x), _int_sign(to_pos.y - from_pos.y))
	var current := from_pos
	var move_x_next := horizontal_first
	roads[current] = true

	while current != to_pos:
		if move_x_next and current.x != to_pos.x:
			current.x += step.x
		elif not move_x_next and current.y != to_pos.y:
			current.y += step.y
		elif current.x != to_pos.x:
			current.x += step.x
		elif current.y != to_pos.y:
			current.y += step.y

		if _is_in_city(current):
			roads[current] = true

		move_x_next = not move_x_next


func _prune_roads(roads: Dictionary) -> void:
	var chance := _float_or(road_gap_chance, 0.08)
	if chance <= 0.0:
		return

	var protected := _protected_road_modules()
	for module_pos_variant in roads.keys():
		var module_pos: Vector2i = module_pos_variant
		if protected.has(module_pos):
			continue
		if _rng.randf() <= chance and _can_remove_road(roads, module_pos):
			roads.erase(module_pos)


func _protected_road_modules() -> Dictionary:
	var protected := {}
	var border := _int_or(protected_border_modules, 1)
	for x in range(module_width):
		for z in range(module_depth):
			var module_pos := Vector2i(x, z)
			if x < border or z < border or x >= module_width - border or z >= module_depth - border:
				protected[module_pos] = true

	if keep_center_cross:
		var center_x := int(floor(float(module_width) * 0.5))
		var center_z := int(floor(float(module_depth) * 0.5))
		for x in range(module_width):
			protected[Vector2i(x, center_z)] = true
		for z in range(module_depth):
			protected[Vector2i(center_x, z)] = true

	if preserve_main_intersections:
		var interval := maxi(road_interval_modules, 1)
		for x in range(0, module_width, interval):
			for z in range(0, module_depth, interval):
				var intersection := Vector2i(x, z)
				protected[intersection] = true
				for offset in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
					var arm = intersection + offset
					if _is_in_city(arm):
						protected[arm] = true

	return protected


func _repair_main_intersections(roads: Dictionary, interval: int) -> void:
	if not preserve_main_intersections:
		return

	for x in range(0, module_width, interval):
		for z in range(0, module_depth, interval):
			var intersection := Vector2i(x, z)
			roads[intersection] = true
			for offset in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
				var arm = intersection + offset
				if _is_in_city(arm):
					roads[arm] = true


func _can_remove_road(roads: Dictionary, module_pos: Vector2i) -> bool:
	var neighbors := _road_neighbor_count(roads, module_pos)
	return neighbors >= 3


func _road_neighbor_count(roads: Dictionary, module_pos: Vector2i) -> int:
	var count := 0
	for offset in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
		if roads.has(module_pos + offset):
			count += 1
	return count


func _is_in_city(module_pos: Vector2i) -> bool:
	return module_pos.x >= 0 and module_pos.y >= 0 and module_pos.x < module_width and module_pos.y < module_depth


func _apply_roads(road_modules: Dictionary, road_ids: Dictionary, origin: Vector2i, occupied: Dictionary) -> void:
	var clearance := _effective_building_clearance()
	for module_pos_variant in road_modules.keys():
		var module_pos: Vector2i = module_pos_variant
		var mask := _road_connection_mask(module_pos, road_modules)
		var tile := _road_tile_for_mask(mask, road_ids)
		if tile.is_empty():
			continue

		var cell := _module_center_cell(module_pos, origin)
		var item_id := int(tile["item_id"])
		var bounds := _road_bounds_cells()
		roads_grid_map.set_cell_item(Vector3i(cell.x, 0, cell.y), item_id, int(tile["orientation"]))
		_mark_bounds(occupied, cell, bounds, clearance)


func _apply_buildings(origin: Vector2i, occupied: Dictionary) -> void:
	var building_ids := _building_item_ids()
	if building_ids.is_empty():
		_push_status("No building items available.")
		return

	for mx in range(module_width):
		for mz in range(module_depth):
			var module_pos := Vector2i(mx, mz)
			var module_key := Vector2i(mx, mz)

			if _road_modules.has(module_key):
				continue

			var attempts := maxi(1, _int_or(building_attempts_per_block, 6))
			for _attempt in range(attempts):
				if _rng.randf() > building_density:
					continue

				var item_id := int(building_ids[_rng.randi_range(0, building_ids.size() - 1)])
				var rotation_quarters := _rng.randi_range(0, 3)
				var bounds := _item_bounds_cells(buildings_grid_map, item_id, rotation_quarters)
				var placed_cell := _building_cell_for_module(module_pos, origin, bounds)

				if _bounds_are_free(occupied, placed_cell, bounds):
					var orientation := _orthogonal_y(buildings_grid_map, rotation_quarters)
					buildings_grid_map.set_cell_item(Vector3i(placed_cell.x, 0, placed_cell.y), item_id, orientation)
					_mark_bounds(occupied, placed_cell, bounds, building_spacing_cells)
					if one_building_per_module:
						break


func _road_connection_mask(module_pos: Vector2i, road_modules: Dictionary) -> int:
	var mask := 0
	if road_modules.has(module_pos + Vector2i(0, -1)):
		mask |= DIR_N
	if road_modules.has(module_pos + Vector2i(1, 0)):
		mask |= DIR_E
	if road_modules.has(module_pos + Vector2i(0, 1)):
		mask |= DIR_S
	if road_modules.has(module_pos + Vector2i(-1, 0)):
		mask |= DIR_W
	return mask


func _road_tile_for_mask(mask: int, road_ids: Dictionary) -> Dictionary:
	if mask == ROAD_JUNCTION_MASK:
		return {"item_id": road_ids["junction"], "orientation": 0, "rotation_quarters": 0}

	if _bit_count(mask) == 3:
		var tjunction_rotation := _road_rotation(_rotation_to_match(ROAD_TJUNCTION_MASK, mask), road_tjunction_rotation_offset)
		return {
			"item_id": road_ids["tjunction"],
			"orientation": _orthogonal_y(roads_grid_map, -tjunction_rotation),
			"rotation_quarters": tjunction_rotation,
		}

	if _bit_count(mask) == 2:
		if mask == ROAD_STRAIGHT_MASK:
			var straight_ns_rotation := _road_rotation(0, road_straight_rotation_offset)
			return {
				"item_id": road_ids["straight"],
				"orientation": _orthogonal_y(roads_grid_map, straight_ns_rotation),
				"rotation_quarters": straight_ns_rotation,
			}
		if mask == (DIR_E | DIR_W):
			var straight_ew_rotation := _road_rotation(1, road_straight_rotation_offset)
			return {
				"item_id": road_ids["straight"],
				"orientation": _orthogonal_y(roads_grid_map, straight_ew_rotation),
				"rotation_quarters": straight_ew_rotation,
			}

		var corner_rotation := _road_rotation(_rotation_to_match(ROAD_CORNER_MASK, mask), road_corner_rotation_offset)
		return {
			"item_id": road_ids["corner"],
			"orientation": _orthogonal_y(roads_grid_map, corner_rotation),
			"rotation_quarters": corner_rotation,
		}

	if _bit_count(mask) == 1:
		var straight_rotation := _road_rotation(0 if mask & (DIR_N | DIR_S) else 1, road_straight_rotation_offset)
		return {
			"item_id": road_ids["straight"],
			"orientation": _orthogonal_y(roads_grid_map, straight_rotation),
			"rotation_quarters": straight_rotation,
		}

	return {}


func _road_rotation(base_rotation: int, offset: Variant) -> int:
	if offset == null:
		offset = 0
	return posmod(base_rotation + int(offset), 4)


func _rotation_to_match(base_mask: int, wanted_mask: int) -> int:
	for rotation in range(4):
		if _rotate_mask(base_mask, rotation) == wanted_mask:
			return rotation
	return 0


func _rotate_mask(mask: int, quarters: int) -> int:
	var result := mask
	for i in range(posmod(quarters, 4)):
		var rotated := 0
		if result & DIR_N:
			rotated |= DIR_E
		if result & DIR_E:
			rotated |= DIR_S
		if result & DIR_S:
			rotated |= DIR_W
		if result & DIR_W:
			rotated |= DIR_N
		result = rotated
	return result


func _building_item_ids() -> Array[int]:
	var ids: Array[int] = []
	var library := buildings_grid_map.mesh_library

	for item_id in library.get_item_list():
		var item_name := String(library.get_item_name(item_id))
		if allowed_building_item_names.is_empty() or allowed_building_item_names.has(item_name):
			ids.append(item_id)

	return ids


func _item_bounds_cells(grid_map: GridMap, item_id: int, rotation_quarters: int) -> Rect2i:
	var default_size := Vector2i(default_building_width_cells, default_building_depth_cells)
	var bounds := _centered_bounds(default_size)
	var mesh := grid_map.mesh_library.get_item_mesh(item_id)
	if mesh != null and use_mesh_aabb_for_building_size:
		var aabb := mesh.get_aabb()
		var cell_size := grid_map.cell_size
		var size := Vector2i(
			maxi(1, ceili(aabb.size.x / cell_size.x)),
			maxi(1, ceili(aabb.size.z / cell_size.z))
		)
		bounds = _centered_bounds(size)

	var max_footprint := _int_or(max_building_footprint_cells, 0)
	if max_footprint > 0 and (bounds.size.x > max_footprint or bounds.size.y > max_footprint):
		bounds = _centered_bounds(
			Vector2i(
				mini(bounds.size.x, max_footprint),
				mini(bounds.size.y, max_footprint)
			)
		)

	return _rotated_bounds(bounds, rotation_quarters)


func _road_bounds_cells() -> Rect2i:
	var size := maxi(1, road_stride_cells)
	return _centered_bounds(Vector2i(size, size))


func _centered_bounds(size: Vector2i) -> Rect2i:
	return Rect2i(
		Vector2i(-int(floor(float(size.x) * 0.5)), -int(floor(float(size.y) * 0.5))),
		size
	)


func _rotated_bounds(bounds: Rect2i, rotation_quarters: int) -> Rect2i:
	var corners := [
		bounds.position,
		bounds.position + Vector2i(bounds.size.x, 0),
		bounds.position + Vector2i(0, bounds.size.y),
		bounds.position + bounds.size,
	]

	var min_pos := Vector2i(2147483647, 2147483647)
	var max_pos := Vector2i(-2147483648, -2147483648)
	for corner in corners:
		var rotated := _rotate_cell_offset(corner, rotation_quarters)
		min_pos.x = mini(min_pos.x, rotated.x)
		min_pos.y = mini(min_pos.y, rotated.y)
		max_pos.x = maxi(max_pos.x, rotated.x)
		max_pos.y = maxi(max_pos.y, rotated.y)

	return Rect2i(min_pos, max_pos - min_pos)


func _rotate_cell_offset(offset: Vector2i, rotation_quarters: int) -> Vector2i:
	match posmod(rotation_quarters, 4):
		0:
			return offset
		1:
			return Vector2i(offset.y, -offset.x)
		2:
			return Vector2i(-offset.x, -offset.y)
		3:
			return Vector2i(-offset.y, offset.x)
	return offset


func _building_cell_for_module(module_pos: Vector2i, origin: Vector2i, bounds: Rect2i) -> Vector2i:
	var center_cell := _module_center_cell(module_pos, origin)
	if center_buildings_in_module:
		return center_cell

	var base_cell := _module_origin_cell(module_pos, origin)
	var free_span := maxi(1, road_stride_cells)
	var max_offset_x := maxi(0, free_span - bounds.size.x)
	var max_offset_z := maxi(0, free_span - bounds.size.y)
	var offset := Vector2i(_rng.randi_range(0, max_offset_x), _rng.randi_range(0, max_offset_z))
	return base_cell + offset - bounds.position


func _effective_building_clearance() -> int:
	var max_clearance := maxi(0, int(floor(float(road_stride_cells) * 0.25)))
	var requested_clearance := _int_or(building_clearance_cells, 1)
	var clearance := mini(requested_clearance, max_clearance)
	if requested_clearance > max_clearance:
		_push_status(
			"building_clearance_cells=%d is too high for road_stride_cells=%d; using %d for this apply."
			% [requested_clearance, road_stride_cells, clearance]
		)
	return clearance


func _city_origin() -> Vector2i:
	if not center_city_on_origin:
		return Vector2i.ZERO

	var width_cells := (module_width - 1) * road_stride_cells
	var depth_cells := (module_depth - 1) * road_stride_cells
	return Vector2i(-int(floor(float(width_cells) * 0.5)), -int(floor(float(depth_cells) * 0.5)))


func _module_center_cell(module_pos: Vector2i, origin: Vector2i) -> Vector2i:
	return origin + module_pos * road_stride_cells


func _module_origin_cell(module_pos: Vector2i, origin: Vector2i) -> Vector2i:
	var half := int(floor(float(road_stride_cells) * 0.5))
	return _module_center_cell(module_pos, origin) - Vector2i(half, half)


func _mark_bounds(occupied: Dictionary, pivot_cell: Vector2i, bounds: Rect2i, clearance: int) -> void:
	var origin := pivot_cell + bounds.position
	for x in range(origin.x - clearance, origin.x + bounds.size.x + clearance):
		for z in range(origin.y - clearance, origin.y + bounds.size.y + clearance):
			occupied[Vector2i(x, z)] = true


func _bounds_are_free(occupied: Dictionary, pivot_cell: Vector2i, bounds: Rect2i) -> bool:
	var origin := pivot_cell + bounds.position
	for x in range(origin.x, origin.x + bounds.size.x):
		for z in range(origin.y, origin.y + bounds.size.y):
			if occupied.has(Vector2i(x, z)):
				return false
	return true


func _orthogonal_y(grid_map: GridMap, quarters: int) -> int:
	var basis := Basis().rotated(Vector3.UP, float(posmod(quarters, 4)) * TAU * 0.25)
	return grid_map.get_orthogonal_index_from_basis(basis)


func _find_item_id(library: MeshLibrary, item_name: StringName) -> int:
	for item_id in library.get_item_list():
		if library.get_item_name(item_id) == item_name:
			return item_id
	return -1


func _bit_count(mask: int) -> int:
	var count := 0
	for bit in [DIR_N, DIR_E, DIR_S, DIR_W]:
		if mask & bit:
			count += 1
	return count


func _int_sign(value: int) -> int:
	if value < 0:
		return -1
	if value > 0:
		return 1
	return 0


func _int_or(value: Variant, fallback: int) -> int:
	if value == null:
		return fallback
	return int(value)


func _float_or(value: Variant, fallback: float) -> float:
	if value == null:
		return fallback
	return float(value)


func _push_status(message: String) -> void:
	print("[CityGridMapApplier] %s" % message)

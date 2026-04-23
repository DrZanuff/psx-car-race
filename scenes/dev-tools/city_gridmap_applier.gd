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
const ROAD_CORNER_ITEM_NAME := &"road_1_corner"
const ROAD_JUNCTION_ITEM_NAME := &"road_1_junction"
const ROAD_STRAIGHT_ITEM_NAME := &"road_1_straight"
const ROAD_TJUNCTION_ITEM_NAME := &"road_1_Tjunction"
const ROAD_CORNER_ROTATION_OFFSET := 0
const ROAD_STRAIGHT_ROTATION_OFFSET := 0
const ROAD_TJUNCTION_ROTATION_OFFSET := 0
const DEFAULT_BUILDING_FOOTPRINT_CELLS := Vector2i(4, 4)
const PROTECTED_BORDER_MODULES := 1
const KEEP_CENTER_CROSS := true
const PRESERVE_MAIN_INTERSECTIONS := true
const MIN_LARGE_BLOCK_MODULES := 4
const TREE_TERRAIN_SMALL_ITEM_NAME := &"TreeTerrainSmall"
const TREE_TERRAIN_LARGE_ITEM_NAME := &"TreeTerrainLarge"
const GENERATED_TREE_AREAS_NAME := "GeneratedTreeAreas"
const GENERATED_TREE_AREA_META := &"generated_by_city_gridmap_applier"

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
## Chance to carve road-free superblocks after the normal road network is built. Higher values create larger empty lots for big buildings.
@export_range(0.0, 1.0, 0.01) var road_free_lot_chance: float = 0.12
## Width and depth, in modules, of each road-free superblock carved by road_free_lot_chance.
@export_range(1, 8, 1) var road_free_lot_size_modules: int = 3

@export_group("Building Placement")
## Chance per buildable module to try one building. Placement can still fail if no building footprint fits.
@export_range(0.0, 1.0, 0.01) var building_density: float = 0.78
## Chance for a multi-module open block to get one centered large building before smaller per-module buildings are placed.
@export_range(0.0, 1.0, 0.01) var large_block_building_chance: float = 0.25
## If true, chooses the largest building candidate that fits the block before falling back to smaller buildings.
@export var prefer_larger_buildings: bool = true
## Empty cells reserved around each placed building before trying another building.
@export_range(0, 16, 1) var building_spacing_cells: int = 1
## Extra cells added to each measured building footprint during overlap checks. Raise this if roofs/walls still clip.
@export_range(0, 16, 1) var building_footprint_padding_cells: int = 0

@export_group("Tree Areas")
## Chance per buildable module to place TreeTerrainSmall or TreeTerrainLarge instead of a building.
@export_range(0.0, 1.0, 0.01) var tree_area_chance: float = 0.18
## Scene node whose Mesh will be copied into generated MultiMeshInstance3D tree areas.
@export var tree_source_mesh_node: Node3D
## If true, each tree gets a random Y rotation inside the terrain tile.
@export var tree_random_rotation: bool = true
## Scale variance around 1.0 for each tree. For example, 0.2 produces random scales from 0.8 to 1.2.
@export_range(0.0, 1.0, 0.01) var tree_random_scale: float = 0.0
## Number of tree instances generated inside each TreeTerrainSmall or TreeTerrainLarge GridMap tile.
@export_range(0, 1024, 1) var tree_amount_per_area: int = 64

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
	_clear_generated_tree_areas()
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
		"corner": _find_item_id(roads_grid_map.mesh_library, ROAD_CORNER_ITEM_NAME),
		"junction": _find_item_id(roads_grid_map.mesh_library, ROAD_JUNCTION_ITEM_NAME),
		"straight": _find_item_id(roads_grid_map.mesh_library, ROAD_STRAIGHT_ITEM_NAME),
		"tjunction": _find_item_id(roads_grid_map.mesh_library, ROAD_TJUNCTION_ITEM_NAME),
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
	_carve_road_free_lots(roads, interval)
	_remove_dead_end_roads(roads)

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
	var run_length := maxi(2, int(ceil(float(maxi(abs(to_pos.x - from_pos.x), abs(to_pos.y - from_pos.y))) * 0.5)))
	roads[current] = true

	while current != to_pos:
		if move_x_next:
			current = _add_stair_run(roads, current, Vector2i(step.x, 0), run_length, to_pos)
			current = _add_stair_run(roads, current, Vector2i(0, step.y), run_length, to_pos)
		else:
			current = _add_stair_run(roads, current, Vector2i(0, step.y), run_length, to_pos)
			current = _add_stair_run(roads, current, Vector2i(step.x, 0), run_length, to_pos)

		move_x_next = not move_x_next


func _add_stair_run(
	roads: Dictionary,
	from_pos: Vector2i,
	step: Vector2i,
	max_steps: int,
	to_pos: Vector2i
) -> Vector2i:
	if step == Vector2i.ZERO:
		return from_pos

	var current := from_pos
	for _i in range(max_steps):
		if step.x != 0 and current.x == to_pos.x:
			break
		if step.y != 0 and current.y == to_pos.y:
			break

		current += step
		if _is_in_city(current):
			roads[current] = true

	return current


func _carve_road_free_lots(roads: Dictionary, interval: int) -> void:
	var chance := _float_or(road_free_lot_chance, 0.12)
	if chance <= 0.0 or module_width < 3 or module_depth < 3:
		return

	var lot_size := maxi(1, _int_or(road_free_lot_size_modules, 3))
	var before_center := int(floor(float(lot_size - 1) * 0.5))
	var after_center := lot_size - before_center - 1

	for x in range(interval, module_width - interval, interval):
		for z in range(interval, module_depth - interval, interval):
			if _rng.randf() > chance:
				continue

			var center := Vector2i(x, z)
			for rx in range(center.x - before_center, center.x + after_center + 1):
				for rz in range(center.y - before_center, center.y + after_center + 1):
					var module_pos := Vector2i(rx, rz)
					if _can_carve_road_free_lot_cell(module_pos):
						roads.erase(module_pos)


func _can_carve_road_free_lot_cell(module_pos: Vector2i) -> bool:
	if not _is_in_city(module_pos):
		return false

	var border := PROTECTED_BORDER_MODULES
	if module_pos.x < border or module_pos.y < border:
		return false
	if module_pos.x >= module_width - border or module_pos.y >= module_depth - border:
		return false

	return not (KEEP_CENTER_CROSS and _is_center_cross_module(module_pos))


func _remove_dead_end_roads(roads: Dictionary) -> void:
	var changed := true
	while changed:
		changed = false
		var to_remove := []

		for module_pos_variant in roads.keys():
			var module_pos: Vector2i = module_pos_variant
			if _is_dead_end_cleanup_protected(module_pos):
				continue
			if _road_neighbor_count(roads, module_pos) <= 1:
				to_remove.append(module_pos)

		for module_pos in to_remove:
			roads.erase(module_pos)
			changed = true


func _is_dead_end_cleanup_protected(module_pos: Vector2i) -> bool:
	var border := PROTECTED_BORDER_MODULES
	if module_pos.x < border or module_pos.y < border:
		return true
	if module_pos.x >= module_width - border or module_pos.y >= module_depth - border:
		return true

	return KEEP_CENTER_CROSS and _is_center_cross_module(module_pos)


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
	var border := PROTECTED_BORDER_MODULES
	for x in range(module_width):
		for z in range(module_depth):
			var module_pos := Vector2i(x, z)
			if x < border or z < border or x >= module_width - border or z >= module_depth - border:
				protected[module_pos] = true

	if KEEP_CENTER_CROSS:
		for x in range(module_width):
			protected[Vector2i(x, _center_module_z())] = true
		for z in range(module_depth):
			protected[Vector2i(_center_module_x(), z)] = true

	if PRESERVE_MAIN_INTERSECTIONS:
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
	if not PRESERVE_MAIN_INTERSECTIONS:
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


func _is_center_cross_module(module_pos: Vector2i) -> bool:
	return module_pos.x == _center_module_x() or module_pos.y == _center_module_z()


func _center_module_x() -> int:
	return int(floor(float(module_width) * 0.5))


func _center_module_z() -> int:
	return int(floor(float(module_depth) * 0.5))


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
	var tree_terrain_ids := _tree_terrain_item_ids()
	if building_ids.is_empty() and tree_terrain_ids.is_empty():
		_push_status("No building items available.")
		return

	var claimed_modules := {}
	if not building_ids.is_empty():
		_apply_large_block_buildings(origin, occupied, building_ids, claimed_modules)

	for mx in range(module_width):
		for mz in range(module_depth):
			var module_pos := Vector2i(mx, mz)
			var module_key := Vector2i(mx, mz)

			if _road_modules.has(module_key):
				continue
			if claimed_modules.has(module_key):
				continue

			if not tree_terrain_ids.is_empty() and _rng.randf() <= tree_area_chance:
				var tree_candidate := _pick_tree_terrain_candidate(module_pos, origin, occupied, tree_terrain_ids)
				if not tree_candidate.is_empty():
					_place_tree_terrain_candidate(tree_candidate, occupied)
					continue

			if _rng.randf() > building_density:
				continue
			if building_ids.is_empty():
				continue

			var candidate := _pick_building_candidate(module_pos, origin, occupied, building_ids)
			if candidate.is_empty():
				continue

			var item_id := int(candidate["item_id"])
			var rotation_quarters := int(candidate["rotation_quarters"])
			var bounds: Rect2i = candidate["bounds"]
			var placed_cell: Vector2i = candidate["placed_cell"]
			var orientation := _orthogonal_y(buildings_grid_map, rotation_quarters)
			buildings_grid_map.set_cell_item(Vector3i(placed_cell.x, 0, placed_cell.y), item_id, orientation)
			_mark_bounds(occupied, placed_cell, bounds, building_spacing_cells)


func _apply_large_block_buildings(
	origin: Vector2i,
	occupied: Dictionary,
	building_ids: Array[int],
	claimed_modules: Dictionary
) -> void:
	var chance := _float_or(large_block_building_chance, 0.25)
	if chance <= 0.0:
		return

	var min_large_area := _minimum_large_building_area()
	for block_variant in _open_module_components():
		var block: Array = block_variant
		if block.size() < MIN_LARGE_BLOCK_MODULES:
			continue
		if _rng.randf() > chance:
			continue

		var center_cell := _block_center_cell(block, origin)
		var candidate := _pick_building_candidate_at_center(center_cell, occupied, building_ids, min_large_area)
		if candidate.is_empty():
			continue

		var item_id := int(candidate["item_id"])
		var rotation_quarters := int(candidate["rotation_quarters"])
		var bounds: Rect2i = candidate["bounds"]
		var placed_cell: Vector2i = candidate["placed_cell"]
		var orientation := _orthogonal_y(buildings_grid_map, rotation_quarters)
		buildings_grid_map.set_cell_item(Vector3i(placed_cell.x, 0, placed_cell.y), item_id, orientation)
		_mark_bounds(occupied, placed_cell, bounds, building_spacing_cells)

		for module_pos in block:
			claimed_modules[module_pos] = true


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
		var tjunction_rotation := _road_rotation(_rotation_to_match(ROAD_TJUNCTION_MASK, mask), ROAD_TJUNCTION_ROTATION_OFFSET)
		return {
			"item_id": road_ids["tjunction"],
			"orientation": _orthogonal_y(roads_grid_map, -tjunction_rotation),
			"rotation_quarters": tjunction_rotation,
		}

	if _bit_count(mask) == 2:
		if mask == ROAD_STRAIGHT_MASK:
			var straight_ns_rotation := _road_rotation(0, ROAD_STRAIGHT_ROTATION_OFFSET)
			return {
				"item_id": road_ids["straight"],
				"orientation": _orthogonal_y(roads_grid_map, straight_ns_rotation),
				"rotation_quarters": straight_ns_rotation,
			}
		if mask == (DIR_E | DIR_W):
			var straight_ew_rotation := _road_rotation(1, ROAD_STRAIGHT_ROTATION_OFFSET)
			return {
				"item_id": road_ids["straight"],
				"orientation": _orthogonal_y(roads_grid_map, straight_ew_rotation),
				"rotation_quarters": straight_ew_rotation,
			}

		var corner_rotation := _road_rotation(_rotation_to_match(ROAD_CORNER_MASK, mask), ROAD_CORNER_ROTATION_OFFSET)
		return {
			"item_id": road_ids["corner"],
			"orientation": _orthogonal_y(roads_grid_map, corner_rotation),
			"rotation_quarters": corner_rotation,
		}

	if _bit_count(mask) == 1:
		var straight_rotation := _road_rotation(0 if mask & (DIR_N | DIR_S) else 1, ROAD_STRAIGHT_ROTATION_OFFSET)
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
		var item_name := library.get_item_name(item_id)
		if item_name == TREE_TERRAIN_SMALL_ITEM_NAME or item_name == TREE_TERRAIN_LARGE_ITEM_NAME:
			continue
		ids.append(item_id)

	return ids


func _tree_terrain_item_ids() -> Array[int]:
	var ids: Array[int] = []
	var large_id := _find_item_id(buildings_grid_map.mesh_library, TREE_TERRAIN_LARGE_ITEM_NAME)
	var small_id := _find_item_id(buildings_grid_map.mesh_library, TREE_TERRAIN_SMALL_ITEM_NAME)

	if large_id != -1:
		ids.append(large_id)
	if small_id != -1:
		ids.append(small_id)

	return ids


func _pick_tree_terrain_candidate(
	module_pos: Vector2i,
	origin: Vector2i,
	occupied: Dictionary,
	tree_terrain_ids: Array[int]
) -> Dictionary:
	var center_cell := _module_center_cell(module_pos, origin)
	for item_id in tree_terrain_ids:
		var bounds := _item_bounds_cells(buildings_grid_map, item_id, 0)
		var placed_cell := _building_cell_for_center_cell(center_cell, bounds)
		if _bounds_are_free(occupied, placed_cell, bounds):
			return {
				"item_id": item_id,
				"bounds": bounds,
				"placed_cell": placed_cell,
			}

	return {}


func _place_tree_terrain_candidate(candidate: Dictionary, occupied: Dictionary) -> void:
	var item_id := int(candidate["item_id"])
	var bounds: Rect2i = candidate["bounds"]
	var placed_cell: Vector2i = candidate["placed_cell"]

	buildings_grid_map.set_cell_item(Vector3i(placed_cell.x, 0, placed_cell.y), item_id, 0)
	_mark_bounds(occupied, placed_cell, bounds, building_spacing_cells)
	_populate_tree_area(item_id, placed_cell, bounds)


func _open_module_components() -> Array:
	var components := []
	var visited := {}
	var offsets := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

	for mx in range(module_width):
		for mz in range(module_depth):
			var start := Vector2i(mx, mz)
			if visited.has(start) or _road_modules.has(start):
				continue

			var component := []
			var queue := [start]
			visited[start] = true

			while not queue.is_empty():
				var current: Vector2i = queue.pop_back()
				component.append(current)

				for offset in offsets:
					var neighbor = current + offset
					if not _is_in_city(neighbor):
						continue
					if visited.has(neighbor) or _road_modules.has(neighbor):
						continue

					visited[neighbor] = true
					queue.append(neighbor)

			components.append(component)

	return components


func _block_center_cell(block: Array, origin: Vector2i) -> Vector2i:
	var min_module := Vector2i(2147483647, 2147483647)
	var max_module := Vector2i(-2147483648, -2147483648)

	for module_pos_variant in block:
		var module_pos: Vector2i = module_pos_variant
		min_module.x = mini(min_module.x, module_pos.x)
		min_module.y = mini(min_module.y, module_pos.y)
		max_module.x = maxi(max_module.x, module_pos.x)
		max_module.y = maxi(max_module.y, module_pos.y)

	var min_cell := _module_center_cell(min_module, origin)
	var max_cell := _module_center_cell(max_module, origin)
	return Vector2i(
		int(round(float(min_cell.x + max_cell.x) * 0.5)),
		int(round(float(min_cell.y + max_cell.y) * 0.5))
	)


func _pick_building_candidate(
	module_pos: Vector2i,
	origin: Vector2i,
	occupied: Dictionary,
	building_ids: Array[int]
) -> Dictionary:
	return _pick_building_candidate_at_center(
		_module_center_cell(module_pos, origin),
		occupied,
		building_ids,
		0
	)


func _pick_building_candidate_at_center(
	center_cell: Vector2i,
	occupied: Dictionary,
	building_ids: Array[int],
	min_area: int
) -> Dictionary:
	var candidates := []

	for item_id in building_ids:
		var rotation_start := _rng.randi_range(0, 3)
		for rotation_index in range(4):
			var rotation_quarters := posmod(rotation_start + rotation_index, 4)
			var bounds := _item_bounds_cells(buildings_grid_map, item_id, rotation_quarters)
			var placed_cell := _building_cell_for_center_cell(center_cell, bounds)
			var area := bounds.size.x * bounds.size.y

			if min_area > 0 and area < min_area:
				continue

			if _bounds_are_free(occupied, placed_cell, bounds):
				candidates.append({
					"item_id": item_id,
					"rotation_quarters": rotation_quarters,
					"bounds": bounds,
					"placed_cell": placed_cell,
					"area": area,
				})
				break

	if candidates.is_empty():
		return {}

	if not prefer_larger_buildings:
		return candidates[_rng.randi_range(0, candidates.size() - 1)]

	var largest_area := 0
	for candidate in candidates:
		largest_area = maxi(largest_area, int(candidate["area"]))

	var largest_candidates := []
	for candidate in candidates:
		if int(candidate["area"]) == largest_area:
			largest_candidates.append(candidate)

	return largest_candidates[_rng.randi_range(0, largest_candidates.size() - 1)]


func _minimum_large_building_area() -> int:
	return maxi(16, int(round(float(road_stride_cells * road_stride_cells) * 0.5)))


func _item_bounds_cells(grid_map: GridMap, item_id: int, rotation_quarters: int) -> Rect2i:
	var bounds := _centered_bounds(DEFAULT_BUILDING_FOOTPRINT_CELLS)
	var mesh := grid_map.mesh_library.get_item_mesh(item_id)
	if mesh != null:
		var aabb := _transformed_aabb(mesh.get_aabb(), grid_map.mesh_library.get_item_mesh_transform(item_id))
		var cell_size := grid_map.cell_size
		var min_cell := Vector2i(
			floori(aabb.position.x / cell_size.x),
			floori(aabb.position.z / cell_size.z)
		)
		var max_cell := Vector2i(
			ceili((aabb.position.x + aabb.size.x) / cell_size.x),
			ceili((aabb.position.z + aabb.size.z) / cell_size.z)
		)
		bounds = Rect2i(min_cell, Vector2i(maxi(1, max_cell.x - min_cell.x), maxi(1, max_cell.y - min_cell.y)))

	var padding := maxi(0, _int_or(building_footprint_padding_cells, 0))
	if padding > 0:
		bounds = _padded_bounds(bounds, padding)

	return _rotated_bounds(bounds, rotation_quarters)


func _road_bounds_cells() -> Rect2i:
	var size := maxi(1, road_stride_cells)
	return _centered_bounds(Vector2i(size, size))


func _centered_bounds(size: Vector2i) -> Rect2i:
	return Rect2i(
		Vector2i(-int(floor(float(size.x) * 0.5)), -int(floor(float(size.y) * 0.5))),
		size
	)


func _padded_bounds(bounds: Rect2i, padding: int) -> Rect2i:
	return Rect2i(
		bounds.position - Vector2i(padding, padding),
		bounds.size + Vector2i(padding * 2, padding * 2)
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
	return _building_cell_for_center_cell(center_cell, bounds)


func _building_cell_for_center_cell(center_cell: Vector2i, bounds: Rect2i) -> Vector2i:
	return center_cell - _bounds_center_offset(bounds)


func _bounds_center_offset(bounds: Rect2i) -> Vector2i:
	return bounds.position + Vector2i(
		int(floor(float(bounds.size.x) * 0.5)),
		int(floor(float(bounds.size.y) * 0.5))
	)


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


func _populate_tree_area(item_id: int, placed_cell: Vector2i, bounds: Rect2i) -> void:
	var source_mesh_instance := _tree_source_mesh_instance()
	if source_mesh_instance == null or source_mesh_instance.mesh == null:
		if tree_amount_per_area > 0:
			_push_status("tree_source_mesh_node is not assigned to a MeshInstance3D; skipping tree MultiMesh.")
		return

	var amount := maxi(0, _int_or(tree_amount_per_area, 64))
	if amount <= 0:
		return

	var parent := _ensure_generated_tree_parent()
	if parent == null:
		return

	var tree_area := MultiMeshInstance3D.new()
	tree_area.name = "Trees_%s_%d_%d" % [
		buildings_grid_map.mesh_library.get_item_name(item_id),
		placed_cell.x,
		placed_cell.y,
	]
	tree_area.set_meta(GENERATED_TREE_AREA_META, true)
	parent.add_child(tree_area)
	_assign_generated_owner(tree_area)

	var area_origin := buildings_grid_map.map_to_local(Vector3i(placed_cell.x, 0, placed_cell.y))
	tree_area.global_transform = Transform3D(Basis(), buildings_grid_map.to_global(area_origin))
	tree_area.material_override = source_mesh_instance.material_override

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = source_mesh_instance.mesh
	multimesh.instance_count = amount
	tree_area.multimesh = multimesh

	for index in range(amount):
		multimesh.set_instance_transform(index, _random_tree_transform_in_area(bounds))


func _random_tree_transform_in_area(bounds: Rect2i) -> Transform3D:
	var cell_size := buildings_grid_map.cell_size
	var offset := Vector3(
		(float(bounds.position.x) + _rng.randf() * float(bounds.size.x)) * cell_size.x,
		0.0,
		(float(bounds.position.y) + _rng.randf() * float(bounds.size.y)) * cell_size.z
	)
	var rotation := _rng.randf() * TAU if tree_random_rotation else 0.0
	var scale_variance := clampf(_float_or(tree_random_scale, 0.0), 0.0, 1.0)
	var scale := 1.0 + _rng.randf_range(-scale_variance, scale_variance)
	var basis := Basis().rotated(Vector3.UP, rotation).scaled(Vector3.ONE * scale)
	return Transform3D(basis, offset)


func _tree_source_mesh_instance() -> MeshInstance3D:
	if tree_source_mesh_node == null:
		return null
	if tree_source_mesh_node is MeshInstance3D:
		return tree_source_mesh_node as MeshInstance3D
	return _find_first_mesh_instance(tree_source_mesh_node)


func _find_first_mesh_instance(node: Node) -> MeshInstance3D:
	for child in node.get_children():
		if child is MeshInstance3D:
			return child as MeshInstance3D

		var child_mesh := _find_first_mesh_instance(child)
		if child_mesh != null:
			return child_mesh

	return null


func _ensure_generated_tree_parent() -> Node3D:
	var parent := buildings_grid_map.get_parent()
	if parent == null:
		return null

	var existing := parent.get_node_or_null(GENERATED_TREE_AREAS_NAME)
	if existing != null and existing is Node3D:
		return existing as Node3D

	var generated := Node3D.new()
	generated.name = GENERATED_TREE_AREAS_NAME
	generated.set_meta(GENERATED_TREE_AREA_META, true)
	parent.add_child(generated)
	_assign_generated_owner(generated)
	return generated


func _clear_generated_tree_areas() -> void:
	if buildings_grid_map == null or buildings_grid_map.get_parent() == null:
		return

	var parent := buildings_grid_map.get_parent()
	var generated := parent.get_node_or_null(GENERATED_TREE_AREAS_NAME)
	if generated == null:
		return

	generated.free()


func _assign_generated_owner(node: Node) -> void:
	if not Engine.is_editor_hint():
		return

	var scene_owner := owner
	if scene_owner == null and get_tree() != null:
		scene_owner = get_tree().edited_scene_root
	node.owner = scene_owner


func _transformed_aabb(aabb: AABB, transform: Transform3D) -> AABB:
	var result := AABB(transform * aabb.position, Vector3.ZERO)
	var aabb_end := aabb.position + aabb.size
	for x in [aabb.position.x, aabb_end.x]:
		for y in [aabb.position.y, aabb_end.y]:
			for z in [aabb.position.z, aabb_end.z]:
				result = result.expand(transform * Vector3(x, y, z))
	return result


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

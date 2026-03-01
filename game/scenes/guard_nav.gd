extends RefCounted

const _COUNTER_CENTER := Vector2(-3.5, -4.0)
const _COUNTER_HALF_X := 1.8
const _COUNTER_HALF_Z := 0.5
const _GATE_ZONE_POS := Vector2(-5.55, -4.6)
const _GATE_ZONE_SIZE := Vector2(1.1, 1.2)

func guard_counter_rect(counter_avoid_margin_x: float, counter_avoid_margin_z: float) -> Rect2:
	var half_x := _COUNTER_HALF_X + counter_avoid_margin_x
	var half_z := _COUNTER_HALF_Z + counter_avoid_margin_z
	var min_x := _COUNTER_CENTER.x - half_x
	var min_z := _COUNTER_CENTER.y - half_z
	return Rect2(Vector2(min_x, min_z), Vector2(half_x * 2.0, half_z * 2.0))

func guard_gate_zone_rect() -> Rect2:
	return Rect2(_GATE_ZONE_POS, _GATE_ZONE_SIZE)

func clamp_to_shop(pos: Vector3, shop_bounds_min: Vector2, shop_bounds_max: Vector2, world_margin: float) -> Vector3:
	var clamped := pos
	clamped.x = clampf(clamped.x, shop_bounds_min.x + world_margin, shop_bounds_max.x - world_margin)
	clamped.z = clampf(clamped.z, shop_bounds_min.y + world_margin, shop_bounds_max.y - world_margin)
	return clamped

func point_in_counter(pos: Vector3, counter_avoid_margin_x: float, counter_avoid_margin_z: float) -> bool:
	var rect := guard_counter_rect(counter_avoid_margin_x, counter_avoid_margin_z)
	return rect.has_point(Vector2(pos.x, pos.z))

func point_in_gate_zone(pos: Vector3) -> bool:
	return guard_gate_zone_rect().has_point(Vector2(pos.x, pos.z))

func sanitize_target(
	target: Vector3,
	prefer_left: bool,
	shop_bounds_min: Vector2,
	shop_bounds_max: Vector2,
	world_margin: float,
	counter_avoid_margin_x: float,
	counter_avoid_margin_z: float
) -> Vector3:
	var sanitized := clamp_to_shop(target, shop_bounds_min, shop_bounds_max, world_margin)
	if not point_in_counter(sanitized, counter_avoid_margin_x, counter_avoid_margin_z) and not point_in_gate_zone(sanitized):
		return sanitized

	var counter_rect := guard_counter_rect(counter_avoid_margin_x, counter_avoid_margin_z)
	var left_x := clampf(counter_rect.position.x - 0.18, shop_bounds_min.x + world_margin, shop_bounds_max.x - world_margin)
	var right_x := clampf(counter_rect.end.x + 0.18, shop_bounds_min.x + world_margin, shop_bounds_max.x - world_margin)
	var back_z := clampf(counter_rect.position.y - 0.14, shop_bounds_min.y + world_margin, shop_bounds_max.y - world_margin)
	var front_z := clampf(counter_rect.end.y + 0.14, shop_bounds_min.y + world_margin, shop_bounds_max.y - world_margin)

	sanitized.x = left_x if prefer_left else right_x
	sanitized.z = back_z if absf(target.z - back_z) <= absf(target.z - front_z) else front_z

	if point_in_gate_zone(sanitized):
		var gate_rect := guard_gate_zone_rect()
		if prefer_left:
			sanitized.x = minf(sanitized.x, gate_rect.position.x - 0.24)
		else:
			sanitized.x = maxf(sanitized.x, gate_rect.end.x + 0.24)
	return clamp_to_shop(sanitized, shop_bounds_min, shop_bounds_max, world_margin)

func rebuild_path(
	from_pos: Vector3,
	target_pos: Vector3,
	guard_chasing_player: bool,
	shop_bounds_min: Vector2,
	shop_bounds_max: Vector2,
	world_margin: float,
	counter_avoid_margin_x: float,
	counter_avoid_margin_z: float,
	left_corridor_inset: float,
	chase_route_side: int = -1
) -> Array[Vector3]:
	var path_points: Array[Vector3] = []
	var route_side := -1 if chase_route_side <= 0 else 1
	var sanitized_target := sanitize_target(
		target_pos,
		route_side < 0,
		shop_bounds_min,
		shop_bounds_max,
		world_margin,
		counter_avoid_margin_x,
		counter_avoid_margin_z
	)
	var from_2d := Vector2(from_pos.x, from_pos.z)
	var target_2d := Vector2(sanitized_target.x, sanitized_target.z)
	var counter_rect := guard_counter_rect(counter_avoid_margin_x, counter_avoid_margin_z)
	var back_z := clampf(counter_rect.position.y - counter_avoid_margin_z, shop_bounds_min.y + world_margin, shop_bounds_max.y - world_margin)
	var front_z := clampf(counter_rect.end.y + counter_avoid_margin_z, shop_bounds_min.y + world_margin, shop_bounds_max.y - world_margin)
	var start_back := from_2d.y <= counter_rect.position.y
	var target_back := target_2d.y <= counter_rect.position.y
	var y := from_pos.y

	if guard_chasing_player:
		# Deterministic key-side route avoids oscillation around the counter edge.
		var left_offset := maxf(0.18, left_corridor_inset + 0.12)
		var corridor_x := counter_rect.position.x - left_offset if route_side < 0 else counter_rect.end.x + left_offset
		var side_wall_buffer := world_margin + 0.18
		corridor_x = clampf(corridor_x, shop_bounds_min.x + side_wall_buffer, shop_bounds_max.x - side_wall_buffer)
		var approach_lane_z := back_z
		var target_lane_z := sanitized_target.z
		if target_lane_z > counter_rect.position.y and target_lane_z < counter_rect.end.y:
			target_lane_z = back_z if target_back else front_z

		var gate_rect := guard_gate_zone_rect()
		var near_gate_band := route_side < 0 and from_pos.z >= gate_rect.position.y - 0.08 and from_pos.z <= gate_rect.end.y + 0.08
		if near_gate_band and absf(from_pos.z - approach_lane_z) > 0.03:
			# Exit gate blocker depth first to prevent horizontal clipping/repath loops.
			path_points.append(Vector3(from_pos.x, y, approach_lane_z))
		if absf(from_pos.x - corridor_x) > 0.03:
			var lane_z_for_left := approach_lane_z if near_gate_band else from_pos.z
			path_points.append(Vector3(corridor_x, y, lane_z_for_left))
		if absf((approach_lane_z if near_gate_band else from_pos.z) - approach_lane_z) > 0.03:
			path_points.append(Vector3(corridor_x, y, approach_lane_z))
		if absf(approach_lane_z - target_lane_z) > 0.03:
			path_points.append(Vector3(corridor_x, y, target_lane_z))
		if absf(sanitized_target.x - corridor_x) > 0.03:
			path_points.append(Vector3(sanitized_target.x, y, target_lane_z))
	elif segment_hits_rect(from_2d, target_2d, counter_rect):
		var left_x := clampf(counter_rect.position.x - counter_avoid_margin_x, shop_bounds_min.x + world_margin, shop_bounds_max.x - world_margin)
		var right_x := clampf(counter_rect.end.x + counter_avoid_margin_x, shop_bounds_min.x + world_margin, shop_bounds_max.x - world_margin)
		var left_cost := absf(from_2d.x - left_x) + absf(target_2d.x - left_x)
		var right_cost := absf(from_2d.x - right_x) + absf(target_2d.x - right_x)
		var bypass_x := left_x if left_cost <= right_cost else right_x

		if start_back != target_back:
			var start_lane_non_chase := back_z if start_back else front_z
			var target_lane_non_chase := back_z if target_back else front_z
			path_points.append(Vector3(bypass_x, y, start_lane_non_chase))
			path_points.append(Vector3(bypass_x, y, target_lane_non_chase))
		else:
			var same_lane := back_z if start_back else front_z
			path_points.append(Vector3(bypass_x, y, same_lane))

	var final_point := Vector3(sanitized_target.x, y, sanitized_target.z)
	if path_points.is_empty() or path_points[path_points.size() - 1].distance_to(final_point) > 0.03:
		path_points.append(final_point)
	return _compact_path(path_points)

func segment_hits_rect(a: Vector2, b: Vector2, rect: Rect2) -> bool:
	if rect.has_point(a) or rect.has_point(b):
		return true
	for i in range(1, 13):
		var t := float(i) / 12.0
		var p := a.lerp(b, t)
		if rect.has_point(p):
			return true
	return false

func _compact_path(points: Array[Vector3]) -> Array[Vector3]:
	var compacted: Array[Vector3] = []
	for point in points:
		if compacted.is_empty() or compacted[compacted.size() - 1].distance_to(point) > 0.05:
			compacted.append(point)
	return compacted

extends Node3D
class_name GuardController

const GuardNavigator = preload("res://scenes/guard_nav.gd")

signal captured_player

@export var shop_bounds_min := Vector2(-5.8, -7.8)
@export var shop_bounds_max := Vector2(1.3, -0.4)
@export var guard_wake_call_suspicion_threshold := 80.0
@export var guard_chase_suspicion_threshold := 82.0
@export var guard_sleep_animation := "mixamo_com"
@export var guard_wake_animation := "Standing Up/mixamo_com"
@export var guard_run_animation := "Mutant Run/mixamo_com"
@export var guard_run_speed := 3.7
@export var guard_chase_speed := 5.9
@export var guard_target_reach_distance := 0.35
@export var guard_catch_distance := 1.3
@export var guard_model_facing_offset_degrees := 180.0
@export var guard_repath_interval := 0.16
@export var guard_repath_distance := 0.55
@export var guard_chase_lock_seconds := 1.8
@export var guard_stuck_timeout_seconds := 0.65
@export var guard_stuck_distance_threshold := 0.04
@export var guard_counter_avoid_margin_x := 0.22
@export var guard_counter_avoid_margin_z := 0.48
@export var guard_world_margin := 0.14
@export var guard_left_corridor_inset := 0.06
@export var guard_path_probe_height := 1.05
@export var guard_path_probe_margin := 0.16
@export var guard_commit_repath_interval := 0.42
@export var guard_commit_repath_distance := 1.1

var guard_anim_player: AnimationPlayer
var guard_awake := false
var guard_target_active := false
var guard_target_position := Vector3.ZERO
var guard_last_seen_player_position := Vector3.ZERO
var guard_has_last_seen_player := false
var guard_chasing_player := false
var guard_path_points: Array[Vector3] = []
var guard_repath_accum := 0.0
var guard_last_path_target := Vector3.ZERO
var guard_chase_lock_until := 0.0
var guard_forced_bypass_side := 0
var guard_forced_lane_side := 0
var guard_last_position := Vector3.ZERO
var guard_stuck_elapsed := 0.0
var guard_capture_committed := false

var current_suspicion := 0.0
var key_stolen := false
var game_locked := false
var distraction_guard_grace_until := 0.0

var player_body: CharacterBody3D
var key_area: Area3D
var guard_nav := GuardNavigator.new()

func _ready():
	setup_state()

func setup_state():
	guard_awake = false
	guard_capture_committed = false
	guard_anim_player = get_node_or_null("AnimationPlayer") as AnimationPlayer
	if guard_anim_player != null:
		var finished_cb := Callable(self, "_on_guard_animation_finished")
		if not guard_anim_player.animation_finished.is_connected(finished_cb):
			guard_anim_player.animation_finished.connect(finished_cb)
		_play_guard_sleeping()
	guard_target_active = false
	guard_has_last_seen_player = false
	guard_chasing_player = false
	guard_path_points.clear()
	guard_repath_accum = 0.0
	guard_last_path_target = global_position
	guard_chase_lock_until = 0.0
	guard_forced_bypass_side = 0
	guard_forced_lane_side = 0
	guard_last_position = global_position
	guard_stuck_elapsed = 0.0

func set_player_body(body: CharacterBody3D):
	player_body = body

func set_key_area(area: Area3D):
	key_area = area

func update_runtime_state(suspicion_value: float, key_stolen_now: bool, game_locked_now: bool, grace_until: float):
	current_suspicion = suspicion_value
	key_stolen = key_stolen_now
	game_locked = game_locked_now
	distraction_guard_grace_until = grace_until

func mark_last_seen_player(world_pos: Vector3):
	guard_last_seen_player_position = world_pos
	guard_has_last_seen_player = true

func set_last_seen_player_position(world_pos: Vector3):
	guard_last_seen_player_position = world_pos
	guard_has_last_seen_player = true

func has_last_seen_player() -> bool:
	return guard_has_last_seen_player

func get_last_seen_player_position() -> Vector3:
	return guard_last_seen_player_position

func is_awake() -> bool:
	return guard_awake

func is_chasing() -> bool:
	return guard_chasing_player

func is_target_active() -> bool:
	return guard_target_active

func get_target_position() -> Vector3:
	return guard_target_position

func set_target_position(target: Vector3):
	guard_target_position = target
	guard_target_active = true

func set_capture_committed(committed: bool):
	guard_capture_committed = committed

func is_capture_committed() -> bool:
	return guard_capture_committed

func chase_locked() -> bool:
	return _guard_chase_locked()

func play_running_animation():
	_play_guard_running()

func wake_if_allowed(barnaby_called: bool = false) -> bool:
	if not _can_wake_guard(barnaby_called):
		return false
	_wake_guard()
	return guard_awake

func start_chase_if_allowed(barnaby_called: bool = false) -> bool:
	if not _can_chase_guard(barnaby_called):
		return false
	if not wake_if_allowed(barnaby_called):
		return false
	guard_capture_committed = true
	_start_guard_player_chase()
	return true

func command_to_last_seen(barnaby_called: bool = false) -> bool:
	if not guard_has_last_seen_player:
		return false
	return command_to_position(guard_last_seen_player_position, barnaby_called)

func command_to_position(world_target: Vector3, barnaby_called: bool = false) -> bool:
	if guard_capture_committed:
		return start_chase_if_allowed(true)
	if guard_chasing_player and _guard_chase_locked():
		return false
	if not wake_if_allowed(barnaby_called):
		return false
	var resolved_target := Vector3(world_target.x, global_position.y, world_target.z)
	resolved_target = _sanitize_guard_target(resolved_target, true)
	if guard_target_active and not guard_chasing_player and guard_target_position.distance_to(resolved_target) <= 0.2:
		return false
	guard_chasing_player = false
	guard_chase_lock_until = 0.0
	guard_forced_bypass_side = 0
	guard_forced_lane_side = 0
	guard_target_position = resolved_target
	guard_target_active = true
	guard_path_points.clear()
	guard_repath_accum = guard_repath_interval
	guard_last_position = global_position
	guard_stuck_elapsed = 0.0
	_face_guard_towards(guard_target_position)
	_play_guard_running()
	return true

func tick(delta: float):
	if not guard_awake:
		return
	if guard_capture_committed and not guard_target_active:
		start_chase_if_allowed(true)
		return
	if not guard_target_active:
		return
	if guard_capture_committed and not guard_chasing_player:
		start_chase_if_allowed(true)
		return

	var current_pos := global_position
	if guard_chasing_player and player_body != null:
		var player_now := Vector3(player_body.global_position.x, global_position.y, player_body.global_position.z)
		player_now = _sanitize_guard_target(player_now, true)
		guard_target_position = player_now
		if _can_guard_capture_player(current_pos, player_now):
			_emit_capture()
			return

	var moved_since_last := current_pos.distance_to(guard_last_position)
	if moved_since_last <= guard_stuck_distance_threshold:
		guard_stuck_elapsed += delta
	else:
		guard_stuck_elapsed = 0.0
	guard_last_position = current_pos

	var final_target := Vector3(guard_target_position.x, current_pos.y, guard_target_position.z)
	final_target = _sanitize_guard_target(final_target, true)
	guard_target_position = final_target
	guard_repath_accum += delta
	var active_repath_interval := guard_repath_interval
	if guard_chasing_player:
		active_repath_interval = maxf(0.09, guard_repath_interval * 0.78)
	if guard_capture_committed:
		active_repath_interval = minf(active_repath_interval, guard_commit_repath_interval)
	var should_repath := guard_path_points.is_empty()
	if guard_capture_committed:
		should_repath = should_repath or guard_repath_accum >= active_repath_interval
		should_repath = should_repath or guard_last_path_target.distance_to(final_target) > guard_commit_repath_distance
	else:
		should_repath = should_repath or guard_repath_accum >= active_repath_interval
		should_repath = should_repath or guard_last_path_target.distance_to(final_target) > guard_repath_distance
	if guard_stuck_elapsed >= guard_stuck_timeout_seconds:
		guard_stuck_elapsed = 0.0
		guard_forced_bypass_side = 0
		guard_forced_lane_side = 0
		guard_path_points.clear()
		should_repath = true
	if should_repath:
		guard_repath_accum = 0.0
		_rebuild_guard_path(current_pos, final_target)

	var target := final_target
	if not guard_path_points.is_empty():
		target = guard_path_points[0]
	var to_target := target - current_pos
	var dist := to_target.length()
	var reach_distance := guard_target_reach_distance
	if guard_chasing_player and guard_path_points.size() <= 1:
		reach_distance = guard_catch_distance
	if dist <= reach_distance:
		if not guard_path_points.is_empty():
			guard_path_points.remove_at(0)
			return
		if guard_chasing_player and not game_locked:
			var player_target := final_target
			if player_body != null:
				player_target = Vector3(player_body.global_position.x, current_pos.y, player_body.global_position.z)
			if _can_guard_capture_player(current_pos, player_target):
				_emit_capture()
				return
			guard_path_points.clear()
			_rebuild_guard_path(current_pos, player_target)
			return
		guard_target_active = false
		guard_forced_bypass_side = 0
		guard_forced_lane_side = 0
		guard_stuck_elapsed = 0.0
		return

	var dir := to_target / dist
	var speed := guard_chase_speed if guard_chasing_player else guard_run_speed
	var step := minf(dist, speed * delta)
	_face_guard_towards(target)
	var next_pos := current_pos + dir * step
	next_pos = _clamp_guard_to_shop(next_pos)
	var counter_rect := _guard_counter_rect()
	var step_from_2d := Vector2(current_pos.x, current_pos.z)
	var step_to_2d := Vector2(next_pos.x, next_pos.z)
	var blocked_by_counter := _segment_hits_rect(step_from_2d, step_to_2d, counter_rect)
	var blocked_by_world := _guard_segment_hits_blocker(current_pos, next_pos)
	if blocked_by_counter or blocked_by_world:
		guard_path_points.clear()
		_rebuild_guard_path(current_pos, final_target)
		if not guard_path_points.is_empty():
			var safe_target := guard_path_points[0]
			var safe_vec := safe_target - current_pos
			safe_vec.y = 0.0
			var safe_len := safe_vec.length()
			if safe_len > 0.001:
				var safe_step := minf(safe_len, speed * delta * 0.65)
				next_pos = current_pos + (safe_vec / safe_len) * safe_step
			else:
				var counter_rect_safe := _guard_counter_rect()
				var recovery_x := clampf(counter_rect_safe.position.x - 0.28, shop_bounds_min.x + guard_world_margin, shop_bounds_max.x - guard_world_margin)
				var recovery_z := clampf(counter_rect_safe.position.y - guard_counter_avoid_margin_z, shop_bounds_min.y + guard_world_margin, shop_bounds_max.y - guard_world_margin)
				next_pos = Vector3(recovery_x, current_pos.y, recovery_z)
		else:
			next_pos = current_pos
		next_pos = _clamp_guard_to_shop(next_pos)
		if _guard_segment_hits_blocker(current_pos, next_pos):
			next_pos = current_pos
	if _point_in_counter(next_pos):
		next_pos = _push_guard_out_of_counter(next_pos, dir)
	if _point_in_guard_gate_zone(next_pos):
		next_pos = _push_guard_out_of_gate_zone(next_pos, dir)
	global_position = next_pos

func _can_wake_guard(barnaby_called: bool = false) -> bool:
	if guard_awake:
		return true
	if current_suspicion <= guard_wake_call_suspicion_threshold:
		return false
	return barnaby_called

func _can_chase_guard(barnaby_called: bool = false) -> bool:
	if guard_chasing_player:
		return true
	if guard_capture_committed and guard_awake:
		return true
	if not guard_awake and not barnaby_called:
		return false
	if _guard_grace_active() and not barnaby_called:
		return false
	if current_suspicion >= guard_chase_suspicion_threshold:
		return guard_awake or barnaby_called
	return barnaby_called and current_suspicion > guard_wake_call_suspicion_threshold

func _guard_grace_active() -> bool:
	if key_stolen:
		return false
	var now := Time.get_ticks_msec() / 1000.0
	return now < distraction_guard_grace_until

func _guard_chase_locked() -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	return now < guard_chase_lock_until

func _wake_guard():
	if guard_awake:
		return
	guard_awake = true
	var anim_name := _resolve_guard_animation(guard_wake_animation, ["Standing Up/mixamo_com", "Standing Up"])
	if guard_anim_player != null and anim_name != "":
		guard_anim_player.play(anim_name)

func _start_guard_player_chase():
	if player_body == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	guard_chase_lock_until = maxf(guard_chase_lock_until, now + guard_chase_lock_seconds)
	var next_target := Vector3(player_body.global_position.x, global_position.y, player_body.global_position.z)
	var switching_mode := not guard_chasing_player
	guard_chasing_player = true
	guard_target_active = true
	guard_target_position = next_target
	guard_stuck_elapsed = 0.0
	guard_last_position = global_position
	var retarget_threshold: float = guard_commit_repath_distance if guard_capture_committed else guard_repath_distance
	if switching_mode or guard_last_path_target.distance_to(next_target) > retarget_threshold:
		guard_forced_bypass_side = 0
		guard_forced_lane_side = 0
		guard_path_points.clear()
		guard_repath_accum = guard_repath_interval
	_play_guard_running()
	_face_guard_towards(guard_target_position)

func _play_guard_running():
	if guard_anim_player == null:
		return
	var anim_name := _resolve_guard_animation(guard_run_animation, ["Mutant Run/mixamo_com", "Mutant Run", "Run/mixamo_com", "Run"])
	if anim_name != "":
		var anim_res := guard_anim_player.get_animation(anim_name)
		if anim_res != null and anim_res.loop_mode == Animation.LOOP_NONE:
			anim_res.loop_mode = Animation.LOOP_LINEAR
	if anim_name != "" and (guard_anim_player.current_animation != anim_name or not guard_anim_player.is_playing()):
		guard_anim_player.play(anim_name)

func _face_guard_towards(target: Vector3):
	var look_target := Vector3(target.x, global_position.y, target.z)
	if global_position.distance_to(look_target) < 0.001:
		return
	look_at(look_target, Vector3.UP)
	rotate_y(deg_to_rad(guard_model_facing_offset_degrees))

func _rebuild_guard_path(from_pos: Vector3, target_pos: Vector3):
	guard_path_points.clear()
	var sanitized_target := _sanitize_guard_target(target_pos, true)
	guard_last_path_target = sanitized_target
	guard_path_points = guard_nav.rebuild_path(
		from_pos,
		sanitized_target,
		guard_chasing_player,
		shop_bounds_min,
		shop_bounds_max,
		guard_world_margin,
		guard_counter_avoid_margin_x,
		guard_counter_avoid_margin_z,
		guard_left_corridor_inset
	)
	if not guard_chasing_player:
		guard_forced_bypass_side = 0
		guard_forced_lane_side = 0

func _guard_counter_rect() -> Rect2:
	return guard_nav.guard_counter_rect(guard_counter_avoid_margin_x, guard_counter_avoid_margin_z)

func _segment_hits_rect(a: Vector2, b: Vector2, rect: Rect2) -> bool:
	return guard_nav.segment_hits_rect(a, b, rect)

func _can_guard_capture_player(guard_pos: Vector3, player_pos: Vector3) -> bool:
	if guard_pos.distance_to(player_pos) > guard_catch_distance:
		return false
	var counter_rect := _guard_counter_rect()
	var from_2d := Vector2(guard_pos.x, guard_pos.z)
	var to_2d := Vector2(player_pos.x, player_pos.z)
	if _segment_hits_rect(from_2d, to_2d, counter_rect):
		return false
	if _guard_segment_hits_blocker(guard_pos, player_pos):
		return false
	return true

func _guard_segment_hits_blocker(from_pos: Vector3, to_pos: Vector3) -> bool:
	var path_vec := to_pos - from_pos
	path_vec.y = 0.0
	if path_vec.length() <= 0.001:
		return false

	var fwd := path_vec.normalized()
	var side := Vector3(-fwd.z, 0.0, fwd.x)
	if side.length() <= 0.001:
		side = Vector3.RIGHT
	side = side.normalized()

	var offsets: Array[Vector3] = [
		Vector3.ZERO,
		side * 0.22,
		-side * 0.22,
	]
	var heights: Array[float] = [
		0.45,
		guard_path_probe_height,
	]

	var excluded_rids: Array[RID] = []
	if player_body != null:
		excluded_rids.append(player_body.get_rid())
	if self is CollisionObject3D:
		excluded_rids.append((self as CollisionObject3D).get_rid())

	for offset in offsets:
		for probe_height in heights:
			var from_probe := from_pos + offset + Vector3(0.0, probe_height, 0.0)
			var to_probe := to_pos + offset + Vector3(0.0, probe_height, 0.0)
			var path_len := from_probe.distance_to(to_probe)
			if path_len <= 0.001:
				continue
			var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from_probe, to_probe)
			query.collide_with_bodies = true
			query.collide_with_areas = false
			query.exclude = excluded_rids
			var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
			if hit.is_empty():
				continue
			var collider_val: Variant = hit.get("collider", null)
			if collider_val is Node:
				var collider_node := collider_val as Node
				if collider_node == key_area:
					continue
				if is_ancestor_of(collider_node):
					continue
			var hit_pos_val: Variant = hit.get("position", to_probe)
			var hit_pos: Vector3 = to_probe
			if hit_pos_val is Vector3:
				hit_pos = hit_pos_val
			if from_probe.distance_to(hit_pos) < maxf(0.05, path_len - guard_path_probe_margin):
				return true
	return false

func _clamp_guard_to_shop(pos: Vector3) -> Vector3:
	return guard_nav.clamp_to_shop(pos, shop_bounds_min, shop_bounds_max, guard_world_margin)

func _point_in_counter(pos: Vector3) -> bool:
	return guard_nav.point_in_counter(pos, guard_counter_avoid_margin_x, guard_counter_avoid_margin_z)

func _guard_gate_zone_rect() -> Rect2:
	return guard_nav.guard_gate_zone_rect()

func _point_in_guard_gate_zone(pos: Vector3) -> bool:
	return guard_nav.point_in_gate_zone(pos)

func _sanitize_guard_target(target: Vector3, prefer_left: bool = true) -> Vector3:
	return guard_nav.sanitize_target(
		target,
		prefer_left,
		shop_bounds_min,
		shop_bounds_max,
		guard_world_margin,
		guard_counter_avoid_margin_x,
		guard_counter_avoid_margin_z
	)

func _push_guard_out_of_counter(pos: Vector3, move_dir: Vector3) -> Vector3:
	var corrected := pos
	var rect := _guard_counter_rect()
	var left := rect.position.x
	var right := rect.end.x
	var back := rect.position.y
	var front := rect.end.y

	var dx_left := absf(corrected.x - left)
	var dx_right := absf(right - corrected.x)
	var dz_back := absf(corrected.z - back)
	var dz_front := absf(front - corrected.z)
	var min_push := minf(minf(dx_left, dx_right), minf(dz_back, dz_front))

	if min_push == dx_left:
		corrected.x = left - 0.02
	elif min_push == dx_right:
		corrected.x = right + 0.02
	elif min_push == dz_back:
		corrected.z = back - 0.02
	else:
		corrected.z = front + 0.02

	if move_dir.length() < 0.001:
		corrected.z = front + 0.04
	return _clamp_guard_to_shop(corrected)

func _push_guard_out_of_gate_zone(pos: Vector3, move_dir: Vector3) -> Vector3:
	var rect := _guard_gate_zone_rect()
	var corrected := pos
	corrected.x = maxf(corrected.x, rect.end.x + 0.18)
	if absf(move_dir.z) > 0.05:
		corrected.z += sign(move_dir.z) * 0.08
	return _clamp_guard_to_shop(corrected)

func _emit_capture():
	if game_locked:
		return
	guard_capture_committed = false
	guard_chasing_player = false
	guard_target_active = false
	guard_chase_lock_until = 0.0
	guard_forced_bypass_side = 0
	guard_forced_lane_side = 0
	emit_signal("captured_player")

func _play_guard_sleeping():
	if guard_anim_player == null:
		return
	var anim_name := _resolve_guard_animation(guard_sleep_animation, ["mixamo_com", "Sleeping Idle/mixamo_com", "Sleeping Idle"])
	if anim_name != "":
		guard_anim_player.play(anim_name)

func _resolve_guard_animation(preferred: String, fallbacks: Array[String]) -> String:
	if guard_anim_player == null:
		return ""
	if preferred != "" and guard_anim_player.has_animation(preferred):
		return preferred
	@warning_ignore("shadowed_variable_base_class")
	for name in fallbacks:
		if guard_anim_player.has_animation(name):
			return name

	var all_names := guard_anim_player.get_animation_list()
	if preferred != "":
		var preferred_lower := preferred.to_lower()
		for candidate in all_names:
			var text := str(candidate)
			if text.to_lower().find(preferred_lower) != -1:
				return text
	for candidate in all_names:
		var text := str(candidate)
		if "standing up" in text.to_lower():
			return text
	if not all_names.is_empty():
		return str(all_names[0])
	return ""

func _on_guard_animation_finished(_anim_name: StringName):
	if guard_awake and guard_target_active:
		_play_guard_running()

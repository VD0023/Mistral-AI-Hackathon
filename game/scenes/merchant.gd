extends Node3D

@onready var anim_player: AnimationPlayer = $AnimationPlayer

@export var model_facing_offset_degrees := 180.0
@export var chase_stop_distance := 0.9
@export var chase_left_distance := 1.8
@export var chase_counter_bypass_z := -4.8
@export var chase_segment_duration := 0.42
@export var chase_final_duration := 0.8
@export var patrol_point_a := Vector3(-4.8, 0.0, -2.2)
@export var patrol_point_b := Vector3(-1.5, 0.0, -2.2)
@export var patrol_leg_duration := 1.5
@export var glance_interval_min := 2.2
@export var glance_interval_max := 4.8
@export var glance_probability := 0.45
@export var glance_max_distance := 4.6

var tint_meshes: Array[MeshInstance3D] = []
var is_patrolling := false
var is_chasing := false
var is_dialogue_animating := false
var glance_timer := 0.0
var talk_variant_index := 0
var dialogue_tween: Tween

func _ready():
	randomize()
	_collect_meshes(self)
	if anim_player and anim_player.has_animation("mixamo_com"):
		anim_player.play("mixamo_com")
	_schedule_next_glance()

func _process(delta: float):
	if is_chasing or is_patrolling or is_dialogue_animating:
		return
	glance_timer -= delta
	if glance_timer > 0.0:
		return
	_schedule_next_glance()

	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var to_cam := cam.global_position - global_position
	to_cam.y = 0.0
	if to_cam.length() > glance_max_distance:
		return
	if randf() <= clampf(glance_probability, 0.0, 1.0):
		_face_towards(cam.global_position)

func start_behavior(mood: String):
	if is_dialogue_animating:
		_apply_mood_tint(mood)
		return
	match mood:
		"hostile":
			_play("Yelling/mixamo_com")
			_apply_mood_tint(mood)
		"annoyed":
			_play("Standing Arguing/mixamo_com")
			_apply_mood_tint(mood)
		"pleased":
			_play("Talking-2/mixamo_com")
			_apply_mood_tint(mood)
		_:
			# Neutral should feel idle/observant, not constantly speaking.
			_play("mixamo_com")
			_apply_mood_tint(mood)

func play_dialogue_line(mood: String, duration_seconds: float = 1.4):
	if is_chasing:
		return
	if is_patrolling:
		stop_counter_patrol()
	is_dialogue_animating = true
	if dialogue_tween:
		dialogue_tween.kill()
	var talk_anim := _pick_talk_animation()
	_play(talk_anim)
	_apply_mood_tint(mood)

	var duration := clampf(duration_seconds, 0.8, 5.5)
	dialogue_tween = create_tween()
	dialogue_tween.tween_interval(duration)
	dialogue_tween.tween_callback(Callable(self, "_finish_dialogue_line").bind(mood))

func start_chase():
	stop_counter_patrol()
	is_chasing = true
	_play_run_animation()

	var cam := get_viewport().get_camera_3d()
	var run_target := global_position + (-global_basis.z) * 4.0
	if cam:
		run_target = cam.global_position + (-cam.global_basis.z) * chase_stop_distance
		run_target.y = global_position.y

	var tween := create_tween()
	var left_dir: Vector3 = Vector3.LEFT
	if cam:
		left_dir = -cam.global_basis.x
	left_dir.y = 0.0
	if left_dir.length() < 0.001:
		left_dir = Vector3.LEFT
	left_dir = left_dir.normalized()

	var waypoint_left: Vector3 = global_position + left_dir * chase_left_distance
	waypoint_left.y = global_position.y
	var forward_z: float = min(run_target.z, chase_counter_bypass_z)
	var waypoint_forward: Vector3 = Vector3(waypoint_left.x, global_position.y, forward_z)
	var waypoint_right: Vector3 = Vector3(run_target.x, global_position.y, forward_z)
	var waypoint_final: Vector3 = Vector3(run_target.x, global_position.y, run_target.z)

	# Force a routed chase: left to bypass the counter, then forward, then across.
	_face_towards(waypoint_left)
	if global_position.distance_to(waypoint_left) > 0.05:
		tween.tween_property(self, "global_position", waypoint_left, chase_segment_duration)

	tween.tween_callback(Callable(self, "_face_towards").bind(waypoint_forward))
	if waypoint_left.distance_to(waypoint_forward) > 0.05:
		tween.tween_property(self, "global_position", waypoint_forward, chase_segment_duration)

	tween.tween_callback(Callable(self, "_face_towards").bind(waypoint_right))
	if waypoint_forward.distance_to(waypoint_right) > 0.05:
		tween.tween_property(self, "global_position", waypoint_right, chase_segment_duration)

	tween.tween_callback(Callable(self, "_face_towards").bind(waypoint_final))
	if waypoint_right.distance_to(waypoint_final) > 0.05:
		tween.tween_property(self, "global_position", waypoint_final, chase_final_duration)

func start_counter_patrol(window_seconds: float = 8.0):
	if is_patrolling:
		return
	is_patrolling = true
	call_deferred("_run_counter_patrol", max(window_seconds, 2.0))

func stop_counter_patrol():
	is_patrolling = false

func _run_counter_patrol(window_seconds: float):
	_play_walk_animation()

	var end_time: float = Time.get_ticks_msec() / 1000.0 + window_seconds
	var point_a: Vector3 = Vector3(patrol_point_a.x, global_position.y, patrol_point_a.z)
	var point_b: Vector3 = Vector3(patrol_point_b.x, global_position.y, patrol_point_b.z)
	var go_to_a := true

	while is_patrolling and (Time.get_ticks_msec() / 1000.0) < end_time:
		var target: Vector3 = point_a if go_to_a else point_b
		_face_towards(target)
		var tween := create_tween()
		tween.tween_property(self, "global_position", target, patrol_leg_duration)
		await tween.finished
		go_to_a = not go_to_a

	is_patrolling = false
	_play_idle_animation()
	_schedule_next_glance()

func _schedule_next_glance():
	var low: float = maxf(0.4, minf(glance_interval_min, glance_interval_max))
	var high: float = maxf(low, maxf(glance_interval_min, glance_interval_max))
	glance_timer = randf_range(low, high)

func _pick_talk_animation() -> String:
	var candidates: Array[String] = [
		"Talking/mixamo_com",
		"Talking-2/mixamo_com",
		"Talking/mixamo_com",
		"Talking-2/mixamo_com",
		"Talking",
		"Talking-2",
	]
	if candidates.is_empty():
		return "mixamo_com"
	for _i in range(candidates.size()):
		var idx: int = talk_variant_index % candidates.size()
		talk_variant_index += 1
		var candidate: String = candidates[idx]
		if anim_player and anim_player.has_animation(candidate):
			return candidate
	return "mixamo_com"

func _finish_dialogue_line(mood: String):
	is_dialogue_animating = false
	if is_chasing or is_patrolling:
		return
	start_behavior(mood)
	_schedule_next_glance()

func is_dialogue_active() -> bool:
	return is_dialogue_animating

func _horizontal_direction_to(target: Vector3) -> Vector3:
	var dir = target - global_position
	dir.y = 0.0
	if dir.length() < 0.001:
		return -global_basis.z.normalized()
	return dir.normalized()

func _face_towards(target: Vector3):
	var look_target = Vector3(target.x, global_position.y, target.z)
	if global_position.distance_to(look_target) < 0.001:
		return
	look_at(look_target, Vector3.UP)
	rotate_y(deg_to_rad(model_facing_offset_degrees))

func _play(anim_name: String):
	if anim_player and anim_player.has_animation(anim_name):
		anim_player.play(anim_name)
	elif anim_player and anim_player.has_animation("mixamo_com"):
		anim_player.play("mixamo_com")

func _play_walk_animation():
	var anim_name := _resolve_animation(
		[
			"Mutant Walking/mixamo_com",
			"Mutant Walking",
			"Walking/mixamo_com",
			"Walking",
			"Walk/mixamo_com",
			"Walk",
		],
		[
			"walking",
			"walk",
		]
	)
	_play(anim_name)

func _play_run_animation():
	var anim_name := _resolve_animation(
		[
			"Mutant Run/mixamo_com",
			"Mutant Run",
			"Run/mixamo_com",
			"Run",
		],
		[
			"run",
			"sprint",
		]
	)
	_play(anim_name)

func _play_idle_animation():
	var anim_name := _resolve_animation(
		[
			"Talking/mixamo_com",
			"Talking",
			"mixamo_com",
		],
		[
			"idle",
			"talk",
			"stand",
		]
	)
	_play(anim_name)

func _resolve_animation(preferred: Array[String], keyword_fallbacks: Array[String]) -> String:
	if anim_player == null:
		return "mixamo_com"
	for candidate in preferred:
		if anim_player.has_animation(candidate):
			return candidate
	var all_names := anim_player.get_animation_list()
	for keyword in keyword_fallbacks:
		var key_lower := keyword.to_lower()
		for raw_name in all_names:
			var name := str(raw_name)
			if key_lower in name.to_lower():
				return name
	if anim_player.has_animation("mixamo_com"):
		return "mixamo_com"
	if not all_names.is_empty():
		return str(all_names[0])
	return ""

func _collect_meshes(node: Node):
	for child in node.get_children():
		if child is MeshInstance3D:
			tint_meshes.append(child)
		_collect_meshes(child)

func _apply_mood_tint(mood: String):
	match mood:
		"hostile":
			_set_tint(Color(1.0, 0.45, 0.45))
		"annoyed":
			_set_tint(Color(1.0, 0.88, 0.55))
		"pleased":
			_set_tint(Color(0.9, 1.0, 0.9))
		_:
			_set_tint(Color(1, 1, 1))

func _set_tint(color: Color):
	for mesh in tint_meshes:
		var mat = mesh.material_override
		if mat == null:
			var mesh_res: Mesh = mesh.mesh
			if mesh_res == null or mesh_res.get_surface_count() <= 0:
				continue
			mat = mesh.get_surface_override_material(0)
		if mat == null:
			continue
		var new_mat = mat.duplicate()
		if new_mat is BaseMaterial3D:
			new_mat.albedo_color = color
			mesh.material_override = new_mat

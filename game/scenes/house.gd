extends Node3D

@onready var npc_text: RichTextLabel = $CanvasLayer/PanelContainer/VBoxContainer/NPC_Text
@onready var radial_menu = $CanvasLayer/RadialMenu
@onready var black_overlay: ColorRect = $CanvasLayer/BlackOverlay
@onready var merchant: Node3D = $Merchant
@onready var camera: Camera3D = $Camera3D
@onready var exit_door: Node3D = $Door_1_Round2
@onready var placed_key: Node3D = get_node_or_null("key") as Node3D
@onready var guard: Node3D = get_node_or_null("Guard") as Node3D

@export var move_speed := 4.8
@export var mouse_sensitivity := 0.0025
@export var player_height := 0.66
@export var player_capsule_height := 1.2
@export var player_capsule_radius := 0.32
@export var interact_distance := 2.8
@export var look_up_limit_degrees := 65.0
@export var look_down_limit_degrees := 48.0
@export var merchant_interact_distance := 2.4
@export var key_interact_distance := 1.45
@export var key_hitbox_radius := 0.55
@export var exit_interact_distance := 2.1
@export var key_window_seconds := 8.0
@export var key_world_position := Vector3(-4.5, 1.05, -4.85)
@export var shop_bounds_min := Vector2(-5.8, -7.8)
@export var shop_bounds_max := Vector2(1.3, -0.4)
@export var suspicion_max := 100.0
@export var suspicion_screen_offset := Vector2(70.0, -120.0)
@export var barnaby_vision_distance := 6.8
@export var barnaby_perception_tick := 0.45
@export var seen_intensity_base := 1.0
@export var unseen_intensity_base := 0.7
@export var barnaby_fov_degrees := 72.0
@export var perception_start_delay_seconds := 1.8
@export var suspicion_close_distance := 2.6
@export var suspicion_key_distance := 1.8
@export var suspicion_movement_threshold := 0.08
@export var guard_wake_suspicion_threshold := 78.0
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
@export var guard_lane_flip_threshold := 0.38
@export var guard_counter_avoid_margin_x := 0.22
@export var guard_counter_avoid_margin_z := 0.48
@export var guard_world_margin := 0.14
@export var guard_left_corridor_inset := 0.06
@export var guard_path_probe_height := 1.05
@export var guard_path_probe_margin := 0.16
@export var guard_commit_repath_interval := 0.42
@export var guard_commit_repath_distance := 1.1
@export var distraction_guard_grace_seconds := 2.8
@export var key_merchant_safe_distance := 1.45
@export var decide_tick_seconds := 0.55
@export var hard_fail_suspicion_threshold := 85.0
@export var show_decision_debug_panel := false
@export var focus_time_scale := 0.72
@export var focus_desaturation := 0.74
@export var focus_vignette_strength := 0.26
@export var focus_merchant_label_height := 2.45
@export var focus_guard_label_height := 2.25
@export var ambient_mutter_interval_seconds := 10.0
@export var ambient_mutter_first_delay_seconds := 2.2
@export var whisper_near_distance := 1.5
@export var whisper_far_distance := 9.5
@export var whisper_near_volume_db := -2.8
@export var whisper_far_volume_db := -27.0
@export var throw_distance := 4.8
@export var throw_arc_height := 1.15
@export var throw_segment_time := 0.24
@export var throw_cleanup_seconds := 6.0

var http := HTTPRequest.new()
var world_http := HTTPRequest.new()
var decide_http := HTTPRequest.new()
var reset_http := HTTPRequest.new()
var mutter_http := HTTPRequest.new()
var last_menu_options: Array = []

var game_locked := false
var pending_choice_id := ""
var key_window_until := 0.0
var key_stolen := false
var stealing_key := false
var is_interacting := false
var suspicion_value := 12.0
var seen_tick_accum := 0.0
var unseen_tick_accum := 0.0
var world_event_in_flight := false
var decide_in_flight := false
var reset_in_flight := false
var mutter_in_flight := false
var decide_tick_accum := 0.0
var ambient_mutter_accum := 0.0
var perception_started_at := 0.0
var last_player_position := Vector3.ZERO
var last_world_emotion := "neutral"

var prompt_label: Label
var key_node: Node3D
var key_area: Area3D
var player_body: CharacterBody3D
var interact_ray: RayCast3D
var suspicion_panel: PanelContainer
var suspicion_text: Label
var suspicion_bar: ProgressBar
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
var distraction_guard_grace_until := 0.0
var guard_capture_committed := false
var recent_actions: Array[String] = []
var decision_panel: PanelContainer
var decision_label: Label
var objective_panel: PanelContainer
var objective_label: Label
var endgame_panel: PanelContainer
var endgame_title: Label
var endgame_subtitle: Label
var endgame_retry_button: Button
var endgame_fresh_button: Button
var hood_prompt_panel: PanelContainer
var awaiting_hood_choice := true
var player_hood_on := false
var focus_active := false
var focus_overlay: ColorRect
var focus_overlay_material: ShaderMaterial
var focus_merchant_label: Label3D
var focus_guard_label: Label3D
var mutter_audio_player: AudioStreamPlayer3D
var voice_audio_player: AudioStreamPlayer3D
var mutter_recently_eligible := false
var ai_last_intent := "monitor"
var ai_last_skill := "monitor"
var ai_last_confidence := 0.0
var ai_last_guard_mode := "idle"
var ai_last_threat := 0.0
var ai_last_suspect_conf := 0.0
var ai_last_temper := 18.0
var thrown_visual_root: Node3D
var throwable_templates: Dictionary = {}

var yaw := 0.0
var pitch := 0.0

enum InteractTarget { NONE, MERCHANT, KEY, EXIT }
var current_target := InteractTarget.NONE

enum StealthPhase { NEED_DISTRACTION, DISTRACTION_WINDOW, KEY_STOLEN, ESCAPED, FAILED }
var stealth_phase := StealthPhase.NEED_DISTRACTION
var fail_reason := ""

func _ready():
	add_child(http)
	http.request_completed.connect(_on_reply)
	add_child(world_http)
	world_http.request_completed.connect(_on_world_event_reply)
	add_child(decide_http)
	decide_http.request_completed.connect(_on_decide_reply)
	add_child(reset_http)
	reset_http.request_completed.connect(_on_reset_reply)
	add_child(mutter_http)
	mutter_http.request_completed.connect(_on_mutter_reply)

	if radial_menu and radial_menu.has_signal("item_selected"):
		radial_menu.item_selected.connect(_on_choice_made)
	if radial_menu and radial_menu.has_signal("canceled"):
		radial_menu.canceled.connect(_on_menu_canceled)

	if black_overlay:
		black_overlay.visible = false

	# Keep radial visuals readable, but open only on explicit interaction.
	radial_menu.show_titles = true
	radial_menu.show_item_labels = true
	radial_menu.item_label_font_size = 12
	radial_menu.center_radius = 96
	radial_menu.show_animation = true

	last_menu_options = _build_fallback_menu("neutral")
	npc_text.text = "Before you move: choose hood on or off."

	_setup_physics_player()
	_create_world_colliders()
	_spawn_key_prop()
	_create_interact_areas()
	_cache_throwable_templates()
	_create_prompt_label()
	_create_suspicion_widget()
	_create_decision_trace_widget()
	_create_objective_widget()
	_create_endgame_widget()
	_setup_focus_instinct()
	_setup_barnaby_mutter_audio()
	_setup_camera_input()
	_setup_guard_state()
	_show_hood_choice_prompt()
	_set_stealth_phase(StealthPhase.NEED_DISTRACTION)
	perception_started_at = Time.get_ticks_msec() / 1000.0
	if player_body:
		last_player_position = player_body.global_position

func _physics_process(delta: float):
	if game_locked:
		_set_focus_mode(false)
		return
	if awaiting_hood_choice:
		_set_focus_mode(false)
		return
	_update_focus_mode()
	_sync_key_interact_area()
	_update_player_movement(delta)
	_update_guard_movement(delta)
	_update_interact_target()
	_update_stealth_window_state()
	_update_barnaby_perception(delta)
	_update_decision_loop(delta)
	_update_ambient_mutter(delta)
	_update_suspicion_widget()
	_update_focus_labels()
	if stealth_phase != StealthPhase.FAILED and stealth_phase != StealthPhase.ESCAPED and suspicion_value >= hard_fail_suspicion_threshold:
		_fail_run("Suspicion reached %d%%. Barnaby calls the guard." % int(round(suspicion_value)))

func _exit_tree():
	_set_focus_mode(false)
	Engine.time_scale = 1.0

func _unhandled_input(event: InputEvent):
	if game_locked:
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
			_retry_run()
		return
	if awaiting_hood_choice:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not is_interacting:
		yaw -= event.relative.x * mouse_sensitivity
		pitch = clamp(
			pitch - event.relative.y * mouse_sensitivity,
			deg_to_rad(-look_down_limit_degrees),
			deg_to_rad(look_up_limit_degrees)
		)
		if player_body:
			player_body.rotation.y = yaw
		camera.rotation = Vector3(pitch, 0.0, 0.0)
		return

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			else:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif event.keycode == KEY_E:
			_handle_interact()
		elif event.keycode == KEY_1:
			_throw_semantic_item("coin")
		elif event.keycode == KEY_2:
			_throw_semantic_item("coin_stack_medium")
		elif event.keycode == KEY_3:
			_throw_semantic_item("bottle_A_brown")
		elif event.keycode == KEY_4:
			_throw_semantic_item("chair")
		elif event.keycode == KEY_5:
			_throw_semantic_item("Drawn Assassin's Dagger")

func _setup_camera_input():
	var euler = camera.global_basis.get_euler()
	pitch = clamp(
		euler.x,
		deg_to_rad(-look_down_limit_degrees),
		deg_to_rad(look_up_limit_degrees)
	)
	yaw = euler.y
	if player_body:
		player_body.global_rotation.y = yaw
	camera.position = Vector3(0.0, player_height, 0.0)
	camera.rotation = Vector3(pitch, 0.0, 0.0)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _update_player_movement(delta: float):
	if radial_menu and radial_menu.visible:
		return
	if is_interacting:
		return
	if player_body == null:
		return

	var movement_input := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if Input.is_key_pressed(KEY_A):
		movement_input.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		movement_input.x += 1.0
	if Input.is_key_pressed(KEY_W):
		movement_input.y += 1.0
	if Input.is_key_pressed(KEY_S):
		movement_input.y -= 1.0
	if movement_input.length() > 1.0:
		movement_input = movement_input.normalized()
	var forward := -player_body.global_basis.z
	var right := player_body.global_basis.x
	forward.y = 0.0
	right.y = 0.0
	forward = forward.normalized()
	right = right.normalized()

	var direction := (right * movement_input.x + forward * movement_input.y)
	var velocity := player_body.velocity
	if direction.length() > 0.001:
		direction = direction.normalized()
		velocity.x = direction.x * move_speed
		velocity.z = direction.z * move_speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * 8.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * 8.0 * delta)

	velocity.y = 0.0
	player_body.velocity = velocity
	player_body.move_and_slide()
	if direction.length() > 0.001:
		if move_speed >= 4.6:
			_push_recent_action("sprint")
		else:
			_push_recent_action("walk")

func _update_interact_target():
	if is_interacting:
		_set_prompt("")
		current_target = InteractTarget.NONE
		return
	if stealing_key:
		_set_prompt("")
		current_target = InteractTarget.NONE
		return
	if interact_ray == null:
		_set_prompt("")
		current_target = InteractTarget.NONE
		return

	current_target = InteractTarget.NONE
	if not interact_ray.is_colliding():
		if _try_key_soft_target():
			return
		_set_prompt("")
		return

	var collider = interact_ray.get_collider()
	var target_type := _resolve_interact_type(collider)

	if target_type == "merchant":
		current_target = InteractTarget.MERCHANT
		_set_prompt("Press E to talk to Barnaby")
		return
	if target_type == "key":
		current_target = InteractTarget.KEY
		if _can_steal_key():
			_set_prompt("Press E to steal key")
		elif stealth_phase == StealthPhase.DISTRACTION_WINDOW:
			_set_prompt("Move now. Barnaby is watching the counter.")
		else:
			_set_prompt("Talk to Barnaby, choose Look Around, then steal.")
		return
	if target_type == "exit":
		current_target = InteractTarget.EXIT
		if key_stolen:
			_set_prompt("Press E to exit")
		else:
			_set_prompt("Steal the key before exiting.")
		return

	_set_prompt("")

func _try_key_soft_target() -> bool:
	if key_stolen or key_node == null:
		return false
	var to_key := key_node.global_position - camera.global_position
	var dist := to_key.length()
	if dist > key_interact_distance:
		return false
	if dist <= 0.001:
		return false
	var camera_forward := -camera.global_basis.z.normalized()
	var facing_dot := camera_forward.dot(to_key.normalized())
	if facing_dot < 0.84:
		return false

	current_target = InteractTarget.KEY
	if _can_steal_key():
		_set_prompt("Press E to steal key")
	elif stealth_phase == StealthPhase.DISTRACTION_WINDOW:
		_set_prompt("Move now. Barnaby is watching the counter.")
	else:
		_set_prompt("Talk to Barnaby, choose Look Around, then steal.")
	return true

func _set_prompt(text: String):
	if prompt_label:
		prompt_label.text = text
		prompt_label.visible = text != ""

func _handle_interact():
	if awaiting_hood_choice:
		return
	if game_locked or stealing_key:
		return
	if radial_menu and radial_menu.visible:
		return

	match current_target:
		InteractTarget.MERCHANT:
			_open_choice_menu(last_menu_options if not last_menu_options.is_empty() else _build_fallback_menu("neutral"))
		InteractTarget.KEY:
			if _can_steal_key():
				_steal_key_sequence()
			else:
				npc_text.text = "No opening yet. Distract Barnaby first."
				_push_recent_action("failed_key_attempt")
				_send_world_event("attempt_key_without_distract", 1.0, {"hood_on": player_hood_on})
		InteractTarget.EXIT:
			if key_stolen:
				_trigger_victory()
			else:
				npc_text.text = "You cannot leave with empty hands. The key is still inside."

func _setup_physics_player():
	player_body = CharacterBody3D.new()
	player_body.name = "PlayerRuntime"
	var start_pos := camera.global_position
	var half_total_height := (player_capsule_height + player_capsule_radius * 2.0) * 0.5
	# Spawn body with feet near floor plane; camera height is applied locally.
	player_body.global_position = Vector3(
		start_pos.x,
		half_total_height + 0.02,
		start_pos.z
	)
	add_child(player_body)

	var collider := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.height = player_capsule_height
	capsule.radius = player_capsule_radius
	collider.shape = capsule
	collider.position = Vector3(0.0, player_capsule_height * 0.5 + 0.02, 0.0)
	player_body.add_child(collider)

	# Re-parent camera under the physics body so movement is collision-driven.
	var cam_global := camera.global_transform
	remove_child(camera)
	player_body.add_child(camera)
	camera.global_transform = cam_global

	interact_ray = RayCast3D.new()
	interact_ray.name = "InteractRay"
	interact_ray.target_position = Vector3(0.0, 0.0, -interact_distance)
	interact_ray.collide_with_areas = true
	interact_ray.collide_with_bodies = true
	interact_ray.enabled = true
	camera.add_child(interact_ray)

func _create_world_colliders():
	var root := Node3D.new()
	root.name = "WorldCollision"
	add_child(root)

	var floor_body := StaticBody3D.new()
	floor_body.name = "FloorCollider"
	root.add_child(floor_body)
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(10.0, 0.3, 10.0)
	floor_shape.shape = floor_box
	floor_shape.position = Vector3(-2.0, -0.15, -4.0)
	floor_body.add_child(floor_shape)

	_add_wall_collider(root, Vector3(-2.0, 1.0, -8.35), Vector3(8.6, 2.0, 0.2))
	_add_wall_collider(root, Vector3(-2.0, 1.0, 0.25), Vector3(8.6, 2.0, 0.2))
	_add_wall_collider(root, Vector3(-6.25, 1.0, -4.0), Vector3(0.2, 2.0, 8.6))
	_add_wall_collider(root, Vector3(2.25, 1.0, -4.0), Vector3(0.2, 2.0, 8.6))

	# Counter block to prevent walking through the bar area.
	var counter := StaticBody3D.new()
	counter.name = "CounterCollider"
	root.add_child(counter)
	var counter_shape := CollisionShape3D.new()
	var counter_box := BoxShape3D.new()
	counter_box.size = Vector3(3.6, 1.4, 1.0)
	counter_shape.shape = counter_box
	counter_shape.position = Vector3(-3.5, 0.7, -4.0)
	counter.add_child(counter_shape)

func _add_wall_collider(parent: Node, world_pos: Vector3, size: Vector3):
	var wall := StaticBody3D.new()
	parent.add_child(wall)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = world_pos
	wall.add_child(shape)

func _create_interact_areas():
	var merchant_area := Area3D.new()
	merchant_area.name = "MerchantInteractArea"
	merchant_area.set_meta("interact_type", "merchant")
	merchant.add_child(merchant_area)
	var merchant_shape := CollisionShape3D.new()
	var merchant_sphere := SphereShape3D.new()
	merchant_sphere.radius = 1.0
	merchant_shape.shape = merchant_sphere
	merchant_shape.position = Vector3(0.0, 1.2, 0.0)
	merchant_area.add_child(merchant_shape)

	var exit_area := Area3D.new()
	exit_area.name = "ExitInteractArea"
	exit_area.set_meta("interact_type", "exit")
	exit_door.add_child(exit_area)
	var exit_shape := CollisionShape3D.new()
	var exit_box := BoxShape3D.new()
	exit_box.size = Vector3(1.4, 2.0, 1.0)
	exit_shape.shape = exit_box
	exit_shape.position = Vector3(0.0, 1.0, 0.6)
	exit_area.add_child(exit_shape)

func _resolve_interact_type(collider: Object) -> String:
	var node := collider as Node
	while node != null:
		if node.has_meta("interact_type"):
			return str(node.get_meta("interact_type"))
		node = node.get_parent()
	return ""

func _update_barnaby_perception(delta: float):
	if merchant == null or player_body == null:
		return
	if is_interacting:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - perception_started_at < perception_start_delay_seconds:
		return

	@warning_ignore("shadowed_variable_base_class")
	var visible := _is_player_visible_to_barnaby()
	var dist := merchant.global_position.distance_to(camera.global_position)
	var move_amount := player_body.global_position.distance_to(last_player_position)
	last_player_position = player_body.global_position

	var near_key := false
	if key_node:
		near_key = camera.global_position.distance_to(key_node.global_position) <= suspicion_key_distance
	var suspicious_context := near_key or dist <= suspicion_close_distance or move_amount >= suspicion_movement_threshold

	if visible:
		guard_last_seen_player_position = player_body.global_position
		guard_has_last_seen_player = true
		seen_tick_accum += delta
		unseen_tick_accum = 0.0
		if seen_tick_accum >= barnaby_perception_tick:
			seen_tick_accum = 0.0
			if suspicious_context:
				var intensity := seen_intensity_base
				if dist < suspicion_close_distance:
					intensity += 0.5
				if near_key:
					intensity += 0.6
				if move_amount >= suspicion_movement_threshold:
					intensity += minf(0.45, move_amount * 2.1)
				_send_world_event("player_seen", intensity, {"distance": dist, "near_key": near_key, "move_amount": move_amount})
	else:
		unseen_tick_accum += delta
		seen_tick_accum = 0.0
		if unseen_tick_accum >= maxf(0.8, barnaby_perception_tick * 2.0):
			unseen_tick_accum = 0.0
			_send_world_event("player_unseen", unseen_intensity_base, {})

func _is_player_visible_to_barnaby() -> bool:
	var origin := merchant.global_position + Vector3(0.0, 1.55, 0.0)
	var target := camera.global_position
	var to_target := target - origin
	if to_target.length() > barnaby_vision_distance:
		return false
	var dir_to_target := to_target.normalized()
	var forward := -merchant.global_basis.z.normalized()
	var dot_val := forward.dot(dir_to_target)
	var min_dot := cos(deg_to_rad(barnaby_fov_degrees * 0.5))
	if dot_val < min_dot:
		return false

	var query := PhysicsRayQueryParameters3D.create(origin, target)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [player_body.get_rid()]

	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	# If nothing blocks the line between Barnaby eye and player eye, player is visible.
	return hit.is_empty()

func _send_world_event(event_type: String, intensity: float, metadata: Dictionary):
	if world_event_in_flight:
		return
	world_event_in_flight = true
	var body := JSON.stringify({
		"event_type": event_type,
		"intensity": intensity,
		"metadata": metadata,
	})
	var err := world_http.request(
		"http://127.0.0.1:8000/world_event",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		body
	)
	if err != OK:
		world_event_in_flight = false

func _cache_throwable_templates():
	throwable_templates.clear()
	for item_name in ["coin", "coin_stack_medium", "bottle_a_brown", "chair"]:
		var found: Node = _find_node_case_insensitive(self, item_name)
		if found is Node3D:
			throwable_templates[item_name] = found
	if thrown_visual_root == null:
		thrown_visual_root = Node3D.new()
		thrown_visual_root.name = "ThrownVisuals"
		add_child(thrown_visual_root)

func _find_node_case_insensitive(root: Node, target_lower: String) -> Node:
	var root_name: String = str(root.name).to_lower()
	if root_name == target_lower:
		return root
	for child in root.get_children():
		if not (child is Node):
			continue
		var found: Node = _find_node_case_insensitive(child as Node, target_lower)
		if found != null:
			return found
	return null

func _spawn_throw_fallback(item_name: String) -> Node3D:
	var mesh := MeshInstance3D.new()
	mesh.name = "ThrowFallback_%s" % item_name
	var item_lower: String = item_name.to_lower()
	var material := StandardMaterial3D.new()

	if item_lower.find("dagger") != -1:
		var blade := BoxMesh.new()
		blade.size = Vector3(0.08, 0.62, 0.08)
		mesh.mesh = blade
		material.albedo_color = Color(0.78, 0.78, 0.82)
	elif item_lower.find("coin") != -1:
		var coin_mesh := CylinderMesh.new()
		coin_mesh.top_radius = 0.14
		coin_mesh.bottom_radius = 0.14
		coin_mesh.height = 0.04
		mesh.mesh = coin_mesh
		material.albedo_color = Color(0.95, 0.78, 0.24)
	elif item_lower.find("bottle") != -1:
		var bottle_mesh := CapsuleMesh.new()
		bottle_mesh.radius = 0.1
		bottle_mesh.height = 0.38
		mesh.mesh = bottle_mesh
		material.albedo_color = Color(0.35, 0.24, 0.14)
	else:
		var box := BoxMesh.new()
		box.size = Vector3(0.3, 0.3, 0.3)
		mesh.mesh = box
		material.albedo_color = Color(0.58, 0.48, 0.4)

	material.roughness = 0.38
	mesh.material_override = material
	return mesh

func _sanitize_thrown_node(node: Node):
	if node.has_meta("interact_type"):
		node.remove_meta("interact_type")
	if node is CollisionObject3D:
		var collider := node as CollisionObject3D
		collider.collision_layer = 0
		collider.collision_mask = 0
	for child in node.get_children():
		if child is Node:
			_sanitize_thrown_node(child as Node)

func _spawn_thrown_visual(item_name: String):
	if camera == null:
		return
	if thrown_visual_root == null:
		_cache_throwable_templates()
	if thrown_visual_root == null:
		return

	var key: String = item_name.to_lower()
	var template: Node3D = null
	if throwable_templates.has(key):
		var raw_template: Variant = throwable_templates[key]
		if raw_template is Node3D:
			template = raw_template as Node3D
	if template == null:
		var resolved: Node = _find_node_case_insensitive(self, key)
		if resolved is Node3D:
			template = resolved as Node3D
			throwable_templates[key] = template

	var thrown_node: Node3D = null
	if template != null:
		var duplicated: Node = template.duplicate()
		if duplicated is Node3D:
			thrown_node = duplicated as Node3D
	if thrown_node == null:
		thrown_node = _spawn_throw_fallback(item_name)
	_sanitize_thrown_node(thrown_node)
	thrown_node.name = "Thrown_%s_%d" % [key, Time.get_ticks_msec()]
	thrown_visual_root.add_child(thrown_node)

	var start_pos: Vector3 = camera.global_position + (-camera.global_basis.z) * 0.35 + Vector3(0.0, -0.18, 0.0)
	var cast_from: Vector3 = camera.global_position + Vector3(0.0, 0.2, 0.0)
	var cast_to: Vector3 = cast_from + (-camera.global_basis.z) * throw_distance
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(cast_from, cast_to)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	if player_body != null:
		query.exclude = [player_body.get_rid()]
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	var landing_pos: Vector3 = cast_to
	if not hit.is_empty():
		var pos_val: Variant = hit.get("position", landing_pos)
		if pos_val is Vector3:
			landing_pos = pos_val
	landing_pos.y += 0.04

	var mid_pos: Vector3 = start_pos.lerp(landing_pos, 0.5) + Vector3(0.0, throw_arc_height, 0.0)
	thrown_node.global_position = start_pos
	var final_rot: Vector3 = thrown_node.rotation_degrees + Vector3(420.0, 560.0, 330.0)

	var throw_tween: Tween = create_tween()
	throw_tween.set_trans(Tween.TRANS_QUAD)
	throw_tween.set_ease(Tween.EASE_OUT)
	throw_tween.tween_property(thrown_node, "global_position", mid_pos, throw_segment_time)
	throw_tween.tween_property(thrown_node, "global_position", landing_pos, throw_segment_time * 1.15)
	throw_tween.parallel().tween_property(thrown_node, "rotation_degrees", final_rot, throw_segment_time * 2.15)
	throw_tween.tween_interval(maxf(0.6, throw_cleanup_seconds))
	throw_tween.tween_callback(Callable(thrown_node, "queue_free"))

func _throw_semantic_item(item_name: String):
	if game_locked or awaiting_hood_choice:
		return
	if is_interacting or (radial_menu and radial_menu.visible):
		return
	if item_name.strip_edges() == "":
		return
	_spawn_thrown_visual(item_name)
	npc_text.text = "You toss the %s onto the floor..." % item_name
	var action_tag := item_name.to_lower().replace(" ", "_").replace("'", "")
	_push_recent_action("threw_%s" % action_tag)
	_send_world_event("item_thrown", 1.0, {"item_name": item_name, "hood_on": player_hood_on})

func _update_decision_loop(delta: float):
	if merchant == null or player_body == null:
		return
	if decide_in_flight:
		return
	decide_tick_accum += delta
	if decide_tick_accum < decide_tick_seconds:
		return
	decide_tick_accum = 0.0

	var los := _is_player_visible_to_barnaby()
	var distance := merchant.global_position.distance_to(camera.global_position)
	var near_key := key_node != null and camera.global_position.distance_to(key_node.global_position) <= suspicion_key_distance
	var key_missing := key_stolen or key_node == null
	var speed := player_body.velocity.length()
	var last_seen_payload = null
	if guard_has_last_seen_player:
		last_seen_payload = {
			"x": guard_last_seen_player_position.x,
			"y": guard_last_seen_player_position.y,
			"z": guard_last_seen_player_position.z,
		}

	var body := JSON.stringify({
		"npc_id": "barnaby",
		"guard_id": "guard",
		"observation": {
			"hood_on": player_hood_on,
			"distance": distance,
			"los": los,
			"player_speed": speed,
			"near_key": near_key,
			"key_missing": key_missing,
			"last_seen_pos": last_seen_payload,
			"recent_actions": recent_actions,
			"interaction_active": is_interacting,
			"metadata": {
				"suspicion_hint": suspicion_value,
			},
		},
	})

	decide_in_flight = true
	var err := decide_http.request(
		"http://127.0.0.1:8000/decide",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		body
	)
	if err != OK:
		decide_in_flight = false

func _setup_barnaby_mutter_audio():
	if merchant == null:
		return
	voice_audio_player = AudioStreamPlayer3D.new()
	voice_audio_player.name = "BarnabyVoiceAudio"
	voice_audio_player.max_distance = whisper_far_distance
	voice_audio_player.unit_size = 1.0
	voice_audio_player.attenuation_filter_cutoff_hz = 5500.0
	voice_audio_player.volume_db = -3.0
	merchant.add_child(voice_audio_player)
	voice_audio_player.position = Vector3(0.0, 1.65, 0.0)

	mutter_audio_player = AudioStreamPlayer3D.new()
	mutter_audio_player.name = "BarnabyMutterAudio"
	mutter_audio_player.max_distance = whisper_far_distance
	mutter_audio_player.unit_size = 1.0
	mutter_audio_player.attenuation_filter_cutoff_hz = 4200.0
	mutter_audio_player.volume_db = whisper_far_volume_db
	merchant.add_child(mutter_audio_player)
	mutter_audio_player.position = Vector3(0.0, 1.65, 0.0)

func _update_ambient_mutter(delta: float):
	_update_mutter_volume()
	if merchant == null or mutter_audio_player == null:
		return
	if game_locked or awaiting_hood_choice or is_interacting:
		return
	if radial_menu and radial_menu.visible:
		return
	var mutter_eligible := _is_mutter_eligible()
	if not mutter_eligible:
		ambient_mutter_accum = 0.0
		mutter_recently_eligible = false
		return
	if not mutter_recently_eligible:
		var kickoff_delay := clampf(ambient_mutter_first_delay_seconds, 0.2, ambient_mutter_interval_seconds)
		ambient_mutter_accum = maxf(ambient_mutter_accum, ambient_mutter_interval_seconds - kickoff_delay)
		mutter_recently_eligible = true
	if mutter_in_flight:
		return

	ambient_mutter_accum += delta
	if ambient_mutter_accum < ambient_mutter_interval_seconds:
		return
	ambient_mutter_accum = 0.0

	var body := JSON.stringify({
		"npc_id": "barnaby",
		"intent": "investigate",
		"suspicion": suspicion_value,
		"temper": clampf(ai_last_temper, 0.0, 100.0),
		"current_skill": ai_last_skill,
		"location_hint": "counter",
	})

	mutter_in_flight = true
	var err := mutter_http.request(
		"http://127.0.0.1:8000/ambient_mutter",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		body
	)
	if err != OK:
		mutter_in_flight = false

func _is_mutter_eligible() -> bool:
	if guard_capture_committed or guard_chasing_player:
		return false
	if ai_last_intent == "investigate":
		return true
	if ai_last_skill in ["investigate_last_seen", "search_counter", "patrol_counter", "question_player"]:
		return true
	return suspicion_value >= 55.0 and not key_stolen

func _update_mutter_volume():
	if mutter_audio_player == null or merchant == null or camera == null:
		return
	var dist := camera.global_position.distance_to(merchant.global_position)
	var span := maxf(0.01, whisper_far_distance - whisper_near_distance)
	var t := clampf((dist - whisper_near_distance) / span, 0.0, 1.0)
	mutter_audio_player.volume_db = lerpf(whisper_near_volume_db, whisper_far_volume_db, t)

func _on_mutter_reply(_res, code, _headers, body):
	mutter_in_flight = false
	if code != 200:
		return
	var payload = JSON.parse_string(body.get_string_from_utf8())
	if not (payload is Dictionary):
		return
	if not bool(payload.get("generated", false)):
		return
	var text := str(payload.get("text", "")).strip_edges()
	if text == "":
		return
	var audio_b64 := str(payload.get("audio_base64", ""))
	if audio_b64 == "" or mutter_audio_player == null:
		return
	var audio_bytes: PackedByteArray = Marshalls.base64_to_raw(audio_b64)
	if audio_bytes.is_empty():
		return
	var stream := AudioStreamMP3.new()
	stream.data = audio_bytes
	mutter_audio_player.stream = stream
	_update_mutter_volume()
	mutter_audio_player.play()

func _estimate_dialogue_duration_seconds(line: String) -> float:
	var words: int = maxi(1, line.strip_edges().split(" ", false).size())
	return clampf(0.55 + float(words) * 0.23, 1.0, 5.6)

func _play_voice_from_base64(audio_b64: String) -> float:
	if audio_b64.strip_edges() == "":
		return 0.0
	if voice_audio_player == null:
		return 0.0
	var audio_bytes: PackedByteArray = Marshalls.base64_to_raw(audio_b64)
	if audio_bytes.is_empty():
		return 0.0
	var stream := AudioStreamMP3.new()
	stream.data = audio_bytes
	voice_audio_player.stream = stream
	if mutter_audio_player and mutter_audio_player.playing:
		mutter_audio_player.stop()
	voice_audio_player.play()
	var length := stream.get_length()
	if is_nan(length) or length < 0.0:
		return 0.0
	return length

func _on_world_event_reply(_res, _code, _headers, body):
	world_event_in_flight = false
	var payload = JSON.parse_string(body.get_string_from_utf8())
	if not (payload is Dictionary):
		return
	var brain_state = payload.get("brain_state", {})
	if not (brain_state is Dictionary):
		return

	suspicion_value = float(brain_state.get("suspicion", suspicion_value))
	ai_last_temper = float(brain_state.get("temper", ai_last_temper))
	var has_stolen := bool(brain_state.get("has_stolen", key_stolen))
	var thief_recognized := bool(brain_state.get("thief_recognized", false))
	var emotion := str(brain_state.get("emotion", "neutral"))
	var run_phase := str(brain_state.get("run_phase", ""))
	var run_outcome := str(brain_state.get("run_outcome", ""))
	var run_reason := str(brain_state.get("run_reason", ""))
	var action_hint := str(payload.get("action_hint", "idle"))
	var event_type := str(payload.get("event_type", ""))

	_apply_brain_run_state(run_phase, run_outcome, run_reason)

	if has_stolen:
		_set_key_stolen_world_state()

	if event_type == "start_visit":
		_handle_start_visit_state(has_stolen, thief_recognized, emotion, action_hint)

	var merchant_dialogue_busy: bool = merchant != null and merchant.has_method("is_dialogue_active") and bool(merchant.call("is_dialogue_active"))
	if merchant and not merchant_dialogue_busy and not stealing_key and not is_interacting and emotion != last_world_emotion:
		last_world_emotion = emotion
		merchant.start_behavior(emotion)
	var should_force_guard := event_type == "start_visit" and has_stolen
	if action_hint == "alert" or suspicion_value >= guard_chase_suspicion_threshold or should_force_guard:
		guard_capture_committed = true
		_start_guard_player_chase_if_allowed(true)
	elif action_hint == "investigate" and guard_awake and not guard_chasing_player:
		_command_guard_to_last_seen()

func _on_decide_reply(_res, code, _headers, body):
	decide_in_flight = false
	if code != 200:
		return
	var payload = JSON.parse_string(body.get_string_from_utf8())
	if not (payload is Dictionary):
		return

	var action := str(payload.get("action", "monitor"))
	var intent := str(payload.get("intent", "monitor"))
	var confidence := float(payload.get("confidence", 0.0))
	@warning_ignore("unused_variable")
	var reason := str(payload.get("reason", ""))
	var emotion := str(payload.get("emotion", "neutral"))
	var brain_state = payload.get("brain_state", {})
	if brain_state is Dictionary:
		suspicion_value = float(brain_state.get("suspicion", suspicion_value))
		ai_last_temper = float(brain_state.get("temper", ai_last_temper))
		var run_phase := str(brain_state.get("run_phase", ""))
		var run_outcome := str(brain_state.get("run_outcome", ""))
		var run_reason := str(brain_state.get("run_reason", ""))
		_apply_brain_run_state(run_phase, run_outcome, run_reason)

	var merchant_dialogue_busy: bool = merchant != null and merchant.has_method("is_dialogue_active") and bool(merchant.call("is_dialogue_active"))
	if merchant and not merchant_dialogue_busy and emotion != "" and not is_interacting:
		merchant.start_behavior(emotion)
	var should_chase_player := intent == "accuse" or confidence >= 0.72

	var blackboard = payload.get("blackboard", {})
	var bb_last_seen = guard_last_seen_player_position
	if blackboard is Dictionary:
		var pos = blackboard.get("last_seen_pos", null)
		if pos is Dictionary:
			bb_last_seen = _vector_from_payload(pos, bb_last_seen)
			guard_last_seen_player_position = bb_last_seen
			guard_has_last_seen_player = true

	var guard_state_payload = payload.get("guard_state", {})
	var guard_mode := ""
	var guard_target_payload: Variant = null
	if guard_state_payload is Dictionary:
		guard_mode = str(guard_state_payload.get("mode", ""))
		guard_target_payload = guard_state_payload.get("target", null)

	# Keep pursuit stable for a short lock window to avoid state thrash/flicker.
	if guard_chasing_player and _guard_chase_locked():
		if player_body != null:
			guard_target_position = Vector3(player_body.global_position.x, guard.global_position.y, player_body.global_position.z)
		_play_guard_running()
		_set_decision_trace(payload)
		return

	var key_missing_bb := false
	if blackboard is Dictionary:
		key_missing_bb = bool(blackboard.get("key_missing", false))
	var force_guard := key_missing_bb or key_stolen or (intent == "accuse" and confidence >= 0.75)
	if force_guard:
		guard_capture_committed = true

	if guard_capture_committed and not game_locked:
		if guard_chasing_player:
			if player_body != null:
				guard_target_position = Vector3(player_body.global_position.x, guard.global_position.y, player_body.global_position.z)
			guard_target_active = true
			_play_guard_running()
		else:
			_start_guard_player_chase_if_allowed(true)
		_set_decision_trace(payload)
		return

	var handled_by_guard_state := _apply_guard_state(guard_mode, guard_target_payload, bb_last_seen, should_chase_player, force_guard)
	if not handled_by_guard_state:
		match action:
			"chase_player":
				guard_capture_committed = true
				_start_guard_player_chase_if_allowed(force_guard)
			"wake_guard":
				if should_chase_player:
					guard_capture_committed = true
					_start_guard_player_chase_if_allowed(force_guard)
				elif _wake_guard_if_allowed(force_guard):
					_command_guard_to_last_seen()
			"investigate_last_seen":
				if should_chase_player:
					guard_capture_committed = true
					_start_guard_player_chase_if_allowed(force_guard)
				elif _wake_guard_if_allowed(force_guard):
					_command_guard_to_position(bb_last_seen)
			"patrol_counter":
				if merchant and merchant.has_method("start_counter_patrol") and not is_interacting:
					merchant.call("start_counter_patrol", 4.0)
			"block_exit":
				if should_chase_player:
					guard_capture_committed = true
					_start_guard_player_chase_if_allowed(force_guard)
				elif _wake_guard_if_allowed(force_guard):
					_command_guard_to_position(exit_door.global_position)
			"question_player":
				if should_chase_player:
					guard_capture_committed = true
					_start_guard_player_chase_if_allowed(force_guard)
				if not radial_menu.visible and not is_interacting and not game_locked:
					npc_text.text = "Barnaby: You there. Why skulk about my shop?"
			_:
				pass

	_set_decision_trace(payload)

func _apply_guard_state(mode: String, target_payload, fallback_last_seen: Vector3, should_chase_player: bool, force_guard: bool) -> bool:
	if mode == "":
		return false
	match mode:
		"idle":
			return true
		"chase_player":
			guard_capture_committed = true
			_start_guard_player_chase_if_allowed(force_guard)
			return true
		"block_exit":
			if should_chase_player:
				guard_capture_committed = true
				_start_guard_player_chase_if_allowed(force_guard)
			elif _wake_guard_if_allowed(force_guard):
				_command_guard_to_position(exit_door.global_position)
			return true
		"investigate_last_seen":
			var target := fallback_last_seen
			if target_payload is Dictionary:
				target = _vector_from_payload(target_payload, target)
			if _wake_guard_if_allowed(force_guard):
				_command_guard_to_position(target)
			return true
		"search_counter":
			if merchant and merchant.has_method("start_counter_patrol") and not is_interacting:
				merchant.call("start_counter_patrol", 4.0)
			return true
		"question_player":
			if should_chase_player:
				guard_capture_committed = true
				_start_guard_player_chase_if_allowed(force_guard)
			elif not radial_menu.visible and not is_interacting and not game_locked:
				npc_text.text = "Barnaby: Why are you lurking here?"
			return true
		_:
			return false

func _apply_brain_run_state(run_phase: String, run_outcome: String, run_reason: String):
	if run_phase == "distracted":
		if not key_stolen and stealth_phase != StealthPhase.FAILED and stealth_phase != StealthPhase.ESCAPED:
			_set_stealth_phase(StealthPhase.DISTRACTION_WINDOW)
	elif run_phase == "key_stolen":
		if stealth_phase != StealthPhase.ESCAPED and stealth_phase != StealthPhase.FAILED:
			_set_stealth_phase(StealthPhase.KEY_STOLEN)
	elif run_phase == "escaped":
		_set_stealth_phase(StealthPhase.ESCAPED)
	elif run_phase == "failed":
		_set_stealth_phase(StealthPhase.FAILED, run_reason)
	elif run_phase == "need_distraction" and stealth_phase == StealthPhase.DISTRACTION_WINDOW and not key_stolen:
		_set_stealth_phase(StealthPhase.NEED_DISTRACTION)

	if run_outcome == "failed" and stealth_phase != StealthPhase.FAILED:
		_set_stealth_phase(StealthPhase.FAILED, run_reason)
	elif run_outcome == "success" and stealth_phase != StealthPhase.ESCAPED:
		_set_stealth_phase(StealthPhase.ESCAPED)

func _begin_interaction_mode():
	_set_focus_mode(false)
	is_interacting = true
	_set_prompt("")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _end_interaction_mode():
	is_interacting = false
	if not game_locked:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _create_prompt_label():
	prompt_label = Label.new()
	prompt_label.name = "InteractPrompt"
	prompt_label.anchors_preset = Control.PRESET_BOTTOM_WIDE
	prompt_label.anchor_top = 1.0
	prompt_label.anchor_bottom = 1.0
	prompt_label.offset_top = -120.0
	prompt_label.offset_bottom = -82.0
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	prompt_label.add_theme_font_size_override("font_size", 24)
	prompt_label.add_theme_color_override("font_color", Color(1.0, 0.96, 0.76))
	prompt_label.visible = false
	$CanvasLayer.add_child(prompt_label)

func _create_decision_trace_widget():
	decision_panel = PanelContainer.new()
	decision_panel.name = "DecisionTrace"
	decision_panel.anchor_left = 0.0
	decision_panel.anchor_top = 0.0
	decision_panel.anchor_right = 0.0
	decision_panel.anchor_bottom = 0.0
	decision_panel.offset_left = 18.0
	decision_panel.offset_top = 18.0
	decision_panel.offset_right = 486.0
	decision_panel.offset_bottom = 232.0
	$CanvasLayer.add_child(decision_panel)

	decision_label = Label.new()
	decision_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	decision_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	decision_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	decision_label.text = "AI Reasoning: awaiting..."
	decision_label.add_theme_font_size_override("font_size", 14)
	decision_panel.add_child(decision_label)
	decision_panel.visible = show_decision_debug_panel

func _setup_focus_instinct():
	_create_focus_overlay()
	focus_merchant_label = _create_focus_label(Color(0.45, 0.95, 1.0, 0.98), "BARNABY")
	if merchant:
		merchant.add_child(focus_merchant_label)
		focus_merchant_label.position = Vector3(0.0, focus_merchant_label_height, 0.0)

	focus_guard_label = _create_focus_label(Color(1.0, 0.64, 0.5, 0.98), "GUARD")
	if guard:
		guard.add_child(focus_guard_label)
		focus_guard_label.position = Vector3(0.0, focus_guard_label_height, 0.0)

func _create_focus_overlay():
	if focus_overlay != null:
		return
	focus_overlay = ColorRect.new()
	focus_overlay.name = "FocusOverlay"
	focus_overlay.anchor_left = 0.0
	focus_overlay.anchor_top = 0.0
	focus_overlay.anchor_right = 1.0
	focus_overlay.anchor_bottom = 1.0
	focus_overlay.offset_left = 0.0
	focus_overlay.offset_top = 0.0
	focus_overlay.offset_right = 0.0
	focus_overlay.offset_bottom = 0.0
	focus_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_overlay.visible = false

	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;
render_mode unshaded;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform float desat_amount : hint_range(0.0, 1.0) = 0.74;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.25;
void fragment() {
	vec2 uv = SCREEN_UV;
	vec4 src = texture(screen_texture, uv);
	float luminance = dot(src.rgb, vec3(0.299, 0.587, 0.114));
	vec3 muted = mix(src.rgb, vec3(luminance), desat_amount);
	float edge = smoothstep(0.88, 0.16, distance(uv, vec2(0.5)));
	float shade = mix(1.0 - vignette_strength, 1.0, edge);
	COLOR = vec4(muted * shade, 1.0);
}
"""
	focus_overlay_material = ShaderMaterial.new()
	focus_overlay_material.shader = shader
	focus_overlay_material.set_shader_parameter("desat_amount", focus_desaturation)
	focus_overlay_material.set_shader_parameter("vignette_strength", focus_vignette_strength)
	focus_overlay.material = focus_overlay_material
	$CanvasLayer.add_child(focus_overlay)

func _create_focus_label(base_color: Color, title: String) -> Label3D:
	var label := Label3D.new()
	label.text = title
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = false
	label.pixel_size = 0.0022
	label.no_depth_test = false
	label.font_size = 20
	label.outline_size = 4
	label.modulate = base_color
	label.outline_modulate = base_color.darkened(0.55)
	label.visible = false
	return label

func _update_focus_mode():
	var wants_focus := Input.is_key_pressed(KEY_SHIFT)
	if radial_menu and radial_menu.visible:
		wants_focus = false
	if is_interacting or awaiting_hood_choice or game_locked:
		wants_focus = false
	_set_focus_mode(wants_focus)

func _set_focus_mode(enabled: bool):
	if focus_active == enabled:
		return
	focus_active = enabled
	Engine.time_scale = focus_time_scale if focus_active else 1.0
	if focus_overlay:
		focus_overlay.visible = focus_active
	if focus_merchant_label:
		focus_merchant_label.visible = focus_active
	if focus_guard_label:
		focus_guard_label.visible = focus_active

func _focus_barnaby_color() -> Color:
	var ratio := clampf(suspicion_value / maxf(suspicion_max, 1.0), 0.0, 1.0)
	var low := Color(0.4, 1.0, 0.62, 0.98)
	var mid := Color(0.98, 0.87, 0.33, 0.98)
	var high := Color(1.0, 0.33, 0.33, 0.98)
	return low.lerp(mid, ratio * 2.0) if ratio < 0.5 else mid.lerp(high, (ratio - 0.5) * 2.0)

func _focus_guard_color(mode: String) -> Color:
	match mode:
		"chase_player", "block_exit":
			return Color(1.0, 0.35, 0.35, 0.98)
		"investigate_last_seen":
			return Color(0.98, 0.78, 0.34, 0.98)
		"question_player":
			return Color(0.45, 0.78, 1.0, 0.98)
		"search_counter":
			return Color(0.42, 1.0, 0.84, 0.98)
		_:
			return Color(0.8, 0.86, 1.0, 0.95)

func _update_focus_labels():
	if not focus_active:
		return
	if focus_overlay_material:
		focus_overlay_material.set_shader_parameter("desat_amount", focus_desaturation)
		focus_overlay_material.set_shader_parameter("vignette_strength", focus_vignette_strength)
	if focus_merchant_label:
		var bar_conf := int(round(ai_last_confidence * 100.0))
		focus_merchant_label.text = (
			"BARNABY\n"
			+ "intent: %s  (%d%%)\n" % [ai_last_intent, bar_conf]
			+ "skill: %s\n" % ai_last_skill
			+ "suspicion: %d%%" % int(round(suspicion_value))
		)
		var barnaby_color := _focus_barnaby_color()
		focus_merchant_label.modulate = barnaby_color
		focus_merchant_label.outline_modulate = barnaby_color.darkened(0.58)
		focus_merchant_label.visible = true
	if focus_guard_label:
		var guard_mode := ai_last_guard_mode if guard_awake else "sleeping"
		focus_guard_label.text = (
			"GUARD\n"
			+ "intent: %s\n" % guard_mode
			+ "skill: %s\n" % ai_last_skill
			+ "suspicion: %d%%\n" % int(round(suspicion_value))
			+ "threat: %d  suspect: %.2f" % [int(round(ai_last_threat)), ai_last_suspect_conf]
		)
		var guard_color := _focus_guard_color(guard_mode)
		focus_guard_label.modulate = guard_color
		focus_guard_label.outline_modulate = guard_color.darkened(0.58)
		focus_guard_label.visible = true

func _format_cooldowns_text(cooldowns: Dictionary) -> String:
	if not (cooldowns is Dictionary) or cooldowns.is_empty():
		return "none"
	var parts: PackedStringArray = []
	for skill in ["wake_guard", "patrol_counter", "question_player", "block_exit", "chase_player"]:
		var left = float(cooldowns.get(skill, 0.0))
		parts.append("%s:%0.1fs" % [skill, left])
	return ", ".join(parts)

func _set_decision_trace(payload: Dictionary):
	if decision_label == null:
		return
	if not (payload is Dictionary):
		decision_label.text = "AI Reasoning: unavailable"
		return

	var intent := str(payload.get("intent", "monitor"))
	var action := str(payload.get("action", "monitor"))
	var confidence := float(payload.get("confidence", 0.0))
	var reason := str(payload.get("reason", ""))
	var pipeline: Dictionary = {}
	var intent_stage: Dictionary = {}
	var skill_stage: Dictionary = {}
	var cooldowns: Dictionary = {}
	var blackboard: Dictionary = {}
	var pipeline_payload = payload.get("pipeline", {})
	if pipeline_payload is Dictionary:
		pipeline = pipeline_payload
		var maybe_intent_stage = pipeline.get("intent", {})
		if maybe_intent_stage is Dictionary:
			intent_stage = maybe_intent_stage
		var maybe_skill_stage = pipeline.get("skill_action", {})
		if maybe_skill_stage is Dictionary:
			skill_stage = maybe_skill_stage
	var band := str(intent_stage.get("confidence_band", "n/a"))
	var before_intent := str(intent_stage.get("before", "n/a"))
	var proposed_intent := str(intent_stage.get("proposed", "n/a"))
	var memory_bias := float(intent_stage.get("memory_bias", 0.0))
	var hysteresis_locked := bool(intent_stage.get("hysteresis_locked", false))

	var blackboard_payload = payload.get("blackboard", {})
	if blackboard_payload is Dictionary:
		blackboard = blackboard_payload
	var threat := float(blackboard.get("threat_level", 0.0))
	var suspect_conf := float(blackboard.get("suspect_confidence", 0.0))
	var key_missing := bool(blackboard.get("key_missing", false))
	var player_visible := bool(blackboard.get("player_visible", false))
	var guard_task := str(blackboard.get("guard_task", "idle"))
	var hf_eval := str(blackboard.get("last_hf_classification", "Waiting for item..."))
	var last_seen_payload = blackboard.get("last_seen_pos", null)
	var last_seen_text := "none"
	if last_seen_payload is Dictionary:
		var lx := float(last_seen_payload.get("x", 0.0))
		var ly := float(last_seen_payload.get("y", 0.0))
		var lz := float(last_seen_payload.get("z", 0.0))
		last_seen_text = "(%.1f, %.1f, %.1f)" % [lx, ly, lz]

	var skill_source := str(skill_stage.get("source", "deterministic"))
	var llm_skill := str(skill_stage.get("llm_proposed_skill", "none"))
	var cooldowns_payload = payload.get("skill_cooldowns", {})
	if cooldowns_payload is Dictionary:
		cooldowns = cooldowns_payload
	var guard_state_payload = payload.get("guard_state", {})
	var guard_mode := "idle"
	if guard_state_payload is Dictionary:
		guard_mode = str(guard_state_payload.get("mode", "idle"))

	# Feed diegetic focus labels from live backend state.
	ai_last_intent = intent
	ai_last_skill = action
	ai_last_confidence = confidence
	ai_last_guard_mode = guard_mode
	ai_last_threat = threat
	ai_last_suspect_conf = suspect_conf
	_update_focus_labels()

	decision_label.text = (
		"[AI REASONING]\n"
		+ "Intent: %s  (before:%s -> proposed:%s)\n" % [intent, before_intent, proposed_intent]
		+ "Confidence: %.2f  band:%s  hysteresis_lock:%s  memory_bias:%0.2f\n" % [confidence, band, str(hysteresis_locked), memory_bias]
		+ "Skill: %s  target:%s  source:%s  llm:%s\n" % [action, str(payload.get("target", "player")), skill_source, llm_skill]
		+ "Reason: %s\n" % reason
		+ "Blackboard -> threat:%0.1f  suspect:%0.2f  key_missing:%s  player_visible:%s\n" % [threat, suspect_conf, str(key_missing), str(player_visible)]
		+ "HF semantic: %s\n" % hf_eval
		+ "Guard task:%s  last_seen:%s\n" % [guard_task, last_seen_text]
		+ "Cooldowns -> %s" % _format_cooldowns_text(cooldowns)
	)

func _create_objective_widget():
	objective_panel = PanelContainer.new()
	objective_panel.name = "ObjectivePanel"
	objective_panel.anchor_left = 1.0
	objective_panel.anchor_top = 0.0
	objective_panel.anchor_right = 1.0
	objective_panel.anchor_bottom = 0.0
	objective_panel.offset_left = -402.0
	objective_panel.offset_top = 18.0
	objective_panel.offset_right = -18.0
	objective_panel.offset_bottom = 102.0
	$CanvasLayer.add_child(objective_panel)

	objective_label = Label.new()
	objective_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	objective_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	objective_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	objective_panel.add_child(objective_label)
	_refresh_objective_widget()

func _objective_state_text() -> String:
	match stealth_phase:
		StealthPhase.NEED_DISTRACTION:
			return "Talk to Barnaby and choose Look Around."
		StealthPhase.DISTRACTION_WINDOW:
			var now := Time.get_ticks_msec() / 1000.0
			var remaining := maxf(0.0, key_window_until - now)
			return "Barnaby distracted. Steal key now (%.1fs left)." % remaining
		StealthPhase.KEY_STOLEN:
			return "Key stolen. Reach the door and exit."
		StealthPhase.ESCAPED:
			return "Success: escaped with the key."
		StealthPhase.FAILED:
			if fail_reason == "":
				return "Failed."
			return "Failed: %s" % fail_reason
		_:
			return "Objective unavailable."

func _refresh_objective_widget():
	if objective_label == null:
		return
	objective_label.text = "Objective\n%s" % _objective_state_text()

func _set_stealth_phase(next_phase: int, reason: String = ""):
	@warning_ignore("int_as_enum_without_cast")
	stealth_phase = next_phase
	if next_phase == StealthPhase.FAILED:
		fail_reason = reason
	elif next_phase != StealthPhase.FAILED:
		fail_reason = ""
	_refresh_objective_widget()

func _create_endgame_widget():
	endgame_panel = PanelContainer.new()
	endgame_panel.name = "EndgamePanel"
	endgame_panel.anchor_left = 0.5
	endgame_panel.anchor_top = 0.5
	endgame_panel.anchor_right = 0.5
	endgame_panel.anchor_bottom = 0.5
	endgame_panel.offset_left = -260.0
	endgame_panel.offset_top = -120.0
	endgame_panel.offset_right = 260.0
	endgame_panel.offset_bottom = 120.0
	endgame_panel.visible = false
	$CanvasLayer.add_child(endgame_panel)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	endgame_panel.add_child(vbox)

	endgame_title = Label.new()
	endgame_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	endgame_title.add_theme_font_size_override("font_size", 34)
	endgame_title.text = "Run Complete"
	vbox.add_child(endgame_title)

	endgame_subtitle = Label.new()
	endgame_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	endgame_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	endgame_subtitle.text = ""
	vbox.add_child(endgame_subtitle)

	endgame_retry_button = Button.new()
	endgame_retry_button.text = "Retry"
	endgame_retry_button.custom_minimum_size = Vector2(140.0, 42.0)
	endgame_retry_button.pressed.connect(_retry_run)
	vbox.add_child(endgame_retry_button)

	endgame_fresh_button = Button.new()
	endgame_fresh_button.text = "Start Fresh"
	endgame_fresh_button.custom_minimum_size = Vector2(140.0, 42.0)
	endgame_fresh_button.pressed.connect(_start_fresh_reset)
	vbox.add_child(endgame_fresh_button)

func _show_endgame_overlay(title: String, subtitle: String, success: bool):
	_set_focus_mode(false)
	if black_overlay:
		black_overlay.color = Color(0.0, 0.0, 0.0, 0.88) if success else Color(0.0, 0.0, 0.0, 0.96)
		black_overlay.visible = true
	if endgame_panel:
		endgame_title.text = title
		endgame_subtitle.text = "%s\nPress R/click Retry, or click Start Fresh to reset Barnaby memory." % subtitle
		if endgame_retry_button:
			endgame_retry_button.disabled = false
		if endgame_fresh_button:
			endgame_fresh_button.disabled = false
			endgame_fresh_button.text = "Start Fresh"
		endgame_panel.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _retry_run():
	_set_focus_mode(false)
	get_tree().reload_current_scene()

func _start_fresh_reset():
	if reset_in_flight:
		return
	reset_in_flight = true
	if endgame_retry_button:
		endgame_retry_button.disabled = true
	if endgame_fresh_button:
		endgame_fresh_button.disabled = true
		endgame_fresh_button.text = "Resetting..."
	var err := reset_http.request(
		"http://127.0.0.1:8000/reset_brain",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		"{}"
	)
	if err != OK:
		reset_in_flight = false
		if endgame_retry_button:
			endgame_retry_button.disabled = false
		if endgame_fresh_button:
			endgame_fresh_button.disabled = false
			endgame_fresh_button.text = "Start Fresh"
		npc_text.text = "Could not reset Barnaby memory. Check backend."

func _on_reset_reply(_res, code, _headers, body):
	reset_in_flight = false
	if endgame_retry_button:
		endgame_retry_button.disabled = false
	if endgame_fresh_button:
		endgame_fresh_button.disabled = false
		endgame_fresh_button.text = "Start Fresh"
	if code != 200:
		npc_text.text = "Reset request failed. Backend not responding."
		return
	var payload = JSON.parse_string(body.get_string_from_utf8())
	if payload is Dictionary and bool(payload.get("ok", false)):
		_retry_run()
		return
	npc_text.text = "Reset request failed. Try again."

func _show_hood_choice_prompt():
	_set_focus_mode(false)
	awaiting_hood_choice = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if hood_prompt_panel and is_instance_valid(hood_prompt_panel):
		hood_prompt_panel.queue_free()

	hood_prompt_panel = PanelContainer.new()
	hood_prompt_panel.name = "HoodChoicePrompt"
	hood_prompt_panel.anchor_left = 0.5
	hood_prompt_panel.anchor_top = 0.5
	hood_prompt_panel.anchor_right = 0.5
	hood_prompt_panel.anchor_bottom = 0.5
	hood_prompt_panel.offset_left = -220.0
	hood_prompt_panel.offset_top = -90.0
	hood_prompt_panel.offset_right = 220.0
	hood_prompt_panel.offset_bottom = 90.0
	$CanvasLayer.add_child(hood_prompt_panel)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hood_prompt_panel.add_child(vbox)

	var title := Label.new()
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.text = "Hood status before entering?"
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	var note := Label.new()
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.text = "Hood Off: Barnaby can fully identify you.\nHood On: harder to identify."
	vbox.add_child(note)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(row)

	var hood_on_button := Button.new()
	hood_on_button.text = "Hood On"
	hood_on_button.pressed.connect(Callable(self, "_on_hood_choice_selected").bind(true))
	row.add_child(hood_on_button)

	var hood_off_button := Button.new()
	hood_off_button.text = "Hood Off"
	hood_off_button.pressed.connect(Callable(self, "_on_hood_choice_selected").bind(false))
	row.add_child(hood_off_button)

func _on_hood_choice_selected(hood_on_choice: bool):
	if not awaiting_hood_choice:
		return
	player_hood_on = hood_on_choice
	_push_recent_action("hood_on" if hood_on_choice else "hood_off")
	awaiting_hood_choice = false
	if hood_prompt_panel and is_instance_valid(hood_prompt_panel):
		hood_prompt_panel.queue_free()
	hood_prompt_panel = null
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_set_focus_mode(false)
	_set_stealth_phase(StealthPhase.NEED_DISTRACTION)
	npc_text.text = "Hood %s. Move with WASD, press E to interact, hold Shift for Thief Instinct. Semantic demo: 1 coin, 2 coin stack, 3 bottle, 4 chair, 5 dagger." % ("On" if player_hood_on else "Off")
	_send_world_event("start_visit", 1.0, {"hood_on": player_hood_on})

func _create_suspicion_widget():
	suspicion_panel = PanelContainer.new()
	suspicion_panel.name = "SuspicionWidget"
	suspicion_panel.custom_minimum_size = Vector2(180.0, 48.0)
	suspicion_panel.visible = true
	$CanvasLayer.add_child(suspicion_panel)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	suspicion_panel.add_child(vbox)

	suspicion_text = Label.new()
	suspicion_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	suspicion_text.text = "Suspicion 12%"
	vbox.add_child(suspicion_text)

	suspicion_bar = ProgressBar.new()
	suspicion_bar.min_value = 0.0
	suspicion_bar.max_value = suspicion_max
	suspicion_bar.value = suspicion_value
	suspicion_bar.show_percentage = false
	suspicion_bar.custom_minimum_size = Vector2(170.0, 18.0)
	vbox.add_child(suspicion_bar)

func _update_suspicion_widget():
	if suspicion_panel == null:
		return
	if merchant == null or camera == null:
		suspicion_panel.visible = false
		return

	var world_anchor := merchant.global_position + Vector3(0.0, 2.4, 0.0)
	if camera.is_position_behind(world_anchor):
		suspicion_panel.visible = false
		return

	var screen_pos: Vector2 = camera.unproject_position(world_anchor) + suspicion_screen_offset
	suspicion_panel.position = screen_pos
	suspicion_panel.visible = true

	suspicion_value = clampf(suspicion_value, 0.0, suspicion_max)
	suspicion_bar.value = suspicion_value
	suspicion_text.text = "Suspicion %d%%" % int(round(suspicion_value))

	var ratio := clampf(suspicion_value / maxf(suspicion_max, 1.0), 0.0, 1.0)
	var c_low := Color(0.2, 0.85, 0.3)
	var c_mid := Color(0.95, 0.8, 0.2)
	var c_high := Color(0.95, 0.2, 0.2)
	var bar_color := c_low.lerp(c_mid, ratio * 2.0) if ratio < 0.5 else c_mid.lerp(c_high, (ratio - 0.5) * 2.0)
	suspicion_bar.modulate = bar_color

func _spawn_key_prop():
	if placed_key:
		key_node = placed_key
	else:
		var fallback_key := MeshInstance3D.new()
		fallback_key.name = "KeyProp"
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.18, 0.07, 0.06)
		fallback_key.mesh = mesh

		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.96, 0.78, 0.2)
		mat.metallic = 0.75
		mat.roughness = 0.22
		fallback_key.material_override = mat

		fallback_key.position = key_world_position
		add_child(fallback_key)
		key_node = fallback_key

	if key_node == null:
		return

	if key_area and is_instance_valid(key_area):
		key_area.queue_free()

	key_area = Area3D.new()
	key_area.name = "KeyInteractArea"
	key_area.monitoring = true
	key_area.monitorable = true
	add_child(key_area)
	key_area.set_meta("interact_type", "key")
	key_area.global_position = key_node.global_position

	var key_shape := CollisionShape3D.new()
	var key_sphere := SphereShape3D.new()
	key_sphere.radius = key_hitbox_radius
	key_shape.shape = key_sphere
	key_shape.position = Vector3.ZERO
	key_area.add_child(key_shape)

func _sync_key_interact_area():
	if key_node == null or key_area == null:
		return
	key_area.global_position = key_node.global_position

func _update_stealth_window_state():
	if stealth_phase != StealthPhase.DISTRACTION_WINDOW:
		return
	if key_stolen:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now <= key_window_until:
		_refresh_objective_widget()
		return
	_set_stealth_phase(StealthPhase.NEED_DISTRACTION)
	if merchant and merchant.has_method("stop_counter_patrol"):
		merchant.call("stop_counter_patrol")
	distraction_guard_grace_until = 0.0
	_push_recent_action("distract_window_expired")
	npc_text.text = "Barnaby turns back toward the counter. You need another distraction."
	_send_world_event("distract_expired", 1.0, {})

func _can_steal_key() -> bool:
	if key_stolen or key_node == null:
		return false
	if stealth_phase != StealthPhase.DISTRACTION_WINDOW:
		return false
	var now := Time.get_ticks_msec() / 1000.0
	if now > key_window_until:
		return false
	# Barnaby must be away from the key while distracted.
	if merchant.global_position.distance_to(key_node.global_position) < key_merchant_safe_distance:
		return false
	return true

func _steal_key_sequence():
	stealing_key = true
	_push_recent_action("steal_key")
	npc_text.text = "You slide behind the counter and reach for the key..."
	_set_prompt("")

	var start_pos := camera.position
	var dip_pos := start_pos + Vector3(0.0, -0.15, 0.0)
	var tween := create_tween()
	tween.tween_property(camera, "position", dip_pos, 0.24)
	tween.tween_interval(0.1)
	if key_node:
		tween.parallel().tween_property(key_node, "scale", Vector3(0.02, 0.02, 0.02), 0.35)
	tween.tween_property(camera, "position", start_pos, 0.28)
	await tween.finished

	if key_node:
		key_node.queue_free()
		key_node = null
	if key_area:
		key_area.queue_free()
		key_area = null
	key_stolen = true
	stealing_key = false
	distraction_guard_grace_until = 0.0
	_set_stealth_phase(StealthPhase.KEY_STOLEN)
	npc_text.text = "Key stolen. Face the door and press E to exit unnoticed."
	_send_world_event("key_touched", 1.0, {"stealth": true, "hood_on": player_hood_on})

func _set_key_stolen_world_state():
	key_stolen = true
	key_window_until = 0.0
	distraction_guard_grace_until = 0.0
	if stealth_phase != StealthPhase.ESCAPED and stealth_phase != StealthPhase.FAILED:
		_set_stealth_phase(StealthPhase.KEY_STOLEN)
	if key_node:
		key_node.queue_free()
		key_node = null
	if key_area:
		key_area.queue_free()
		key_area = null

@warning_ignore("unused_parameter")
func _handle_start_visit_state(has_stolen: bool, thief_recognized: bool, emotion: String, action_hint: String):
	if not has_stolen:
		_set_stealth_phase(StealthPhase.NEED_DISTRACTION)
		return
	_set_stealth_phase(StealthPhase.KEY_STOLEN)
	# Returning after key theft should immediately trigger pursuit, not passive lurking.
	suspicion_value = maxf(suspicion_value, 95.0)
	if merchant:
		merchant.start_behavior("hostile")
	guard_capture_committed = true
	_start_guard_player_chase_if_allowed(true)
	if thief_recognized or action_hint == "alert" or not player_hood_on:
		npc_text.text = "Barnaby shouts: \"Thief! Guard, take them now!\""
	else:
		npc_text.text = "Barnaby snaps toward you: \"That key is mine. Guard!\""

func _build_fallback_menu(emotion: String) -> Array:
	if emotion == "hostile":
		return [
			{"id": "apologize", "title": "Apologize", "prompt": "Offer an apology and lower your voice.", "color": "#3aa655"},
			{"id": "bargain", "title": "Bargain", "prompt": "Offer extra coin and request safe passage.", "color": "#2a7fff"},
			{"id": "threaten", "title": "Threaten", "prompt": "Threaten Barnaby and demand the key.", "color": "#d48a00"},
			{"id": "look_around", "title": "Look Around", "prompt": "Tell Barnaby you are only looking around.", "color": "#7a8cff"}
		]
	return [
		{"id": "charm", "title": "Charm", "prompt": "Offer a respectful greeting and praise the shop.", "color": "#3aa655"},
		{"id": "bargain", "title": "Bargain", "prompt": "Ask for a fair discount with confidence.", "color": "#2a7fff"},
		{"id": "pressure", "title": "Pressure", "prompt": "Push Barnaby for better terms with urgency.", "color": "#d48a00"},
		{"id": "look_around", "title": "Look Around", "prompt": "Tell Barnaby you are just having a look around first.", "color": "#7a8cff"}
	]

func _parse_color(value, fallback: Color) -> Color:
	if value is Color:
		return value
	if value is String:
		return Color.from_string(value, fallback)
	return fallback

func _to_radial_items(options: Array) -> Array:
	var items: Array = []
	for option in options:
		if not (option is Dictionary):
			continue
		if not option.has("id") or not option.has("title"):
			continue

		var base = _parse_color(option.get("color", "#444444"), Color(0.27, 0.27, 0.27, 1.0))
		var selected = base.lightened(0.22)

		items.append({
			"id": option["id"],
			"title": option["title"],
			"texture": null,
			"bg_color": base,
			"selected_bg_color": selected,
			"stroke_color": base.darkened(0.25),
			"selected_stroke_color": selected.darkened(0.18),
			"label_color": Color.WHITE,
			"selected_label_color": Color(1.0, 1.0, 0.92)
		})
	return items

func _menu_center_position() -> Vector2:
	var view_size = get_viewport().get_visible_rect().size
	var x = clamp(view_size.x * 0.22, 170.0, 360.0)
	var y = clamp(view_size.y * 0.73, 260.0, view_size.y - 120.0)
	return Vector2(x, y)

func _open_choice_menu(options: Array):
	if game_locked:
		return
	last_menu_options = options.duplicate(true)
	var radial_items = _to_radial_items(last_menu_options)
	if radial_items.is_empty():
		return
	if merchant and merchant.has_method("stop_counter_patrol"):
		merchant.call("stop_counter_patrol")
	_begin_interaction_mode()
	radial_menu.set_items(radial_items)
	radial_menu.open_menu(_menu_center_position())

func _find_option(choice_id: String) -> Dictionary:
	for option in last_menu_options:
		if option is Dictionary and option.get("id", "") == choice_id:
			return option
	return {}

func _on_choice_made(choice_id, _position):
	if game_locked:
		return

	_end_interaction_mode()
	pending_choice_id = str(choice_id)
	_push_recent_action("choice_%s" % pending_choice_id)
	var option = _find_option(pending_choice_id)
	var prompt = option.get("prompt", "Speak to Barnaby.")
	var body = JSON.stringify({"message": prompt, "choice_id": pending_choice_id})
	npc_text.text = "Barnaby studies your move..."
	http.request(
		"http://127.0.0.1:8000/chat",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		body
	)

func _on_menu_canceled():
	# Interaction is now explicit; do not auto-reopen menu.
	_end_interaction_mode()

func _on_reply(_res, code, _head, body):
	if code != 200:
		npc_text.text = "Barnaby: The market winds are noisy. Speak again."
		return

	var payload = JSON.parse_string(body.get_string_from_utf8())
	if not (payload is Dictionary):
		npc_text.text = "Barnaby: Hrm. Say that once more."
		return

	var text = str(payload.get("text", "Barnaby grunts."))
	var emotion = str(payload.get("emotion", "neutral"))
	var is_caught = bool(payload.get("is_caught", false))
	var voice_b64 := str(payload.get("audio_base64", ""))
	var dialogue_duration := _estimate_dialogue_duration_seconds(text)
	var played_duration := _play_voice_from_base64(voice_b64)
	if played_duration > 0.05:
		dialogue_duration = played_duration
	var brain_state = payload.get("brain_state", {})
	if brain_state is Dictionary:
		suspicion_value = float(brain_state.get("suspicion", suspicion_value))
		var run_phase := str(brain_state.get("run_phase", ""))
		var run_outcome := str(brain_state.get("run_outcome", ""))
		var run_reason := str(brain_state.get("run_reason", ""))
		_apply_brain_run_state(run_phase, run_outcome, run_reason)

	npc_text.text = text
	if merchant:
		if merchant.has_method("play_dialogue_line"):
			merchant.call("play_dialogue_line", emotion, dialogue_duration)
		else:
			merchant.start_behavior(emotion)
	if is_caught:
		guard_capture_committed = true
		_start_guard_player_chase_if_allowed(true)
	elif suspicion_value >= guard_chase_suspicion_threshold or (emotion == "hostile" and suspicion_value >= guard_wake_suspicion_threshold):
		guard_capture_committed = true
		_start_guard_player_chase_if_allowed(false)

	if is_caught:
		_fail_run("Barnaby identified the theft during dialogue.")
		return

	var menu_options = payload.get("menu_options", [])
	if menu_options is Array and not menu_options.is_empty():
		last_menu_options = menu_options.duplicate(true)
	else:
		last_menu_options = _build_fallback_menu(emotion)

	_try_open_key_window(emotion, pending_choice_id)
	pending_choice_id = ""

func _try_open_key_window(emotion: String, choice_id: String):
	if key_stolen:
		return
	if choice_id != "look_around":
		return
	if emotion == "hostile":
		return

	var now := Time.get_ticks_msec() / 1000.0
	var window_duration := key_window_seconds
	if emotion == "annoyed":
		window_duration = maxf(3.5, key_window_seconds * 0.65)
	key_window_until = now + window_duration
	distraction_guard_grace_until = now + minf(distraction_guard_grace_seconds, maxf(1.6, window_duration * 0.6))
	_set_stealth_phase(StealthPhase.DISTRACTION_WINDOW)
	if emotion == "annoyed":
		npc_text.text = "%s\nBarnaby is distracted, but still wary. Move quickly." % npc_text.text
	else:
		npc_text.text = "%s\nBarnaby nods and turns to the shelves. Your window is open." % npc_text.text
	if merchant and merchant.has_method("start_counter_patrol"):
		merchant.call("start_counter_patrol", window_duration)
	_send_world_event("distract_started", 1.0, {"choice_id": choice_id})

func _setup_guard_state():
	guard_awake = false
	guard_capture_committed = false
	if guard == null:
		return
	guard_anim_player = guard.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if guard_anim_player == null:
		return
	var finished_cb := Callable(self, "_on_guard_animation_finished")
	if not guard_anim_player.animation_finished.is_connected(finished_cb):
		guard_anim_player.animation_finished.connect(finished_cb)
	_play_guard_sleeping()
	guard_target_active = false
	guard_has_last_seen_player = false
	guard_chasing_player = false
	guard_path_points.clear()
	guard_repath_accum = 0.0
	guard_last_path_target = guard.global_position
	guard_chase_lock_until = 0.0
	guard_forced_bypass_side = 0
	guard_forced_lane_side = 0
	guard_last_position = guard.global_position
	guard_stuck_elapsed = 0.0

func _wake_guard():
	if guard_awake:
		return
	guard_awake = true
	var anim_name := _resolve_guard_animation(guard_wake_animation, ["Standing Up/mixamo_com", "Standing Up"])
	if guard_anim_player != null and anim_name != "":
		guard_anim_player.play(anim_name)

func _guard_grace_active() -> bool:
	if key_stolen:
		return false
	var now := Time.get_ticks_msec() / 1000.0
	return now < distraction_guard_grace_until

func _can_wake_guard(force_guard: bool = false) -> bool:
	if force_guard:
		return true
	if guard_awake:
		return true
	if key_stolen:
		return true
	if _guard_grace_active():
		return false
	return suspicion_value >= guard_wake_suspicion_threshold

func _can_chase_guard(force_guard: bool = false) -> bool:
	if force_guard:
		return true
	if guard_chasing_player:
		return true
	if key_stolen:
		return true
	if _guard_grace_active():
		return false
	return suspicion_value >= guard_chase_suspicion_threshold

func _guard_chase_locked() -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	return now < guard_chase_lock_until

func _wake_guard_if_allowed(force_guard: bool = false) -> bool:
	if not _can_wake_guard(force_guard):
		return false
	_wake_guard()
	return guard_awake

func _start_guard_player_chase_if_allowed(force_guard: bool = false) -> bool:
	if not _can_chase_guard(force_guard):
		return false
	if not _wake_guard_if_allowed(force_guard):
		return false
	guard_capture_committed = true
	_start_guard_player_chase()
	return true

func _start_guard_player_chase():
	if player_body == null or guard == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	guard_chase_lock_until = maxf(guard_chase_lock_until, now + guard_chase_lock_seconds)
	var next_target := Vector3(player_body.global_position.x, guard.global_position.y, player_body.global_position.z)
	var switching_mode := not guard_chasing_player
	guard_chasing_player = true
	guard_target_active = true
	guard_target_position = next_target
	guard_stuck_elapsed = 0.0
	guard_last_position = guard.global_position
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
	if guard == null:
		return
	var look_target := Vector3(target.x, guard.global_position.y, target.z)
	if guard.global_position.distance_to(look_target) < 0.001:
		return
	guard.look_at(look_target, Vector3.UP)
	guard.rotate_y(deg_to_rad(guard_model_facing_offset_degrees))

func _command_guard_to_last_seen():
	if guard_has_last_seen_player:
		_command_guard_to_position(guard_last_seen_player_position)

func _command_guard_to_position(world_target: Vector3):
	if guard == null:
		return
	if guard_capture_committed:
		_start_guard_player_chase_if_allowed(true)
		return
	if guard_chasing_player and _guard_chase_locked():
		return
	var resolved_target := Vector3(world_target.x, guard.global_position.y, world_target.z)
	if guard_target_active and not guard_chasing_player and guard_target_position.distance_to(resolved_target) <= 0.2:
		return
	guard_chasing_player = false
	guard_chase_lock_until = 0.0
	guard_forced_bypass_side = 0
	guard_forced_lane_side = 0
	guard_target_position = resolved_target
	guard_target_active = true
	guard_path_points.clear()
	guard_repath_accum = guard_repath_interval
	guard_last_position = guard.global_position
	guard_stuck_elapsed = 0.0
	_face_guard_towards(guard_target_position)
	_play_guard_running()

func _update_guard_movement(delta: float):
	if guard == null or not guard_awake:
		return
	if guard_capture_committed and not guard_target_active:
		_start_guard_player_chase_if_allowed(true)
		return
	if not guard_target_active:
		return
	if guard_capture_committed and not guard_chasing_player:
		_start_guard_player_chase_if_allowed(true)
		return
	var current_pos := guard.global_position
	if guard_chasing_player and player_body != null:
		var player_now := Vector3(player_body.global_position.x, guard.global_position.y, player_body.global_position.z)
		guard_target_position = player_now
		if current_pos.distance_to(player_now) <= guard_catch_distance:
			_trigger_guard_capture()
			return

	var moved_since_last := current_pos.distance_to(guard_last_position)
	if moved_since_last <= guard_stuck_distance_threshold:
		guard_stuck_elapsed += delta
	else:
		guard_stuck_elapsed = 0.0
	guard_last_position = current_pos

	var final_target := Vector3(guard_target_position.x, current_pos.y, guard_target_position.z)
	guard_repath_accum += delta
	var active_repath_interval := guard_repath_interval
	if guard_chasing_player:
		active_repath_interval = maxf(0.09, guard_repath_interval * 0.78)
	if guard_capture_committed:
		active_repath_interval = maxf(active_repath_interval, guard_commit_repath_interval)
	var should_repath := guard_path_points.is_empty()
	if guard_capture_committed:
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
			_trigger_guard_capture()
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
		# Hard-stop any tunneling through counter/props; rebuild path and take a smaller safe step.
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
				next_pos = current_pos
		else:
			next_pos = current_pos
		next_pos = _clamp_guard_to_shop(next_pos)
		if _guard_segment_hits_blocker(current_pos, next_pos):
			next_pos = current_pos
	if _point_in_counter(next_pos):
		next_pos = _push_guard_out_of_counter(next_pos, dir)
	guard.global_position = next_pos

func _rebuild_guard_path(from_pos: Vector3, target_pos: Vector3):
	guard_path_points.clear()
	guard_last_path_target = target_pos
	var from_2d := Vector2(from_pos.x, from_pos.z)
	var target_2d := Vector2(target_pos.x, target_pos.z)
	var counter_rect := _guard_counter_rect()
	var back_z := clampf(counter_rect.position.y - guard_counter_avoid_margin_z, shop_bounds_min.y + guard_world_margin, shop_bounds_max.y - guard_world_margin)
	var front_z := clampf(counter_rect.end.y + guard_counter_avoid_margin_z, shop_bounds_min.y + guard_world_margin, shop_bounds_max.y - guard_world_margin)
	var start_back := from_2d.y <= counter_rect.position.y
	var target_back := target_2d.y <= counter_rect.position.y

	if guard_chasing_player:
		# Merchant-style chase route: left corridor, lane align, across, then final.
		var desired_left_corridor_x := minf(shop_bounds_min.x + guard_left_corridor_inset, counter_rect.position.x - guard_path_probe_margin)
		var left_corridor_x := clampf(
			desired_left_corridor_x,
			shop_bounds_min.x + 0.01,
			shop_bounds_max.x - guard_world_margin
		)
		var y := guard.global_position.y
		var from_lane_z := back_z if start_back else front_z
		var target_lane_z := back_z if target_back else front_z

		# Step 1: align to a safe lane first (keeps motion away from center objects).
		if absf(from_pos.z - from_lane_z) > 0.02:
			guard_path_points.append(Vector3(from_pos.x, y, from_lane_z))

		# Step 2: move left along the safe lane.
		guard_path_points.append(Vector3(left_corridor_x, y, from_lane_z))

		# Step 3: if player is on opposite side of counter, switch lane on the left corridor.
		if absf(from_lane_z - target_lane_z) > 0.02:
			guard_path_points.append(Vector3(left_corridor_x, y, target_lane_z))

		# Step 4: move across to player's x while staying in safe lane.
		guard_path_points.append(Vector3(target_pos.x, y, target_lane_z))
	elif _segment_hits_rect(from_2d, target_2d, counter_rect):
		var left_x := clampf(counter_rect.position.x - guard_counter_avoid_margin_x, shop_bounds_min.x + guard_world_margin, shop_bounds_max.x - guard_world_margin)
		var right_x := clampf(counter_rect.end.x + guard_counter_avoid_margin_x, shop_bounds_min.x + guard_world_margin, shop_bounds_max.x - guard_world_margin)
		var left_cost := absf(from_2d.x - left_x) + absf(target_2d.x - left_x)
		var right_cost := absf(from_2d.x - right_x) + absf(target_2d.x - right_x)
		var bypass_x := left_x if left_cost <= right_cost else right_x

		if start_back != target_back:
			var start_lane_non_chase := back_z if start_back else front_z
			var target_lane_non_chase := back_z if target_back else front_z
			guard_path_points.append(Vector3(bypass_x, guard.global_position.y, start_lane_non_chase))
			guard_path_points.append(Vector3(bypass_x, guard.global_position.y, target_lane_non_chase))
		else:
			var same_lane := back_z if start_back else front_z
			guard_path_points.append(Vector3(bypass_x, guard.global_position.y, same_lane))
	elif not guard_chasing_player:
		guard_forced_bypass_side = 0
		guard_forced_lane_side = 0

	var final_point := Vector3(target_pos.x, guard.global_position.y, target_pos.z)
	if guard_path_points.is_empty() or guard_path_points[guard_path_points.size() - 1].distance_to(final_point) > 0.03:
		guard_path_points.append(final_point)

func _guard_counter_rect() -> Rect2:
	var half_x := 1.8 + guard_counter_avoid_margin_x
	var half_z := 0.5 + guard_counter_avoid_margin_z
	var min_x := -3.5 - half_x
	var min_z := -4.0 - half_z
	return Rect2(Vector2(min_x, min_z), Vector2(half_x * 2.0, half_z * 2.0))

func _segment_hits_rect(a: Vector2, b: Vector2, rect: Rect2) -> bool:
	if rect.has_point(a) or rect.has_point(b):
		return true
	for i in range(1, 13):
		var t := float(i) / 12.0
		var p := a.lerp(b, t)
		if rect.has_point(p):
			return true
	return false

func _guard_segment_hits_blocker(from_pos: Vector3, to_pos: Vector3) -> bool:
	if guard == null:
		return false
	var from_probe := from_pos + Vector3(0.0, guard_path_probe_height, 0.0)
	var to_probe := to_pos + Vector3(0.0, guard_path_probe_height, 0.0)
	var path_len := from_probe.distance_to(to_probe)
	if path_len <= 0.001:
		return false
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from_probe, to_probe)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	var excluded_rids: Array[RID] = []
	if player_body != null:
		excluded_rids.append(player_body.get_rid())
	if guard is CollisionObject3D:
		excluded_rids.append((guard as CollisionObject3D).get_rid())
	query.exclude = excluded_rids
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	var collider_val: Variant = hit.get("collider", null)
	if collider_val is Node:
		var collider_node := collider_val as Node
		if collider_node == key_area:
			return false
		if guard != null and guard.is_ancestor_of(collider_node):
			return false
	var hit_pos_val: Variant = hit.get("position", to_probe)
	var hit_pos: Vector3 = to_probe
	if hit_pos_val is Vector3:
		hit_pos = hit_pos_val
	return from_probe.distance_to(hit_pos) < maxf(0.05, path_len - guard_path_probe_margin)

func _clamp_guard_to_shop(pos: Vector3) -> Vector3:
	var clamped := pos
	clamped.x = clampf(clamped.x, shop_bounds_min.x + guard_world_margin, shop_bounds_max.x - guard_world_margin)
	clamped.z = clampf(clamped.z, shop_bounds_min.y + guard_world_margin, shop_bounds_max.y - guard_world_margin)
	return clamped

func _point_in_counter(pos: Vector3) -> bool:
	var rect := _guard_counter_rect()
	return rect.has_point(Vector2(pos.x, pos.z))

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

func _trigger_guard_capture():
	_set_focus_mode(false)
	guard_capture_committed = false
	guard_chasing_player = false
	guard_target_active = false
	guard_chase_lock_until = 0.0
	guard_forced_bypass_side = 0
	guard_forced_lane_side = 0
	game_locked = true
	_end_interaction_mode()
	if radial_menu.visible:
		radial_menu.close_menu()
	_set_prompt("")
	_set_stealth_phase(StealthPhase.FAILED, "The guard reached you.")
	_send_world_event("caught_by_guard", 1.0, {"reason": "Guard captured player."})
	npc_text.text = "The guard catches you."
	_show_endgame_overlay("You Got Caught", "The guard got you. Retry?", false)

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

func _vector_from_payload(payload: Dictionary, fallback: Vector3) -> Vector3:
	if not (payload is Dictionary):
		return fallback
	var x = float(payload.get("x", fallback.x))
	var y = float(payload.get("y", fallback.y))
	var z = float(payload.get("z", fallback.z))
	return Vector3(x, y, z)

func _push_recent_action(action_name: String):
	if action_name == "":
		return
	if recent_actions.is_empty() or recent_actions[recent_actions.size() - 1] != action_name:
		recent_actions.append(action_name)
	while recent_actions.size() > 8:
		recent_actions.remove_at(0)

func _fail_run(reason: String):
	if stealth_phase == StealthPhase.FAILED:
		return
	_set_stealth_phase(StealthPhase.FAILED, reason)
	_send_world_event("run_failed", 1.0, {"reason": reason})
	guard_capture_committed = true
	_start_guard_player_chase_if_allowed(true)
	_trigger_game_over()

func _trigger_game_over():
	_set_focus_mode(false)
	game_locked = true
	_end_interaction_mode()
	if radial_menu.visible:
		radial_menu.close_menu()
	_set_prompt("")
	if stealth_phase != StealthPhase.FAILED:
		_set_stealth_phase(StealthPhase.FAILED, "Run failed.")
	if merchant:
		merchant.start_chase()
	await get_tree().create_timer(1.8).timeout
	var reason := fail_reason if fail_reason != "" else "Barnaby caught on to you."
	_show_endgame_overlay("You Got Caught", "%s Retry?" % reason, false)

func _trigger_victory():
	_set_focus_mode(false)
	game_locked = true
	_end_interaction_mode()
	if radial_menu.visible:
		radial_menu.close_menu()
	_set_prompt("")
	_set_stealth_phase(StealthPhase.ESCAPED)
	_send_world_event("exit_success", 1.0, {"hood_on": player_hood_on})
	npc_text.text = "You slip through the door with the key. Clean escape."
	_show_endgame_overlay(
		"You Did It",
		"You stole the key and escaped. Want to try again and mess with Barnaby?",
		true
	)

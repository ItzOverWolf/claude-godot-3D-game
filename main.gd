extends Node3D
## Sky Ruins Dash - an endless 3D runner in ONE script.
## Every mesh, material, menu and sound effect is generated in code: no assets.
##
## Controls:
##   A / D  or  Left / Right : change lane, or TURN when you reach a corner
##   W / Up / Space          : jump        S / Down : slide
##   ESC / P                 : pause       Mouse drag (swipe) also works.

enum State { MENU, SHOP, PLAYING, PAUSED, DEAD }
enum T { STRAIGHT, TURN_L, TURN_R }
enum O { LOW, HIGH, GAP, BLOCK }

# ---------------------------------------------------------------- tuning ----
const LANE_W := 2.0
const PATH_W := 6.0
const TILE_LEN := 10.0
const TURN_LEN := 6.0
const TILES_AHEAD := 16
const TILES_BEHIND := 3
const START_SPEED := 10.0
const MAX_SPEED := 24.0
const ACCEL := 0.2
const GRAVITY := 28.0
const JUMP_VEL := 9.5
const SLIDE_TIME := 0.75
const LANE_SPEED := 14.0
const PICK_RADIUS := 1.1
const MIX := 22050
const SAVE_PATH := "user://sky_ruins_dash.cfg"

const UPGRADES := {
	"magnet": {"name": "Magnet Time", "desc": "Coin magnet power-up lasts longer", "costs": [100, 250, 500, 900, 1500]},
	"shield": {"name": "Guardian Shield", "desc": "Start every run with shields", "costs": [300, 900, 2000]},
	"value": {"name": "Golden Touch", "desc": "Every coin is worth more", "costs": [200, 600, 1400, 3000]},
	"luck": {"name": "Lucky Finds", "desc": "Power-ups appear more often", "costs": [150, 350, 700, 1200, 2000]},
}

# ------------------------------------------------------------ ui palette ----
const OUTLINE := Color(0.16, 0.10, 0.06)
const GOLD := Color(1.0, 0.82, 0.2)
const CREAM := Color(1.0, 0.96, 0.84)
const BROWN := Color(0.45, 0.27, 0.11)
const BTN_GREEN := Color(0.36, 0.76, 0.25)
const BTN_ORANGE := Color(1.0, 0.60, 0.15)
const BTN_BLUE := Color(0.27, 0.60, 0.95)
const BTN_RED := Color(0.93, 0.36, 0.30)
const BTN_GRAY := Color(0.6, 0.6, 0.62)

# ------------------------------------------------------------- save data ----
var total_coins := 0
var best_score := 0
var levels := {"magnet": 0, "shield": 0, "value": 0, "luck": 0}

# ------------------------------------------------------------- run state ----
var state := State.MENU
var shop_return := State.MENU
var time := 0.0
var tiles: Array = []
var cur := 0
var d := 0.0          # distance along current tile
var lat := 0.0        # sideways offset on the path
var lane := 0
var y := 0.0
var vy := 0.0
var sliding := false
var slide_t := 0.0
var speed := START_SPEED
var distance := 0.0
var run_coins := 0
var run_time := 0.0
var shields := 0
var invuln := 0.0
var magnet_t := 0.0
var queued_turn := 0
var anim_phase := 0.0
var last_step_sign := 1.0
var coin_streak := 0
var coin_streak_t := 0.0
var falling := false
var death_pos := Vector3.ZERO
var death_dir := Vector3.FORWARD
var death_fwd := 0.0
var death_token := 0
var is_new_best := false
var cam_dir := Vector3.FORWARD
var cam_shake := 0.0
var swipe_start := Vector2.ZERO
var swiping := false

# generator
var gen_pos := Vector3.ZERO
var gen_dir := Vector3.FORWARD
var heading := 0      # 0 = forward, -1 = left, +1 = right (never backwards)
var gen_index := 0
var since_turn := 0

# ----------------------------------------------------------------- nodes ----
var world: Node3D
var cam: Camera3D
var player: Node3D
var model: Node3D
var body: Node3D
var arm_l: Node3D
var arm_r: Node3D
var leg_l: Node3D
var leg_r: Node3D
var scarf_tail: MeshInstance3D
var bubble: MeshInstance3D
var mats := {}
var mesh_cache := {}
var sfx := {}
var players: Array = []
var player_idx := 0

# -------------------------------------------------------------------- ui ----
var ui_theme: Theme
var ui: CanvasLayer
var hud: Control
var coins_label: Label
var score_label: Label
var dist_label: Label
var shield_label: Label
var magnet_box: HBoxContainer
var magnet_bar: ProgressBar
var tip_label: Label
var pause_btn: Button
var menu_panel: Control
var menu_stats: Label
var pause_panel: Control
var death_panel: Control
var death_title: Label
var death_score: Label
var death_stats: Label
var new_best_label: Label
var shop_panel: Control
var shop_coins: Label
var shop_list: VBoxContainer


func _ready() -> void:
	randomize()
	_load()
	_make_materials()
	_make_sfx()
	_build_environment()
	_build_player()
	_build_ui()
	go_menu()


# ============================================================ game flow ====
func go_menu() -> void:
	_reset_world()
	state = State.MENU
	hud.hide()
	pause_panel.hide()
	death_panel.hide()
	shop_panel.hide()
	menu_stats.text = "Coins: %d     Best: %d" % [total_coins, best_score]
	_fade_in(menu_panel)


func start_run() -> void:
	_reset_world()
	state = State.PLAYING
	shields = int(levels["shield"])
	menu_panel.hide()
	pause_panel.hide()
	death_panel.hide()
	shop_panel.hide()
	hud.show()
	pause_btn.show()
	tip_label.show()
	tip_label.modulate.a = 1.0
	create_tween().tween_property(tip_label, "modulate:a", 0.0, 1.0).set_delay(3.0)


func open_shop() -> void:
	shop_return = state
	state = State.SHOP
	menu_panel.hide()
	death_panel.hide()
	_refresh_shop()
	_fade_in(shop_panel)


func close_shop() -> void:
	shop_panel.hide()
	if shop_return == State.DEAD:
		state = State.DEAD
		_fill_death_panel()
		_fade_in(death_panel)
	else:
		go_menu()


func pause_game() -> void:
	if state != State.PLAYING:
		return
	state = State.PAUSED
	pause_btn.hide()
	_fade_in(pause_panel)


func resume_game() -> void:
	state = State.PLAYING
	pause_panel.hide()
	pause_btn.show()


func _reset_world() -> void:
	for t in tiles:
		(t["node"] as Node3D).queue_free()
	tiles.clear()
	gen_pos = Vector3.ZERO
	gen_dir = Vector3.FORWARD
	heading = 0
	gen_index = 0
	since_turn = 0
	for i in TILES_AHEAD:
		_gen_tile()
	cur = 0
	d = 2.0
	lat = 0.0
	lane = 0
	y = 0.0
	vy = 0.0
	sliding = false
	speed = START_SPEED
	distance = 0.0
	run_coins = 0
	run_time = 0.0
	invuln = 0.0
	magnet_t = 0.0
	queued_turn = 0
	falling = false
	cam_shake = 0.0
	cam_dir = Vector3.FORWARD
	body.rotation = Vector3.ZERO
	model.rotation = Vector3.ZERO
	model.visible = true
	player.position = _world_pos(tiles[0], d, lat)


func _score() -> int:
	return int(distance) + run_coins * 10


func _end_run(fell: bool) -> void:
	state = State.DEAD
	falling = fell
	var t: Dictionary = tiles[cur]
	death_pos = _world_pos(t, d, lat)
	death_dir = t["dir"]
	death_fwd = speed * 0.6 if fell else -4.0
	if fell:
		_play("fall")
	else:
		_play("hit")
		cam_shake = 0.5
		vy = maxf(vy, 4.0)
	pause_btn.hide()
	bubble.hide()
	pause_panel.hide()
	model.visible = true
	total_coins += run_coins
	var sc := _score()
	is_new_best = sc > best_score
	if is_new_best:
		best_score = sc
	_save()
	death_token += 1
	get_tree().create_timer(1.3).timeout.connect(_on_death_timer.bind(death_token))


func _on_death_timer(token: int) -> void:
	if token != death_token or state != State.DEAD:
		return
	hud.hide()
	_fill_death_panel()
	_fade_in(death_panel)


func _fill_death_panel() -> void:
	death_title.text = "YOU FELL!" if falling else "WIPED OUT!"
	death_score.text = str(_score())
	death_stats.text = "Distance: %d m\nCoins: +%d  (total %d)\nBest: %d" % [int(distance), run_coins, total_coins, best_score]
	new_best_label.visible = is_new_best


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and state == State.PLAYING:
		pause_game()


# ================================================================ input ====
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if not k.pressed or k.echo:
			return
		match k.keycode:
			KEY_LEFT, KEY_A:
				_action("left")
			KEY_RIGHT, KEY_D:
				_action("right")
			KEY_UP, KEY_W:
				_action("jump")
			KEY_SPACE:
				_action("jump")
				_action("confirm")
			KEY_DOWN, KEY_S:
				_action("slide")
			KEY_ENTER, KEY_KP_ENTER:
				_action("confirm")
			KEY_ESCAPE, KEY_P:
				_action("pause")
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			swiping = mb.pressed
			swipe_start = mb.position
	elif event is InputEventMouseMotion and swiping:
		var delta := (event as InputEventMouseMotion).position - swipe_start
		if delta.length() > 45.0:
			swiping = false
			if absf(delta.x) > absf(delta.y):
				_action("right" if delta.x > 0 else "left")
			else:
				_action("slide" if delta.y > 0 else "jump")


func _action(a: String) -> void:
	match state:
		State.MENU:
			if a == "confirm":
				start_run()
		State.PAUSED:
			if a == "pause" or a == "confirm":
				resume_game()
		State.DEAD:
			if a == "confirm" and death_panel.visible:
				start_run()
		State.PLAYING:
			match a:
				"pause":
					pause_game()
				"left":
					_steer(-1)
				"right":
					_steer(1)
				"jump":
					if _grounded():
						vy = JUMP_VEL
						sliding = false
						_play("jump", -4.0)
				"slide":
					if not sliding:
						sliding = true
						slide_t = SLIDE_TIME
						if not _grounded():
							vy = -18.0
						_play("slide", -2.0)


func _grounded() -> bool:
	return y <= 0.001 and vy <= 0.0


func _turn_type(dirn: int) -> int:
	return T.TURN_L if dirn < 0 else T.TURN_R


func _steer(dirn: int) -> void:
	var t: Dictionary = tiles[cur]
	if t["type"] == _turn_type(dirn):
		_do_turn()
		return
	if t["type"] == T.STRAIGHT and tiles[cur + 1]["type"] == _turn_type(dirn) and float(t["len"]) - d < 7.0:
		queued_turn = dirn
		_play("swish", -8.0, 1.3)
		return
	var new_lane := clampi(lane + dirn, -1, 1)
	if new_lane != lane:
		lane = new_lane
		_play("swish", -6.0)


func _do_turn() -> void:
	# Keep the runner's world position continuous while switching to the next tile.
	var t: Dictionary = tiles[cur]
	var nt: Dictionary = tiles[cur + 1]
	var dir: Vector3 = t["dir"]
	var center: Vector3 = t["start"] + dir * TURN_LEN * 0.5
	var rel := _world_pos(t, d, lat) - center
	d = rel.dot(nt["dir"]) - TURN_LEN * 0.5
	lat = rel.dot(nt["right"])
	lane = clampi(roundi(lat / LANE_W), -1, 1)
	cur += 1
	queued_turn = 0
	_play("turn", -3.0)


# =============================================================== update ====
func _process(delta: float) -> void:
	time += delta
	match state:
		State.MENU, State.SHOP:
			_update_menu(delta)
		State.PLAYING:
			_update_run(delta)
		State.DEAD:
			_update_dead(delta)
	if state != State.PAUSED:
		_animate(delta)
		_spin_items()
	_update_hud()


func _update_menu(delta: float) -> void:
	var p := player.position
	var a := time * 0.25
	var cp := p + Vector3(sin(a), 0.0, cos(a)) * 5.5 + Vector3.UP * 2.2
	cam.position = cam.position.lerp(cp, minf(1.0, delta * 3.0))
	var fwd := p - cam.position
	fwd.y = 0.0
	var right := fwd.normalized().cross(Vector3.UP)
	cam.look_at(p + Vector3.UP * 1.1 - right * 1.7)


func _update_run(delta: float) -> void:
	run_time += delta
	speed = minf(MAX_SPEED, START_SPEED + run_time * ACCEL)
	var step := speed * delta
	d += step
	distance += step
	invuln = maxf(0.0, invuln - delta)
	magnet_t = maxf(0.0, magnet_t - delta)
	coin_streak_t -= delta
	if coin_streak_t <= 0.0:
		coin_streak = 0
	if sliding:
		slide_t -= delta
		if slide_t <= 0.0:
			sliding = false
	lat = move_toward(lat, lane * LANE_W, LANE_SPEED * delta)

	# --- advance along tiles / corners ---
	var t: Dictionary = tiles[cur]
	if queued_turn != 0 and t["type"] == _turn_type(queued_turn) and d >= 0.3:
		_do_turn()
		t = tiles[cur]
	while d >= float(t["len"]):
		if t["type"] != T.STRAIGHT:
			_end_run(true)   # ran straight off a corner
			return
		d -= float(t["len"])
		cur += 1
		_manage_tiles()
		t = tiles[cur]
		if queued_turn != 0 and t["type"] == T.STRAIGHT:
			queued_turn = 0

	# --- vertical motion ---
	var was_grounded := _grounded()
	vy -= GRAVITY * delta
	y += vy * delta
	if y <= 0.0:
		if _floor_at(t, d):
			if not was_grounded:
				_play("step", -6.0, 0.8)
			y = 0.0
			vy = 0.0
		elif shields > 0 and y > -0.5:
			shields -= 1   # the shield bounces you over a gap
			vy = JUMP_VEL * 1.1
			invuln = 1.0
			_play("shield")
		elif y < -0.4:
			_end_run(true)
			return

	# --- obstacles ---
	for o in t["obs"]:
		if o["hit"] or o["type"] == O.GAP or absf(d - float(o["d"])) > 0.45:
			continue
		var hit := false
		match o["type"]:
			O.LOW:
				hit = y < 0.65
			O.HIGH:
				hit = not sliding
			O.BLOCK:
				for ln in o["lanes"]:
					if absf(lat - ln * LANE_W) < 1.3:
						hit = true
		if hit and invuln <= 0.0:
			o["hit"] = true
			if shields > 0:
				shields -= 1
				invuln = 1.5
				cam_shake = 0.25
				_play("shield")
			else:
				_end_run(false)
				return

	# --- place player ---
	player.position = _world_pos(t, d, lat) + Vector3.UP * y
	var dir: Vector3 = t["dir"]
	model.rotation.y = lerp_angle(model.rotation.y, atan2(-dir.x, -dir.z), minf(1.0, delta * 14.0))
	model.visible = invuln <= 0.0 or int(invuln * 14.0) % 2 == 0

	_collect(delta)
	_update_camera(delta, t)


func _update_camera(delta: float, t: Dictionary) -> void:
	var dir: Vector3 = t["dir"]
	cam_dir = cam_dir.lerp(dir, minf(1.0, delta * 5.0)).normalized()
	var base := _world_pos(t, d, lat * 0.6)
	var target := base - cam_dir * 6.5 + Vector3.UP * (3.6 + y * 0.4)
	cam.position = cam.position.lerp(target, minf(1.0, delta * 8.0))
	cam.look_at(base + cam_dir * 6.0 + Vector3.UP * (1.0 + y * 0.3))
	_apply_shake(delta)


func _apply_shake(delta: float) -> void:
	cam_shake = maxf(0.0, cam_shake - delta)
	cam.h_offset = randf_range(-1, 1) * cam_shake * 0.6
	cam.v_offset = randf_range(-1, 1) * cam_shake * 0.6


func _update_dead(delta: float) -> void:
	vy -= GRAVITY * delta
	if falling:
		y = maxf(y + vy * delta, -35.0)
		death_fwd = move_toward(death_fwd, 0.0, 5.0 * delta)
	else:
		y = maxf(0.0, y + vy * delta)
		death_fwd = move_toward(death_fwd, 0.0, 10.0 * delta)
	death_pos += death_dir * death_fwd * delta
	player.position = death_pos + Vector3.UP * y
	cam.look_at(player.position + Vector3.UP * 0.8)
	_apply_shake(delta)


func _floor_at(t: Dictionary, dd: float) -> bool:
	for o in t["obs"]:
		if o["type"] == O.GAP and dd > float(o["d0"]) + 0.3 and dd < float(o["d1"]) - 0.3:
			return false
	return true


func _world_pos(t: Dictionary, dd: float, ll: float) -> Vector3:
	return t["start"] + t["dir"] * dd + t["right"] * ll


func _collect(delta: float) -> void:
	var pc := player.position + Vector3.UP * (0.5 if sliding else 1.0)
	for i in range(cur, mini(cur + 4, tiles.size())):
		var t: Dictionary = tiles[i]
		for c in t["coins"]:
			if c["taken"]:
				continue
			var n: Node3D = c["node"]
			var dist := n.global_position.distance_to(pc)
			if magnet_t > 0.0 and dist < 9.0:
				n.global_position = n.global_position.move_toward(pc, (speed + 18.0) * delta)
				dist = n.global_position.distance_to(pc)
			if dist < PICK_RADIUS:
				c["taken"] = true
				run_coins += 1 + int(levels["value"])
				coin_streak = mini(coin_streak + 1, 12)
				coin_streak_t = 0.6
				_play("coin", -5.0, 1.0 + coin_streak * 0.04)
				_pop_away(n)
		for it in t["items"]:
			if it["taken"]:
				continue
			var n2: Node3D = it["node"]
			if n2.global_position.distance_to(pc) < PICK_RADIUS + 0.2:
				it["taken"] = true
				if it["kind"] == "magnet":
					magnet_t = 6.0 + 2.0 * int(levels["magnet"])
				else:
					shields += 1
				_play("power")
				_pop_away(n2)


func _pop_away(n: Node3D) -> void:
	var tw := create_tween()
	tw.tween_property(n, "scale", Vector3.ONE * 0.01, 0.15)
	tw.tween_callback(n.hide)


func _manage_tiles() -> void:
	while tiles.size() - cur < TILES_AHEAD:
		_gen_tile()
	while cur > TILES_BEHIND:
		var old: Dictionary = tiles.pop_front()
		(old["node"] as Node3D).queue_free()
		cur -= 1


func _spin_items() -> void:
	for i in range(cur, tiles.size()):
		var t: Dictionary = tiles[i]
		for c in t["coins"]:
			(c["node"] as Node3D).rotation.y = time * 4.0 + float(c["d"])
		for it in t["items"]:
			var n: Node3D = it["node"]
			n.rotation.y = time * 2.0
			n.position.y = 1.1 + sin(time * 4.0) * 0.15
	bubble.visible = state == State.PLAYING and shields > 0
	if bubble.visible:
		bubble.scale = Vector3.ONE * (1.0 + sin(time * 6.0) * 0.04)


# ========================================================== animation ====
func _animate(delta: float) -> void:
	var k := minf(1.0, delta * 14.0)
	var ll := 0.0
	var lr := 0.0
	var al := 0.0
	var ar := 0.0
	var spread := 0.12
	var bx := 0.0
	var by := 0.0
	var scarf := 0.3 + sin(time * 18.0) * 0.25
	if state == State.MENU or state == State.SHOP:
		al = sin(time * 2.0) * 0.06
		ar = -al
		by = sin(time * 2.0) * 0.02
		scarf = 0.15 + sin(time * 3.0) * 0.08
	elif state == State.DEAD:
		if falling:
			al = 2.6 + sin(time * 22.0) * 0.5
			ar = 2.6 - sin(time * 22.0) * 0.5
			ll = sin(time * 18.0) * 0.8
			lr = -ll
			spread = 0.6
		else:
			bx = 1.5
			al = 2.8
			ar = 2.8
			spread = 0.5
			ll = 0.2
			lr = 0.3
	elif state == State.PLAYING:
		if sliding:
			bx = 1.2
			al = 2.0
			ar = 2.0
			spread = 0.4
		elif not _grounded():
			ll = 0.9
			lr = -0.4
			al = 2.4
			ar = 2.2
			spread = 0.35
		else:
			anim_phase += delta * speed * 1.1
			var s := sin(anim_phase)
			ll = s * 0.9
			lr = -s * 0.9
			al = -s * 0.8
			ar = s * 0.8
			by = absf(cos(anim_phase)) * 0.08
			if signf(s) != last_step_sign:
				last_step_sign = signf(s)
				_play("step", -16.0, randf_range(0.85, 1.15))
	else:
		return
	leg_l.rotation.x = lerpf(leg_l.rotation.x, ll, k)
	leg_r.rotation.x = lerpf(leg_r.rotation.x, lr, k)
	arm_l.rotation.x = lerpf(arm_l.rotation.x, al, k)
	arm_r.rotation.x = lerpf(arm_r.rotation.x, ar, k)
	arm_l.rotation.z = lerpf(arm_l.rotation.z, -spread, k)
	arm_r.rotation.z = lerpf(arm_r.rotation.z, spread, k)
	body.rotation.x = lerpf(body.rotation.x, bx, k)
	body.position.y = lerpf(body.position.y, by, k)
	scarf_tail.rotation.x = scarf


# ======================================================= map generator ====
func _gen_tile() -> void:
	var t := {
		"start": gen_pos, "dir": gen_dir, "right": gen_dir.cross(Vector3.UP),
		"type": T.STRAIGHT, "len": TILE_LEN, "obs": [], "coins": [], "items": [],
		"node": null, "shade": gen_index % 2,
	}
	var turn_dir := 0
	if gen_index > 5 and since_turn >= 3 and randf() < 0.3:
		turn_dir = (-1 if randf() < 0.5 else 1) if heading == 0 else -heading
	if turn_dir != 0:
		t["type"] = _turn_type(turn_dir)
		t["len"] = TURN_LEN
		var center: Vector3 = gen_pos + gen_dir * TURN_LEN * 0.5
		gen_dir = (t["right"] as Vector3) * turn_dir
		heading += turn_dir
		gen_pos = center + gen_dir * TURN_LEN * 0.5
		since_turn = 0
	else:
		_plan_straight(t)
		gen_pos += gen_dir * TILE_LEN
		since_turn += 1
	gen_index += 1
	_build_tile(t)
	tiles.append(t)


func _plan_straight(t: Dictionary) -> void:
	var obs_chance := 0.45 + minf(0.35, gen_index * 0.005)
	var otype := -1
	var blocked: Array = []
	if gen_index >= 4 and since_turn > 0 and randf() < obs_chance:
		otype = randi() % 4
		match otype:
			O.GAP:
				t["obs"].append({"type": O.GAP, "d": 5.0, "d0": 3.5, "d1": 6.5, "hit": false})
			O.BLOCK:
				var free := randi_range(-1, 1)
				for ln in [-1, 0, 1]:
					if ln != free and (blocked.is_empty() or randf() < 0.5):
						blocked.append(ln)
				t["obs"].append({"type": O.BLOCK, "d": 5.0, "lanes": blocked, "hit": false})
			_:
				t["obs"].append({"type": otype, "d": 5.0, "hit": false})
	# coins
	var coin_lane := 99
	if randf() < 0.75:
		coin_lane = randi_range(-1, 1)
		while coin_lane in blocked:
			coin_lane = randi_range(-1, 1)
		for i in 6:
			var cd := 1.0 + i * 1.6
			var h := 0.9
			if otype == O.LOW or otype == O.GAP:
				h += 1.3 * maxf(0.0, 1.0 - absf(cd - 5.0) / 3.0)
			elif otype == O.HIGH:
				h = 0.55
			t["coins"].append({"lane": coin_lane, "d": cd, "h": h, "taken": false})
	# power-ups
	if gen_index > 6 and randf() < 0.06 + 0.03 * int(levels["luck"]):
		var il := randi_range(-1, 1)
		while il in blocked or il == coin_lane:
			il = randi_range(-1, 1)
		t["items"].append({"kind": "magnet" if randf() < 0.65 else "shield", "lane": il, "d": 8.5, "taken": false})


func _build_tile(t: Dictionary) -> void:
	var root := Node3D.new()
	world.add_child(root)
	root.position = t["start"]
	root.basis = Basis.looking_at(t["dir"], Vector3.UP)
	t["node"] = root
	var fmat: Material = mats["stone"] if t["shade"] == 0 else mats["stone2"]

	if t["type"] == T.STRAIGHT:
		var gap = null
		for o in t["obs"]:
			if o["type"] == O.GAP:
				gap = o
		if gap:
			_floor(root, 0.0, gap["d0"], fmat)
			_floor(root, gap["d1"], TILE_LEN, fmat)
		else:
			_floor(root, 0.0, TILE_LEN, fmat)
		for o in t["obs"]:
			_build_obstacle(root, o)
		_decorate(root)
	else:
		var s := -1.0 if t["type"] == T.TURN_L else 1.0
		_floor(root, 0.0, TURN_LEN, fmat, false)
		_add(root, _box(Vector3(PATH_W + 0.6, 1.15, 0.3)), mats["stone_dark"], Vector3(0, -0.42, -TURN_LEN - 0.15))
		_add(root, _box(Vector3(0.3, 1.15, TURN_LEN)), mats["stone_dark"], Vector3(-s * 3.15, -0.42, -TURN_LEN * 0.5))
		for cx in [-0.6, 0.6]:
			var x: float = cx * s
			_add(root, _box(Vector3(1.13, 0.04, 0.28)), mats["arrow"], Vector3(x, 0.03, -3.4), Vector3(0, deg_to_rad(-45.0 * s), 0), false)
			_add(root, _box(Vector3(1.13, 0.04, 0.28)), mats["arrow"], Vector3(x, 0.03, -2.6), Vector3(0, deg_to_rad(45.0 * s), 0), false)
		_column(root, Vector3(-s * 3.8, 0, -TURN_LEN - 0.6), 4.5, true)

	var cmesh := _cyl(0.35, 0.35, 0.08, 20)
	for c in t["coins"]:
		var n := _add(root, cmesh, mats["gold"], Vector3(c["lane"] * LANE_W, c["h"], -c["d"]), Vector3(PI / 2, 0, 0))
		c["node"] = n
	for it in t["items"]:
		var holder := Node3D.new()
		root.add_child(holder)
		holder.position = Vector3(it["lane"] * LANE_W, 1.1, -it["d"])
		if it["kind"] == "magnet":
			var tor := TorusMesh.new()
			tor.inner_radius = 0.2
			tor.outer_radius = 0.38
			_add(holder, tor, mats["magnet"], Vector3.ZERO, Vector3(PI / 2, 0, 0))
			_add(holder, _box(Vector3(0.18, 0.18, 0.18)), mats["metal"], Vector3(-0.29, -0.3, 0))
			_add(holder, _box(Vector3(0.18, 0.18, 0.18)), mats["metal"], Vector3(0.29, -0.3, 0))
		else:
			_add(holder, _sph(0.4), mats["shield_item"], Vector3.ZERO)
			_add(holder, _box(Vector3(0.3, 0.36, 0.08)), mats["metal"], Vector3.ZERO)
		it["node"] = holder


func _floor(root: Node3D, a: float, b: float, fmat: Material, trims := true) -> void:
	var l := b - a
	var mid := -(a + l * 0.5)
	_add(root, _box(Vector3(PATH_W, 1.0, l)), fmat, Vector3(0, -0.5, mid))
	if trims:
		for sx in [-3.15, 3.15]:
			_add(root, _box(Vector3(0.3, 1.15, l)), mats["stone_dark"], Vector3(sx, -0.42, mid))
	for lx in [-1.0, 1.0]:
		_add(root, _box(Vector3(0.07, 0.02, l)), mats["groove"], Vector3(lx, 0.005, mid), Vector3.ZERO, false)
	var j := a + 2.5
	while j < b - 0.1:
		_add(root, _box(Vector3(PATH_W, 0.02, 0.06)), mats["groove"], Vector3(0, 0.005, -j), Vector3.ZERO, false)
		j += 2.5
	var rock := _add(root, _cyl(3.0, 0.3, 5.0, 7), mats["rock"], Vector3(0, -3.4, mid), Vector3.ZERO, false)
	rock.scale = Vector3(1.0, 1.0, maxf(0.4, l / 6.0))


func _build_obstacle(root: Node3D, o: Dictionary) -> void:
	var z := -float(o["d"])
	match o["type"]:
		O.LOW:
			_add(root, _cyl(0.35, 0.35, 6.2, 12), mats["wood"], Vector3(0, 0.35, z), Vector3(0, 0, PI / 2))
			for x in [-3.1, 3.1]:
				_add(root, _cyl(0.36, 0.36, 0.05, 12), mats["wood_end"], Vector3(x, 0.35, z), Vector3(0, 0, PI / 2))
		O.HIGH:
			for x in [-3.25, 3.25]:
				_add(root, _box(Vector3(0.5, 2.6, 0.5)), mats["stone_dark"], Vector3(x, 1.3, z))
			_add(root, _box(Vector3(7.0, 0.55, 0.6)), mats["stone_dark"], Vector3(0, 1.75, z))
			_add(root, _box(Vector3(5.6, 0.4, 0.05)), mats["banner"], Vector3(0, 1.3, z))
			for x in [-2.0, 0.0, 2.0]:
				_add(root, _sph(0.12), mats["gold"], Vector3(x, 1.3, z - 0.05))
		O.GAP:
			for x in [-2.2, 0.4, 2.3]:
				_add(root, _box(Vector3(0.7, 0.5, 0.6)), mats["rock"], Vector3(x, -0.15, -float(o["d0"]) + 0.1), Vector3(0.3, x, 0.2))
		O.BLOCK:
			for ln in o["lanes"]:
				var x: float = ln * LANE_W
				_add(root, _box(Vector3(1.8, 2.0, 1.2)), mats["block"], Vector3(x, 1.0, z))
				_add(root, _box(Vector3(1.9, 0.25, 1.3)), mats["moss"], Vector3(x, 2.1, z))
				_add(root, _box(Vector3(0.8, 0.8, 0.05)), mats["rune"], Vector3(x, 1.0, z + 0.62), Vector3.ZERO, false)


func _decorate(root: Node3D) -> void:
	if randf() < 0.55:
		for sx in [-3.8, 3.8]:
			if randf() < 0.8:
				var broken := randf() < 0.3
				_column(root, Vector3(sx, 0, -5.0), snappedf(randf_range(1.5, 2.5) if broken else randf_range(3.0, 5.0), 0.5), not broken and randf() < 0.4, broken)
	if randf() < 0.3:
		var side := -1.0 if randf() < 0.5 else 1.0
		var p := Vector3(side * randf_range(12, 22), -randf_range(2, 8), -randf_range(0, 10))
		_add(root, _cyl(3.0, 0.3, 4.5, 7), mats["rock"], p + Vector3(0, -2.4, 0), Vector3.ZERO, false)
		_add(root, _cyl(3.1, 3.1, 0.4, 14), mats["grass"], p, Vector3.ZERO, false)
		_add(root, _cyl(0.2, 0.28, 2.0, 8), mats["wood"], p + Vector3(0, 1.2, 0), Vector3.ZERO, false)
		_add(root, _sph(1.2), mats["leaf"], p + Vector3(0, 2.6, 0), Vector3.ZERO, false)
		_add(root, _sph(0.8), mats["leaf2"], p + Vector3(0.6, 3.3, 0.2), Vector3.ZERO, false)
	if randf() < 0.35:
		var side2 := -1.0 if randf() < 0.5 else 1.0
		var cp := Vector3(side2 * randf_range(8, 28), -randf_range(9, 18), -randf_range(0, 10))
		for b in [Vector4(0, 0, 0, 2.5), Vector4(2.2, -0.4, 0.5, 1.8), Vector4(-2.0, -0.5, -0.3, 1.9), Vector4(0.5, 0.8, 0.2, 1.6)]:
			_add(root, _sph(b.w), mats["cloud"], cp + Vector3(b.x, b.y, b.z), Vector3.ZERO, false)


func _column(root: Node3D, p: Vector3, h: float, torch: bool, broken := false) -> void:
	_add(root, _box(Vector3(1.0, 0.4, 1.0)), mats["stone_dark"], p + Vector3(0, 0.2, 0))
	_add(root, _cyl(0.35, 0.4, h, 10), mats["column"], p + Vector3(0, h * 0.5, 0), Vector3(0, 0, 0.08 if broken else 0.0))
	if broken:
		return
	_add(root, _box(Vector3(1.0, 0.35, 1.0)), mats["stone_dark"], p + Vector3(0, h + 0.17, 0))
	if torch:
		_add(root, _cyl(0.25, 0.15, 0.3, 8), mats["metal"], p + Vector3(0, h + 0.5, 0))
		_add(root, _sph(0.22), mats["flame"], p + Vector3(0, h + 0.78, 0), Vector3.ZERO, false)
		_add(root, _sph(0.12), mats["flame_core"], p + Vector3(0, h + 0.75, 0), Vector3.ZERO, false)


# ============================================================== builders ====
func _build_environment() -> void:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.32, 0.55, 0.92)
	sky_mat.sky_horizon_color = Color(1.0, 0.82, 0.62)
	sky_mat.ground_horizon_color = Color(1.0, 0.85, 0.7)
	sky_mat.ground_bottom_color = Color(0.85, 0.75, 0.8)
	sky_mat.sun_angle_max = 30.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(1.0, 0.84, 0.72)
	env.fog_density = 0.0065
	env.fog_sky_affect = 0.0
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_bloom = 0.05
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -35, 0)
	sun.light_color = Color(1.0, 0.93, 0.82)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 60.0
	add_child(sun)

	world = Node3D.new()
	add_child(world)
	cam = Camera3D.new()
	cam.fov = 70.0
	cam.far = 300.0
	add_child(cam)
	cam.make_current()
	cam.position = Vector3(4, 3, 4)


func _build_player() -> void:
	var skin := _mat(Color(1.0, 0.8, 0.62))
	var shirt := _mat(Color(0.16, 0.62, 0.66))
	var pants := _mat(Color(0.33, 0.27, 0.45))
	var boots := _mat(Color(0.28, 0.17, 0.1))
	var bag := _mat(Color(0.62, 0.42, 0.2))
	var hat := _mat(Color(0.88, 0.58, 0.22))
	var scarf := _mat(Color(0.92, 0.22, 0.22))
	var dark := _mat(Color(0.08, 0.06, 0.05), 0.4)

	player = Node3D.new()
	add_child(player)
	model = Node3D.new()
	player.add_child(model)
	body = Node3D.new()
	model.add_child(body)

	leg_l = _pivot(body, Vector3(-0.17, 0.8, 0))
	leg_r = _pivot(body, Vector3(0.17, 0.8, 0))
	for leg in [leg_l, leg_r]:
		_add(leg, _cap(0.13, 0.8), pants, Vector3(0, -0.4, 0))
		_add(leg, _box(Vector3(0.24, 0.16, 0.36)), boots, Vector3(0, -0.76, -0.06))

	_add(body, _cap(0.32, 0.95), shirt, Vector3(0, 1.17, 0))
	_add(body, _cyl(0.335, 0.335, 0.1, 16), boots, Vector3(0, 0.86, 0))
	_add(body, _box(Vector3(0.5, 0.55, 0.26)), bag, Vector3(0, 1.22, 0.34))
	_add(body, _cyl(0.12, 0.12, 0.6, 10), _mat(Color(0.5, 0.65, 0.35)), Vector3(0, 1.55, 0.36), Vector3(0, 0, PI / 2))

	_add(body, _sph(0.3), skin, Vector3(0, 1.84, 0))
	for ex in [-0.1, 0.1]:
		_add(body, _sph(0.055), dark, Vector3(ex, 1.88, -0.27))
	_add(body, _sph(0.06), _mat(Color(1.0, 0.6, 0.5)), Vector3(0, 1.8, -0.3))
	_add(body, _cyl(0.44, 0.44, 0.05, 20), hat, Vector3(0, 2.02, 0))
	_add(body, _cyl(0.24, 0.28, 0.24, 16), hat, Vector3(0, 2.15, 0))
	_add(body, _cyl(0.285, 0.285, 0.06, 16), scarf, Vector3(0, 2.07, 0))
	var tor := TorusMesh.new()
	tor.inner_radius = 0.17
	tor.outer_radius = 0.3
	_add(body, tor, scarf, Vector3(0, 1.56, 0))
	var tail_pivot := _pivot(body, Vector3(0.1, 1.56, 0.25))
	scarf_tail = _add(tail_pivot, _box(Vector3(0.14, 0.05, 0.55)), scarf, Vector3(0, 0, 0.27))

	arm_l = _pivot(body, Vector3(-0.42, 1.47, 0))
	arm_r = _pivot(body, Vector3(0.42, 1.47, 0))
	for arm in [arm_l, arm_r]:
		_add(arm, _cap(0.1, 0.68), shirt, Vector3(0, -0.3, 0))
		_add(arm, _sph(0.11), skin, Vector3(0, -0.64, 0))

	bubble = _add(player, _sph(1.25), mats["bubble"], Vector3(0, 1.0, 0), Vector3.ZERO, false)


func _make_materials() -> void:
	mats["stone"] = _mat(Color(0.86, 0.76, 0.62))
	mats["stone2"] = _mat(Color(0.80, 0.70, 0.57))
	mats["stone_dark"] = _mat(Color(0.58, 0.48, 0.40))
	mats["column"] = _mat(Color(0.93, 0.88, 0.78))
	mats["groove"] = _mat(Color(0.55, 0.45, 0.36))
	mats["rock"] = _mat(Color(0.52, 0.42, 0.38))
	mats["block"] = _mat(Color(0.62, 0.55, 0.5))
	mats["moss"] = _mat(Color(0.38, 0.66, 0.3))
	mats["grass"] = _mat(Color(0.45, 0.75, 0.32))
	mats["leaf"] = _mat(Color(0.3, 0.62, 0.3))
	mats["leaf2"] = _mat(Color(0.42, 0.72, 0.34))
	mats["wood"] = _mat(Color(0.55, 0.34, 0.18))
	mats["wood_end"] = _mat(Color(0.85, 0.66, 0.42))
	mats["banner"] = _mat(Color(0.85, 0.25, 0.25))
	mats["metal"] = _mat(Color(0.75, 0.75, 0.8), 0.3, 0.8)
	mats["gold"] = _mat(Color(1.0, 0.72, 0.1), 0.25, 0.8, Color(1.0, 0.6, 0.05), 0.25)
	mats["rune"] = _mat(Color(0.3, 0.9, 1.0), 0.5, 0.0, Color(0.2, 0.8, 1.0), 2.0)
	mats["arrow"] = _mat(Color(1.0, 0.85, 0.3), 0.5, 0.0, Color(1.0, 0.75, 0.2), 1.5)
	mats["flame"] = _mat(Color(1.0, 0.5, 0.1), 1.0, 0.0, Color(1.0, 0.45, 0.05), 4.0)
	mats["flame_core"] = _mat(Color(1.0, 0.9, 0.5), 1.0, 0.0, Color(1.0, 0.9, 0.4), 5.0)
	mats["magnet"] = _mat(Color(0.95, 0.2, 0.2), 0.4, 0.2, Color(1.0, 0.15, 0.1), 1.0)
	mats["cloud"] = _mat(Color(1.0, 0.97, 0.95), 1.0)
	var sh := _mat(Color(0.3, 0.7, 1.0, 0.55), 0.2, 0.0, Color(0.2, 0.6, 1.0), 1.5)
	sh.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mats["shield_item"] = sh
	var bub := _mat(Color(0.4, 0.75, 1.0, 0.18), 0.1, 0.0, Color(0.3, 0.6, 1.0), 0.6)
	bub.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bub.cull_mode = BaseMaterial3D.CULL_DISABLED
	mats["bubble"] = bub


func _mat(c: Color, rough := 0.85, metal := 0.0, emit := Color.BLACK, emit_e := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	if emit_e > 0.0:
		m.emission_enabled = true
		m.emission = emit
		m.emission_energy_multiplier = emit_e
	return m


func _add(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, rot := Vector3.ZERO, shadow := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	if not shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


func _pivot(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n


func _box(s: Vector3) -> BoxMesh:
	var key := "b%s" % s
	if not mesh_cache.has(key):
		var m := BoxMesh.new()
		m.size = s
		mesh_cache[key] = m
	return mesh_cache[key]


func _cyl(top: float, bottom: float, h: float, segs := 16) -> CylinderMesh:
	var key := "c%s_%s_%s_%s" % [top, bottom, h, segs]
	if not mesh_cache.has(key):
		var m := CylinderMesh.new()
		m.top_radius = top
		m.bottom_radius = bottom
		m.height = h
		m.radial_segments = segs
		m.rings = 1
		mesh_cache[key] = m
	return mesh_cache[key]


func _sph(r: float) -> SphereMesh:
	var key := "s%s" % r
	if not mesh_cache.has(key):
		var m := SphereMesh.new()
		m.radius = r
		m.height = r * 2.0
		m.radial_segments = 20
		m.rings = 10
		mesh_cache[key] = m
	return mesh_cache[key]


func _cap(r: float, h: float) -> CapsuleMesh:
	var key := "k%s_%s" % [r, h]
	if not mesh_cache.has(key):
		var m := CapsuleMesh.new()
		m.radius = r
		m.height = h
		mesh_cache[key] = m
	return mesh_cache[key]


# ========================================================= sound effects ====
func _make_sfx() -> void:
	var defs := {
		"coin": 0.2, "jump": 0.22, "slide": 0.35, "swish": 0.14, "turn": 0.25,
		"hit": 0.45, "fall": 0.9, "click": 0.05, "buy": 0.35, "deny": 0.25,
		"power": 0.4, "shield": 0.45, "step": 0.06,
	}
	for kind in defs:
		sfx[kind] = _wav(kind, defs[kind])
	for i in 10:
		var p := AudioStreamPlayer.new()
		add_child(p)
		players.append(p)


func _play(kind: String, vol := 0.0, pitch := 1.0) -> void:
	var p: AudioStreamPlayer = players[player_idx]
	player_idx = (player_idx + 1) % players.size()
	p.stream = sfx[kind]
	p.volume_db = vol
	p.pitch_scale = pitch
	p.play()


func _wav(kind: String, dur: float) -> AudioStreamWAV:
	var n := int(dur * MIX)
	var data := PackedByteArray()
	data.resize(n * 2)
	var st := {"ph": 0.0, "lp": 0.0}
	for i in n:
		var t := float(i) / MIX
		var s := _sample(kind, t, t / dur, st)
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 30000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = MIX
	w.stereo = false
	w.data = data
	return w


func _sample(kind: String, t: float, k: float, st: Dictionary) -> float:
	match kind:
		"coin":
			return _osc(st, 988.0 if t < 0.06 else 1319.0, true) * 0.3 * _env(k, 0.02)
		"jump":
			return _osc(st, lerpf(260.0, 720.0, k)) * 0.5 * _env(k, 0.05)
		"slide":
			return _noise(st, 0.12) * 1.6 * sin(PI * k)
		"swish":
			return _noise(st, 0.3) * 0.9 * sin(PI * k)
		"turn":
			return (_noise(st, 0.25) * 0.8 + _osc(st, lerpf(350.0, 900.0, k)) * 0.15) * sin(PI * k)
		"hit":
			return (_osc(st, lerpf(170.0, 40.0, k)) * 0.7 + _noise(st, 0.5) * 0.6 * (1.0 - k)) * _env(k, 0.01)
		"fall":
			return _osc(st, lerpf(800.0, 110.0, k) * (1.0 + 0.03 * sin(t * 40.0))) * 0.4 * (1.0 - k)
		"click":
			return _osc(st, 700.0) * 0.4 * _env(k, 0.05)
		"buy":
			var notes := [523.25, 659.25, 783.99, 1046.5]
			var idx := mini(int(k * 4.0), 3)
			return _osc(st, notes[idx], true) * 0.25 * (1.0 - fmod(k * 4.0, 1.0) * 0.5) * (1.0 - k * 0.5)
		"deny":
			return _osc(st, 190.0 if k < 0.5 else 140.0, true) * 0.25 * _env(k, 0.02)
		"power":
			return _osc(st, lerpf(400.0, 1600.0, k) * (1.0 + 0.06 * sin(t * 70.0))) * 0.4 * _env(k, 0.05)
		"shield":
			return (_noise(st, 0.9) * 0.35 + _osc(st, 2200.0 - 1200.0 * k) * 0.3) * pow(1.0 - k, 3.0)
		"step":
			return _noise(st, 0.1) * 2.0 * pow(1.0 - k, 4.0)
	return 0.0


func _osc(st: Dictionary, f: float, square := false) -> float:
	st["ph"] = float(st["ph"]) + TAU * f / MIX
	var s := sin(float(st["ph"]))
	return signf(s) * 0.6 if square else s


func _noise(st: Dictionary, cutoff: float) -> float:
	st["lp"] = lerpf(float(st["lp"]), randf_range(-1.0, 1.0), cutoff)
	return float(st["lp"])


func _env(k: float, attack: float) -> float:
	return minf(1.0, k / attack) * pow(1.0 - k, 2.0)


# =================================================================== ui ====
func _update_hud() -> void:
	if not hud.visible:
		return
	coins_label.text = "%d" % run_coins
	score_label.text = str(_score())
	dist_label.text = "%d m" % int(distance)
	shield_label.visible = shields > 0
	shield_label.text = "SHIELD x%d" % shields
	magnet_box.visible = magnet_t > 0.0
	magnet_bar.max_value = 6.0 + 2.0 * int(levels["magnet"])
	magnet_bar.value = magnet_t


func _build_ui() -> void:
	ui_theme = Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Comic Sans MS", "Chalkboard SE", "Comic Neue", "sans-serif"])
	font.font_weight = 700
	ui_theme.default_font = font
	ui_theme.default_font_size = 28
	ui = CanvasLayer.new()
	add_child(ui)

	# --- HUD -------------------------------------------------------------
	hud = _full_rect(Control.MOUSE_FILTER_IGNORE)
	var coin_row := HBoxContainer.new()
	coin_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	coin_row.position = Vector2(28, 22)
	coin_row.add_theme_constant_override("separation", 10)
	hud.add_child(coin_row)
	var coin_icon := Panel.new()
	coin_icon.custom_minimum_size = Vector2(38, 38)
	coin_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	coin_icon.add_theme_stylebox_override("panel", _sbox(GOLD, Color(0.7, 0.45, 0.05), 4, 19, 0))
	coin_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	coin_row.add_child(coin_icon)
	coins_label = _label("0", 42, GOLD, 10)
	coin_row.add_child(coins_label)

	score_label = _label("0", 60)
	hud.add_child(score_label)
	score_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	score_label.position.y = 8
	dist_label = _label("0 m", 28)
	hud.add_child(dist_label)
	dist_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	dist_label.position.y = 84

	pause_btn = _button("II", BTN_ORANGE, pause_game, Vector2(66, 66), 28)
	hud.add_child(pause_btn)
	pause_btn.anchor_left = 1.0
	pause_btn.anchor_right = 1.0
	pause_btn.offset_left = -92
	pause_btn.offset_right = -26
	pause_btn.offset_top = 20
	pause_btn.offset_bottom = 86

	var status := VBoxContainer.new()
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(status)
	status.anchor_top = 1.0
	status.anchor_bottom = 1.0
	status.offset_left = 28
	status.offset_top = -130
	shield_label = _label("SHIELD x1", 30, Color(0.5, 0.85, 1.0), 9)
	shield_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	status.add_child(shield_label)
	magnet_box = HBoxContainer.new()
	magnet_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status.add_child(magnet_box)
	magnet_box.add_child(_label("MAGNET", 30, Color(1.0, 0.45, 0.4), 9))
	magnet_bar = ProgressBar.new()
	magnet_bar.show_percentage = false
	magnet_bar.custom_minimum_size = Vector2(200, 22)
	magnet_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	magnet_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	magnet_bar.add_theme_stylebox_override("background", _sbox(Color(0, 0, 0, 0.35), OUTLINE, 3, 11, 0))
	magnet_bar.add_theme_stylebox_override("fill", _sbox(Color(1.0, 0.35, 0.3), OUTLINE, 3, 11, 0))
	magnet_box.add_child(magnet_bar)

	tip_label = _label("A/D or arrows: dodge & TURN at corners   •   W/Space: jump   •   S: slide", 24)
	hud.add_child(tip_label)
	tip_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	tip_label.offset_top = -80
	tip_label.offset_bottom = -40
	tip_label.grow_horizontal = Control.GROW_DIRECTION_BOTH

	# --- Main menu -------------------------------------------------------
	menu_panel = _full_rect(Control.MOUSE_FILTER_STOP)
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 16)
	menu_panel.add_child(mv)
	mv.anchor_top = 0.5
	mv.anchor_bottom = 0.5
	mv.offset_left = 90
	mv.grow_vertical = Control.GROW_DIRECTION_BOTH
	mv.add_child(_label("SKY RUINS\nDASH", 84, GOLD, 18))
	mv.add_child(_spacer(8))
	mv.add_child(_button("PLAY", BTN_GREEN, start_run, Vector2(300, 72)))
	mv.add_child(_button("SHOP", BTN_ORANGE, open_shop, Vector2(300, 72)))
	mv.add_child(_button("QUIT", BTN_RED, func(): get_tree().quit(), Vector2(300, 72)))
	menu_stats = _label("", 26)
	mv.add_child(menu_stats)
	mv.add_child(_label("A/D: dodge & turn   W: jump   S: slide   ESC: pause", 18, Color.WHITE, 6))

	# --- Pause -----------------------------------------------------------
	pause_panel = _full_rect(Control.MOUSE_FILTER_STOP, 0.45)
	var pv := _center_vbox(pause_panel)
	pv.add_child(_label("PAUSED", 72, Color.WHITE, 16))
	pv.add_child(_button("RESUME", BTN_GREEN, resume_game))
	pv.add_child(_button("RESTART", BTN_ORANGE, start_run))
	pv.add_child(_button("MAIN MENU", BTN_BLUE, go_menu))

	# --- Death -----------------------------------------------------------
	death_panel = _full_rect(Control.MOUSE_FILTER_STOP, 0.35)
	var dv := _center_vbox(death_panel)
	death_title = _label("WIPED OUT!", 66, Color(1, 0.45, 0.32), 16)
	dv.add_child(death_title)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _sbox(CREAM, BROWN, 5, 22, 26))
	card.custom_minimum_size = Vector2(380, 0)
	card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	dv.add_child(card)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 0)
	card.add_child(cv)
	cv.add_child(_label("SCORE", 24, Color(0.85, 0.45, 0.15), 0))
	death_score = _label("0", 60, BROWN, 0)
	cv.add_child(death_score)
	death_stats = _label("", 22, BROWN, 0)
	death_stats.add_theme_constant_override("line_spacing", 0)
	cv.add_child(death_stats)
	new_best_label = _label("NEW BEST!", 28, Color(0.95, 0.25, 0.35), 0)
	cv.add_child(new_best_label)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	dv.add_child(row)
	row.add_child(_button("PLAY AGAIN", BTN_GREEN, start_run, Vector2(230, 66), 26))
	row.add_child(_button("SHOP", BTN_ORANGE, open_shop, Vector2(150, 66), 26))
	row.add_child(_button("MENU", BTN_BLUE, go_menu, Vector2(150, 66), 26))

	# --- Shop ------------------------------------------------------------
	shop_panel = _full_rect(Control.MOUSE_FILTER_STOP, 0.45)
	var sv := _center_vbox(shop_panel)
	sv.add_child(_label("SHOP", 64, GOLD, 16))
	shop_coins = _label("", 30, GOLD, 9)
	sv.add_child(shop_coins)
	var scard := PanelContainer.new()
	scard.add_theme_stylebox_override("panel", _sbox(CREAM, BROWN, 5, 22, 20))
	scard.custom_minimum_size = Vector2(760, 0)
	sv.add_child(scard)
	shop_list = VBoxContainer.new()
	shop_list.add_theme_constant_override("separation", 10)
	scard.add_child(shop_list)
	sv.add_child(_button("BACK", BTN_BLUE, close_shop))


func _refresh_shop() -> void:
	shop_coins.text = "Coins: %d" % total_coins
	for c in shop_list.get_children():
		c.queue_free()
	for key in UPGRADES:
		var u: Dictionary = UPGRADES[key]
		var costs: Array = u["costs"]
		var lvl: int = levels[key]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		shop_list.add_child(row)
		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.add_theme_constant_override("separation", 2)
		row.add_child(info)
		var name_l := _label(u["name"], 30, BROWN, 0)
		name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		info.add_child(name_l)
		var desc_l := _label("%s  %s" % [u["desc"], _effect_text(key, lvl)], 18, Color(0.5, 0.38, 0.25), 0)
		desc_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		info.add_child(desc_l)
		var pips := HBoxContainer.new()
		info.add_child(pips)
		for i in costs.size():
			var pip := Panel.new()
			pip.custom_minimum_size = Vector2(34, 12)
			pip.add_theme_stylebox_override("panel", _sbox(GOLD if i < lvl else Color(0.82, 0.76, 0.66), BROWN, 2, 6, 0))
			pips.add_child(pip)
		var b: Button
		if lvl >= costs.size():
			b = _button("MAXED", BTN_GRAY, func(): _play("deny"), Vector2(190, 60), 24)
		else:
			var cost: int = costs[lvl]
			b = _button("%d coins" % cost, BTN_GREEN if total_coins >= cost else BTN_GRAY, _buy.bind(key), Vector2(190, 60), 24)
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(b)


func _effect_text(key: String, lvl: int) -> String:
	match key:
		"magnet":
			return "(%ds)" % (6 + 2 * lvl)
		"shield":
			return "(%d per run)" % lvl
		"value":
			return "(%d per coin)" % (1 + lvl)
		"luck":
			return "(+%d%%)" % (lvl * 50)
	return ""


func _buy(key: String) -> void:
	var costs: Array = UPGRADES[key]["costs"]
	var lvl: int = levels[key]
	if lvl < costs.size() and total_coins >= int(costs[lvl]):
		total_coins -= int(costs[lvl])
		levels[key] = lvl + 1
		_save()
		_play("buy")
	else:
		_play("deny")
	_refresh_shop()


func _full_rect(filter: Control.MouseFilter, dim := 0.0) -> Control:
	var c := Control.new()
	c.theme = ui_theme
	c.mouse_filter = filter
	ui.add_child(c)
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.hide()
	if dim > 0.0:
		var cr := ColorRect.new()
		cr.color = Color(0.05, 0.04, 0.12, dim)
		cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.add_child(cr)
		cr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return c


func _center_vbox(parent: Control) -> VBoxContainer:
	var cc := CenterContainer.new()
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(cc)
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 14)
	cc.add_child(vb)
	return vb


func _spacer(h: float) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s


func _label(text: String, size: int, color := Color.WHITE, outline := 10) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", OUTLINE)
	l.add_theme_constant_override("outline_size", outline)
	l.add_theme_constant_override("line_spacing", -14)
	return l


func _button(text: String, base: Color, on_press: Callable, min_size := Vector2(280, 68), font_size := 30) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = min_size
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.add_theme_font_size_override("font_size", font_size)
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(k, Color.WHITE)
	b.add_theme_color_override("font_outline_color", OUTLINE)
	b.add_theme_constant_override("outline_size", 8)
	b.add_theme_stylebox_override("normal", _btn_box(base, 9))
	b.add_theme_stylebox_override("hover", _btn_box(base.lightened(0.15), 9))
	b.add_theme_stylebox_override("pressed", _btn_box(base.darkened(0.08), 4))
	b.add_theme_stylebox_override("hover_pressed", _btn_box(base.darkened(0.08), 4))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(func(): _play("click", -6.0))
	b.pressed.connect(on_press)
	return b


func _btn_box(c: Color, depth: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_corner_radius_all(18)
	s.set_border_width_all(4)
	s.border_width_bottom = depth
	s.border_color = c.darkened(0.45)
	s.content_margin_top = 4 + (9 - depth)
	s.content_margin_bottom = 4
	s.content_margin_left = 12
	s.content_margin_right = 12
	return s


func _sbox(bg: Color, border: Color, bw: int, radius: int, margin: float) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(bw)
	s.set_corner_radius_all(radius)
	s.content_margin_left = margin
	s.content_margin_right = margin
	s.content_margin_top = margin * 0.6
	s.content_margin_bottom = margin * 0.6
	return s


func _fade_in(c: CanvasItem) -> void:
	c.show()
	c.modulate.a = 0.0
	create_tween().tween_property(c, "modulate:a", 1.0, 0.22)


# ================================================================= save ====
func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	total_coins = int(cfg.get_value("save", "coins", 0))
	best_score = int(cfg.get_value("save", "best", 0))
	for key in levels:
		levels[key] = int(cfg.get_value("upgrades", key, 0))


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("save", "coins", total_coins)
	cfg.set_value("save", "best", best_score)
	for key in levels:
		cfg.set_value("upgrades", key, levels[key])
	cfg.save(SAVE_PATH)

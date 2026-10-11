class_name ReplayMatch
extends Node
## Plays a saved Replay (GameState.replay): takes over the FightManager's tick and feeds
## both fighters the recorded inputs, which reproduces the match exactly. Every recorded
## checksum is checked on the way; a mismatch stops with "out of sync". After the last
## recorded tick the match plays on with neutral inputs, so the victory scene shows.
## Controls (keyboard / pad): Space or A pause, . or RB one tick while paused, Left/Right
## seek 5 s, Up/Down speed (¼× to 4×), H or Y hide the HUD, C or X camera mode, Esc menu.
## Seeking loads the nearest snapshot (one is kept every SNAPSHOT_INTERVAL ticks as the
## replay first passes it) and re-simulates the rest with effects muted.

const SPEEDS := [0.25, 0.5, 1.0, 2.0, 4.0]
const SEEK_TICKS := 300
const SNAPSHOT_INTERVAL := 300
const AFTER_END_TICKS := 600 # neutral ticks played after the end (the victory scene)

var manager: Node # FightManager
var replay: Replay
## The next tick to simulate.
var frame := 0
var paused := false
var speed_index := 2
var diverged := false
## Recorded checksums this playback matched.
var checks_passed := 0
var hud_hidden := false

var _controllers: Array[NetInputController] = []
var _snapshots := {} # tick -> FightManager.save_state()
var _step_once := false
var _bar: Label
var _layer: CanvasLayer


func setup(fight_manager: Node, recorded: Replay) -> void:
	manager = fight_manager
	replay = recorded
	name = "ReplayMatch"
	manager.set_physics_process(false)
	for fighter: Fighter in manager.fighters:
		var controller := NetInputController.new()
		fighter.controller = controller
		_controllers.append(controller)
	var hud: FightHud = manager.hud
	hud.p1_name.text = str(replay.meta.get("p1_name", manager.fighters[0].data.display_name))
	hud.p2_name.text = str(replay.meta.get("p2_name", manager.fighters[1].data.display_name))
	hud.configure_result("Watch Again", "Replays", "Main Menu")
	_snapshots[0] = manager.save_state()
	_build_ui()
	_update_bar()


func _exit_tree() -> void:
	if manager and manager.camera:
		manager.camera.normal_time_scale = 1.0


func speed() -> float:
	return SPEEDS[speed_index]


func end_tick() -> int:
	return replay.ticks()


func _physics_process(_delta: float) -> void:
	if manager._waiting_for_screen or diverged:
		return
	if paused and not _step_once:
		return
	var steps := 1 if paused or speed() <= 1.0 else int(speed())
	_step_once = false
	for i in steps:
		if not advance():
			break
	_update_bar()


## One tick: the recorded inputs (checked against the recorded checksum first), or
## neutral after the end. False when there's nothing more to play or it went out of sync.
func advance() -> bool:
	if frame >= end_tick() + AFTER_END_TICKS:
		return false
	if replay.checksums.has(frame) and frame <= end_tick():
		var mine: int = manager.checksum(manager.save_state())
		if mine != int(replay.checksums[frame]):
			_diverge(mine, int(replay.checksums[frame]))
			return false
		checks_passed += 1
	if frame % SNAPSHOT_INTERVAL == 0 and not _snapshots.has(frame):
		_snapshots[frame] = manager.save_state()
	var neutral := InputBuffer.pack(InputBuffer.NEUTRAL, 0)
	_controllers[0].raw = replay.p1[frame] if frame < end_tick() else neutral
	_controllers[1].raw = replay.p2[frame] if frame < end_tick() else neutral
	manager.step()
	frame += 1
	return true


## Jumps to `tick` (clamped to the recording): from the nearest snapshot at or before
## it, re-simulated muted.
func seek(tick: int) -> void:
	tick = clampi(tick, 0, end_tick())
	if diverged:
		return
	if tick < frame or manager.phase == manager.Phase.MATCH_OVER:
		var from := 0
		for t: int in _snapshots:
			if t <= tick and t > from:
				from = t
		manager.load_state(_snapshots[from])
		frame = from
	manager.resimulating = true
	while frame < tick:
		if not advance():
			break
	manager.resimulating = false
	_after_jump()
	_update_bar()


func restart() -> void:
	seek(0)


## Clears what a jump left on screen: call-outs, the result menu, the victory cinematic,
## the camera's position.
func _after_jump() -> void:
	var hud: FightHud = manager.hud
	hud.announce("")
	hud.hide_result()
	if manager.phase != manager.Phase.MATCH_OVER:
		hud.end_cinematic()
		for fighter: Fighter in manager.fighters:
			fighter.victory_clip = &""
		manager.match_winner = null
	if manager.camera.manager:
		manager.camera.snap()
	for fighter: Fighter in manager.fighters:
		fighter.reset_physics_interpolation()


func toggle_pause() -> void:
	paused = not paused
	_update_bar()


func change_speed(step: int) -> void:
	speed_index = clampi(speed_index + step, 0, SPEEDS.size() - 1)
	manager.camera.normal_time_scale = minf(speed(), 1.0) # faster runs more ticks a frame instead
	_update_bar()


func set_hud_hidden(on: bool) -> void:
	hud_hidden = on
	manager.hud.visible = not on
	_bar.visible = not on


func _diverge(mine: int, recorded: int) -> void:
	push_warning("Replay diverged at tick %d (local %08x, recorded %08x)" % [frame, mine, recorded])
	diverged = true
	manager.resimulating = false
	set_hud_hidden(false)
	manager.hud.announce("OUT OF SYNC", "THIS REPLAY NO LONGER MATCHES THE GAME", true)
	manager.hud.show_result()
	_update_bar()


func _unhandled_input(event: InputEvent) -> void:
	if get_tree().paused:
		return
	var handled := true
	if event.is_action_pressed("ui_accept") and not manager.hud.result_panel.visible:
		toggle_pause()
	elif event.is_action_pressed("ui_left", true):
		seek(frame - SEEK_TICKS)
	elif event.is_action_pressed("ui_right", true):
		seek(frame + SEEK_TICKS)
	elif event.is_action_pressed("ui_up"):
		change_speed(1)
	elif event.is_action_pressed("ui_down"):
		change_speed(-1)
	elif _pressed(event, KEY_PERIOD, JOY_BUTTON_RIGHT_SHOULDER):
		if not paused:
			paused = true
		_step_once = true
	elif _pressed(event, KEY_H, JOY_BUTTON_Y):
		set_hud_hidden(not hud_hidden)
	elif _pressed(event, KEY_C, JOY_BUTTON_X):
		manager.camera.cycle_mode()
		_update_bar()
	else:
		handled = false
	if handled:
		get_viewport().set_input_as_handled()


static func _pressed(event: InputEvent, key: Key, button: JoyButton) -> bool:
	if event is InputEventKey:
		return event.pressed and not event.echo and event.physical_keycode == key
	if event is InputEventJoypadButton:
		return event.pressed and event.button_index == button
	return false


# --- Display ---------------------------------------------------------------------

static func time_text(ticks: int) -> String:
	var seconds := ticks / 60
	return "%d:%02d" % [seconds / 60, seconds % 60]


func bar_text() -> String:
	if diverged:
		return "REPLAY OUT OF SYNC"
	var state := "❚❚ PAUSED" if paused else "▶ %s×" % _speed_label()
	var camera: String = ["OFF", "SUBTLE", "FULL"][manager.camera.mode]
	return "REPLAY   %s   %s / %s   ·   SPACE pause  ·  ◀ ▶ seek  ·  ▲ ▼ speed  ·  . step  ·  H hide HUD  ·  C camera: %s  ·  ESC menu" % [
		state, time_text(mini(frame, end_tick())), time_text(end_tick()), camera]


func _speed_label() -> String:
	match speed():
		0.25: return "¼"
		0.5: return "½"
	return str(int(speed()))


func _update_bar() -> void:
	if _bar:
		_bar.text = bar_text()


func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 5
	add_child(_layer)
	_bar = Label.new()
	_bar.add_theme_font_size_override("font_size", 20)
	_bar.add_theme_constant_override("outline_size", 6)
	_bar.add_theme_color_override("font_outline_color", Color.BLACK)
	_bar.add_theme_color_override("font_color", Color(0.85, 0.88, 0.95))
	_bar.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_bar.offset_bottom = -54 # above the SUPER meters
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_bar)

extends Control
## Saved replays (main menu "Replays"): newest first, one row per match with both
## fighters, the players' names, stage, mode, result, length and date. Confirm watches,
## K / pad Y keeps a replay (kept ones are never pruned), Delete / pad X deletes (press
## twice), Esc / B goes back. Replays from another version are listed but can't be
## watched (the simulation would play out differently).

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const WALLPAPER := "res://assets/ui/wallpaper.png"
const GOLD := Color(1.0, 0.82, 0.3)
const DIM := Color(0.55, 0.56, 0.62)
const MODE_NAMES := {vs_cpu = "Vs CPU", versus = "Versus", arcade = "Arcade", online = "Online", spectated = "Watched"}
const DELETE_CONFIRM_MS := 2500

var replays: Array[Replay] = []
var rows: Array[Button] = []
var _list: VBoxContainer
var _hint: Label
var _empty: Label
var _delete_armed := -1
var _delete_time := 0


func _ready() -> void:
	Audio.music(&"menu")
	var background := ColorRect.new()
	background.color = Color(0.03, 0.03, 0.05)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var art := TextureRect.new()
	art.texture = load(WALLPAPER)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	art.modulate = Color(0.22, 0.22, 0.28)
	add_child(art)

	var column := VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.offset_top = 60
	column.offset_bottom = -40
	column.add_theme_constant_override("separation", 16)
	add_child(column)
	column.add_child(_label("REPLAYS", 64, GOLD, HORIZONTAL_ALIGNMENT_CENTER))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	column.add_child(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 10)
	center.add_child(_list)
	_empty = _label("No replays yet.\nEvery finished match (Vs CPU, Versus, Arcade) is saved here.", 30, DIM, HORIZONTAL_ALIGNMENT_CENTER)
	_empty.visible = false
	column.add_child(_empty)
	_hint = _label("", 22, DIM, HORIZONTAL_ALIGNMENT_CENTER)
	column.add_child(_hint)
	refresh()


## Reloads the list from disk.
func refresh(focus_index := 0) -> void:
	replays = Replay.list()
	for row in rows:
		row.queue_free()
	rows.clear()
	for i in replays.size():
		var row := _row(replays[i], i)
		_list.add_child(row)
		rows.append(row)
	_empty.visible = replays.is_empty()
	_delete_armed = -1
	_update_hint()
	if not rows.is_empty():
		rows[clampi(focus_index, 0, rows.size() - 1)].grab_focus.call_deferred()


func _row(replay: Replay, index: int) -> Button:
	var meta := replay.meta
	var row := Button.new()
	row.custom_minimum_size = Vector2(1500, 96)
	row.focus_mode = Control.FOCUS_ALL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.08, 0.8)
	style.set_corner_radius_all(8)
	row.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.1, 0.1, 0.15, 0.9)
	row.add_theme_stylebox_override("hover", hover)
	var focus := style.duplicate() as StyleBoxFlat
	focus.set_border_width_all(3)
	focus.border_color = GOLD
	focus.draw_center = false
	row.add_theme_stylebox_override("focus", focus)
	row.pressed.connect(watch.bind(index))
	row.focus_entered.connect(_update_hint)

	var line := HBoxContainer.new()
	line.set_anchors_preset(Control.PRESET_FULL_RECT)
	line.offset_left = 12
	line.offset_right = -16
	line.add_theme_constant_override("separation", 14)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(line)
	var p1 := _character(str(meta.get("p1", "")))
	var p2 := _character(str(meta.get("p2", "")))
	line.add_child(_portrait(p1))
	line.add_child(_portrait(p2))

	var names := VBoxContainer.new()
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	names.custom_minimum_size.x = 560
	names.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var matchup := "%s  VS  %s" % [p1.display_name.to_upper() if p1 else "?", p2.display_name.to_upper() if p2 else "?"]
	names.add_child(_label(("★  " if replay.kept() else "") + matchup, 32, GOLD if replay.kept() else Color.WHITE))
	names.add_child(_label("%s  ·  %s" % [meta.get("p1_name", ""), meta.get("p2_name", "")], 20, DIM))
	line.add_child(names)

	var problem := replay.problem()
	var details := VBoxContainer.new()
	details.alignment = BoxContainer.ALIGNMENT_CENTER
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details.mouse_filter = Control.MOUSE_FILTER_IGNORE
	details.add_child(_label(result_text(replay), 26, Color.WHITE))
	var stage_name: String = _game_state().stage_name(str(meta.get("stage", ""))) if _game_state() else ""
	details.add_child(_label("%s  ·  %s" % [MODE_NAMES.get(str(meta.get("mode", "")), "Match"), stage_name], 20, DIM))
	line.add_child(details)

	var right := VBoxContainer.new()
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	right.custom_minimum_size.x = 260
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_child(_label(ReplayMatch.time_text(replay.ticks()), 26, Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT))
	right.add_child(_label(problem if problem != "" else date_text(int(meta.get("date", 0))), 20,
		Color(1.0, 0.45, 0.4) if problem != "" else DIM, HORIZONTAL_ALIGNMENT_RIGHT))
	line.add_child(right)
	if problem != "":
		row.modulate = Color(1, 1, 1, 0.6)
	return row


static func result_text(replay: Replay) -> String:
	var meta := replay.meta
	var wins: Array = meta.get("wins", [0, 0])
	var score := "%d–%d" % [int(wins[0]), int(wins[1])] if wins.size() == 2 else ""
	match int(meta.get("result", SpectatorFeed.Result.ABORTED)):
		SpectatorFeed.Result.P1_WON:
			return "%s wins  %s" % [meta.get("p1_name", "P1"), score]
		SpectatorFeed.Result.P2_WON:
			return "%s wins  %s" % [meta.get("p2_name", "P2"), score]
		SpectatorFeed.Result.DRAW:
			return "Draw  %s" % score
	return "Unfinished"


static func date_text(unix: int) -> String:
	var local := unix + int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d := Time.get_datetime_dict_from_unix_time(local)
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return "%s %d, %02d:%02d" % [months[int(d.month) - 1], d.day, d.hour, d.minute]


func focused_index() -> int:
	return rows.find(get_viewport().gui_get_focus_owner())


func watch(index: int) -> void:
	if index < 0 or index >= replays.size():
		return
	if replays[index].problem() != "":
		Audio.sfx(&"ui_back", -4.0)
		return
	_game_state().start_replay(get_tree(), replays[index])


func toggle_keep(index: int) -> void:
	if index < 0 or index >= replays.size():
		return
	replays[index].set_kept(not replays[index].kept())
	refresh(index)


## Deletes on the second press within DELETE_CONFIRM_MS.
func request_delete(index: int) -> void:
	if index < 0 or index >= replays.size():
		return
	var now := Time.get_ticks_msec()
	if _delete_armed == index and now - _delete_time <= DELETE_CONFIRM_MS:
		replays[index].delete()
		Audio.sfx(&"ui_back", -4.0)
		refresh(index)
		return
	_delete_armed = index
	_delete_time = now
	_update_hint()


func _update_hint() -> void:
	if replays.is_empty():
		_hint.text = "Esc / B to return"
		return
	var index := focused_index()
	if _delete_armed >= 0 and _delete_armed == index:
		_hint.text = "Press Delete / X again to delete this replay"
		return
	var keep := "Unkeep" if index >= 0 and replays[index].kept() else "Keep"
	_hint.text = "Enter / A watch  ·  K / Y %s  ·  Delete / X delete  ·  Esc / B return   (the newest %d unkept replays are saved)" % [
		keep, Replay.MAX_UNKEPT]


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		Audio.sfx(&"ui_back", -4.0)
		get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	elif ReplayMatch._pressed(event, KEY_K, JOY_BUTTON_Y):
		get_viewport().set_input_as_handled()
		toggle_keep(focused_index())
	elif ReplayMatch._pressed(event, KEY_DELETE, JOY_BUTTON_X):
		get_viewport().set_input_as_handled()
		request_delete(focused_index())


func _portrait(character: CharacterData) -> TextureRect:
	var portrait := TextureRect.new()
	portrait.texture = character.portrait if character else null
	portrait.custom_minimum_size = Vector2(76, 76)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	portrait.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return portrait


func _label(text: String, size: int, color: Color, align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 6)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.horizontal_alignment = align
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _character(id: String) -> CharacterData:
	var gs := _game_state()
	if gs:
		for c: CharacterData in gs.roster:
			if String(c.id) == id:
				return c
	return null


func _game_state() -> Node:
	return get_tree().root.get_node_or_null("GameState")

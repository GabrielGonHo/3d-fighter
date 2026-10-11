class_name Replay
extends RefCounted
## A saved match: its setup, both players' screen-relative inputs (the words the
## simulation and the spectator feed run on) and a checksum every CHECKSUM_INTERVAL
## ticks. The simulation is deterministic, so playing the inputs back from the start of
## the match reproduces it exactly; the checksums catch a replay that drifts (other game
## data). Files are user://replays/<time>.rpl, Zstandard-compressed:
##   "3DFR", u16 FILE_VERSION, u32 length + JSON meta, u32 ticks, ticks × (u16 P1, u16 P2),
##   u32 count, count × (u32 tick, u32 checksum of the state before that tick)
## Meta: version, content (GameState.content_hash), date (unix), mode, stage (path), p1,
## p2 (character ids), p1_name, p2_name, boss (P2 starts every round with a full
## meter: the Arcade boss), result (SpectatorFeed.Result), wins [P1, P2], ticks, kept.

const MAGIC := "3DFR"
const FILE_VERSION := 1
const EXTENSION := "rpl"
const CHECKSUM_INTERVAL := 60
## Replays not marked to keep: the oldest beyond this many are deleted.
const MAX_UNKEPT := 30
const MAX_TICKS := 5 * 60 * 60 * 10 # far beyond any match (five rounds of 99 s plus pauses)
const MAX_META_BYTES := 4096

## Where replays live. Tests point it elsewhere.
static var directory := "user://replays/"

var meta := {}
var p1 := PackedInt32Array()
var p2 := PackedInt32Array()
var checksums := {} # tick -> checksum
var path := ""


func ticks() -> int:
	return p1.size()


## Why this replay can't be watched on this build ("" = it can).
func problem() -> String:
	var version := str(meta.get("version", ""))
	if version != _game_version() or int(meta.get("content", 0)) != _content_hash():
		return "Made with version %s" % version if version != _game_version() else "Made with different game data"
	if _character(str(meta.get("p1", ""))) == null or _character(str(meta.get("p2", ""))) == null:
		return "Unknown fighter"
	if not ResourceLoader.exists(str(meta.get("stage", ""))):
		return "Unknown stage"
	return ""


func kept() -> bool:
	return bool(meta.get("kept", false))


## Marks the replay to keep (never pruned) or not, and rewrites its file.
func set_kept(on: bool) -> bool:
	meta.kept = on
	return save(path)


## Writes the replay (to `file`, or a new name from its date in `directory`). Returns false
## if the file couldn't be written.
func save(file := "") -> bool:
	if file == "":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		var stamp := Time.get_datetime_string_from_unix_time(int(meta.get("date", 0))).replace(":", "").replace("T", "_")
		file = directory.path_join("%s.%s" % [stamp, EXTENSION])
		var n := 2
		while FileAccess.file_exists(file):
			file = directory.path_join("%s_%d.%s" % [stamp, n, EXTENSION])
			n += 1
	var out := StreamPeerBuffer.new()
	out.put_data(MAGIC.to_ascii_buffer())
	out.put_u16(FILE_VERSION)
	var json := JSON.stringify(meta).to_utf8_buffer()
	out.put_u32(json.size())
	out.put_data(json)
	out.put_u32(p1.size())
	for i in p1.size():
		out.put_u16(p1[i])
		out.put_u16(p2[i])
	var ticks_sorted := checksums.keys()
	ticks_sorted.sort()
	out.put_u32(ticks_sorted.size())
	for tick: int in ticks_sorted:
		out.put_u32(tick)
		out.put_u32(int(checksums[tick]) & 0xFFFFFFFF)
	var f := FileAccess.open_compressed(file, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return false
	f.store_buffer(out.data_array)
	f.close()
	path = file
	return true


## Reads a replay file, or null if it's missing, damaged or not a replay.
static func load_file(file: String) -> Replay:
	var f := FileAccess.open_compressed(file, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var replay := from_bytes(bytes)
	if replay:
		replay.path = file
	return replay


static func from_bytes(bytes: PackedByteArray) -> Replay:
	if bytes.size() < 14 or bytes.slice(0, 4).get_string_from_ascii() != MAGIC:
		return null
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	buffer.seek(4)
	if buffer.get_u16() != FILE_VERSION:
		return null
	var meta_size := buffer.get_u32()
	if meta_size > MAX_META_BYTES or buffer.get_available_bytes() < meta_size + 4:
		return null
	var parsed: Variant = JSON.parse_string((buffer.get_data(meta_size)[1] as PackedByteArray).get_string_from_utf8())
	if not parsed is Dictionary:
		return null
	var replay := Replay.new()
	replay.meta = parsed
	var count := buffer.get_u32()
	if count > MAX_TICKS or buffer.get_available_bytes() < count * 4 + 4:
		return null
	replay.p1.resize(count)
	replay.p2.resize(count)
	for i in count:
		replay.p1[i] = buffer.get_u16()
		replay.p2[i] = buffer.get_u16()
		if not SpectatorFeed.valid_input(replay.p1[i]) or not SpectatorFeed.valid_input(replay.p2[i]):
			return null
	var sums := buffer.get_u32()
	if buffer.get_available_bytes() != sums * 8:
		return null
	for i in sums:
		var tick := buffer.get_u32()
		replay.checksums[tick] = buffer.get_u32()
	return replay


## Every replay in `directory`, newest first (damaged files are skipped).
static func list() -> Array[Replay]:
	var out: Array[Replay] = []
	var dir := DirAccess.open(directory)
	if dir == null:
		return out
	for file in dir.get_files():
		if file.get_extension() == EXTENSION:
			var replay := load_file(directory.path_join(file))
			if replay:
				out.append(replay)
	out.sort_custom(func(a: Replay, b: Replay) -> bool:
		var da := int(a.meta.get("date", 0))
		var db := int(b.meta.get("date", 0))
		return da > db if da != db else a.path > b.path)
	return out


## Deletes the oldest replays not marked to keep, leaving MAX_UNKEPT.
static func prune() -> void:
	var unkept := list().filter(func(r: Replay) -> bool: return not r.kept())
	for i in range(MAX_UNKEPT, unkept.size()):
		DirAccess.remove_absolute(ProjectSettings.globalize_path((unkept[i] as Replay).path))


func delete() -> void:
	if path != "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## The meta for a match that's starting: the fighters, stage and names; the result and
## length are filled in when it ends (finish).
static func new_meta(mode: String, stage: String, p1_data: CharacterData, p2_data: CharacterData,
		p1_name: String, p2_name: String, boss := false) -> Dictionary:
	return {version = _game_version(), content = _content_hash(), date = int(Time.get_unix_time_from_system()),
		mode = mode, stage = stage, p1 = String(p1_data.id), p2 = String(p2_data.id),
		p1_name = p1_name, p2_name = p2_name, boss = boss, result = SpectatorFeed.Result.ABORTED,
		wins = [0, 0], ticks = 0, kept = false}


func finish(result: int, p1_wins: int, p2_wins: int) -> void:
	meta.result = result
	meta.wins = [p1_wins, p2_wins]
	meta.ticks = ticks()


## A finished spectator log (a watched internet match, or one's own online match).
static func from_log(log: SpectatorFeed.Log, mode: String, stage: String) -> Replay:
	var replay := Replay.new()
	var start := log.start
	var p1_data := _character(str(start.get("p1_id", "")))
	var p2_data := _character(str(start.get("p2_id", "")))
	if p1_data == null or p2_data == null:
		return null
	replay.meta = new_meta(mode, stage, p1_data, p2_data, str(start.get("p1_name", "P1")), str(start.get("p2_name", "P2")))
	var final := int(log.end.get("final_tick", log.ticks())) if not log.end.is_empty() else log.ticks()
	final = mini(final, log.ticks())
	replay.p1 = log.p1.slice(0, final)
	replay.p2 = log.p2.slice(0, final)
	for tick: int in log.checksums:
		if tick <= final:
			replay.checksums[tick] = log.checksums[tick]
	replay.finish(int(log.end.get("result", SpectatorFeed.Result.ABORTED)), int(log.end.get("p1_wins", 0)), int(log.end.get("p2_wins", 0)))
	return replay


# GameState is looked up at run time: tools and tests compile class_name scripts before
# the autoloads exist.
static func _game_state() -> Node:
	return (Engine.get_main_loop() as SceneTree).root.get_node_or_null("GameState")


static func _game_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0"))


static var _content_cache := -1


static func _content_hash() -> int:
	if _content_cache < 0:
		var gs := _game_state()
		_content_cache = gs.content_hash() if gs else 0
	return _content_cache


static func _character(id: String) -> CharacterData:
	var gs := _game_state()
	if gs == null:
		return null
	for c: CharacterData in gs.roster:
		if String(c.id) == id:
			return c
	return null

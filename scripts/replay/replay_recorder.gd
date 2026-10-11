class_name ReplayRecorder
extends Node
## Records an offline match (Vs CPU, Versus, Arcade) as a Replay: each tick, both
## fighters' screen-relative inputs (Fighter.last_screen_input), plus a checksum of the
## state every Replay.CHECKSUM_INTERVAL ticks. FightManager calls begin() whenever a
## match starts (a restart or rematch starts a new recording); the replay is saved when
## the match is decided, then the oldest unkept replays are pruned.

## Off for tools that play many matches (balance sim, determinism check).
static var enabled := true

var manager: Node # FightManager
var replay: Replay
## The last saved replay (tests, the result screen).
var saved: Replay
var _mode := ""
var _boss := false
var _done := false


func setup(fight_manager: Node, mode: String, boss: bool) -> void:
	manager = fight_manager
	name = "ReplayRecorder"
	_mode = mode
	_boss = boss
	manager.ticked.connect(_on_ticked)


## A match is starting: a fresh recording from the state right now.
func begin() -> void:
	var f: Array = manager.fighters
	replay = Replay.new()
	replay.meta = Replay.new_meta(_mode, manager.stage.scene_file_path, f[0].data, f[1].data,
		_name(0), _name(1), _boss)
	replay.checksums[0] = manager.checksum(manager.save_state())
	_done = false


func _name(index: int) -> String:
	var text: String = (manager.hud.p1_name if index == 0 else manager.hud.p2_name).text
	return text


func _on_ticked() -> void:
	if replay == null or _done or manager.resimulating:
		return
	replay.p1.append(manager.fighters[0].last_screen_input)
	replay.p2.append(manager.fighters[1].last_screen_input)
	var tick := replay.ticks()
	if tick % Replay.CHECKSUM_INTERVAL == 0:
		replay.checksums[tick] = manager.checksum(manager.save_state())
	if manager.phase == manager.Phase.MATCH_OVER:
		_done = true
		var wins: Array[int] = manager.round_wins
		var result := SpectatorFeed.Result.DRAW
		if wins[0] != wins[1]:
			result = SpectatorFeed.Result.P1_WON if wins[0] > wins[1] else SpectatorFeed.Result.P2_WON
		replay.finish(result, wins[0], wins[1])
		if replay.save():
			saved = replay
			Replay.prune()
		else:
			push_warning("Couldn't save the replay to %s" % Replay.directory)

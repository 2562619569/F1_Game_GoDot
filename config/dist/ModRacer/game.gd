# warnings-disable
extends RefCounted

@warning_ignore("unused_variable")
var True = true
@warning_ignore("unused_variable")
var False = false
@warning_ignore("unused_variable")
var None = null


var data = \
{
1:{ "id":1,  "key":'player_max',  "value":8.0,  "note":'Max players (incl. AI)', },
2:{ "id":2,  "key":'intermission_sec',  "value":40.0,  "note":'Intermission duration (sec)', },
3:{ "id":3,  "key":'round_count',  "value":4.0,  "note":'Sub-round count', },
4:{ "id":4,  "key":'start_countdown',  "value":3.0,  "note":'Start countdown (sec)', },
5:{ "id":5,  "key":'lock_ahead_range',  "value":60.0,  "note":'Rocket lock-on range ahead (m)', },
6:{ "id":6,  "key":'loot_pick_radius',  "value":3.0,  "note":'Loot pickup radius (m)', },

}


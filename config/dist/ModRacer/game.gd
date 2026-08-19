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
7:{ "id":7,  "key":'checkpoint_interval',  "value":100.0,  "note":'Checkpoint spacing along main route (m)', },
8:{ "id":8,  "key":'rewind_speed_limit',  "value":20.0,  "note":'Rewind (R) allowed below this speed (m/s)', },
9:{ "id":9,  "key":'rewind_ghost_sec',  "value":5.0,  "note":'Ghost (translucent, no car collision) after rewind (sec)', },
10:{ "id":10,  "key":'cam_chase_distance',  "value":6.5,  "note":'Chase cam distance (m)', },
11:{ "id":11,  "key":'cam_chase_height',  "value":2.6,  "note":'Chase cam height (m)', },
12:{ "id":12,  "key":'cam_fov_max',  "value":79.0,  "note":'Chase cam max FOV at top speed (deg)', },
13:{ "id":13,  "key":'cam_shake',  "value":1.0,  "note":'Camera shake master switch (0=off)', },
14:{ "id":14,  "key":'bump_strength',  "value":0.7,  "note":'Car-car impact boost multiplier (x closing speed x reduced mass)', },
15:{ "id":15,  "key":'bump_min_speed',  "value":2.0,  "note":'Closing speed below this no boost (m/s)', },
16:{ "id":16,  "key":'bump_max_speed',  "value":25.0,  "note":'Closing speed cap for boost math (m/s)', },
17:{ "id":17,  "key":'bump_yaw',  "value":2.5,  "note":'Yaw spin torque multiplier on corner hits', },
18:{ "id":18,  "key":'bump_destab_speed',  "value":6.0,  "note":'Closing speed to trigger destabilization window (m/s)', },
19:{ "id":19,  "key":'bump_destab_time',  "value":1.0,  "note":'Max destabilization window duration (s, scales with closing speed)', },
20:{ "id":20,  "key":'bump_destab_grip',  "value":0.4,  "note":'Tire friction scale during destabilization window', },

}


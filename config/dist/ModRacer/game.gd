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
21:{ "id":21,  "key":'npc_count',  "value":20.0,  "note":'NPC traffic cars per round (max; rolled within [npc_count_min, this])', },
22:{ "id":22,  "key":'npc_hp',  "value":100.0,  "note":'NPC traffic car hit points', },
23:{ "id":23,  "key":'npc_speed_scale',  "value":0.45,  "note":'NPC cruise speed scale vs AI pace', },
24:{ "id":24,  "key":'npc_damage_coeff',  "value":1.0,  "note":'NPC collision damage scale on speed fraction (100km/h=50% hp, 200km/h=wreck, floor 25% per hit)', },
25:{ "id":25,  "key":'npc_w_common',  "value":70.0,  "note":'NPC type spawn weight: common (701, npc_common loot)', },
26:{ "id":26,  "key":'npc_count_min',  "value":15.0,  "note":'NPC traffic cars per round (min for random density)', },
27:{ "id":27,  "key":'npc_w_rare',  "value":25.0,  "note":'NPC type spawn weight: rare (702, npc_rare loot)', },
28:{ "id":28,  "key":'npc_w_elite',  "value":5.0,  "note":'NPC type spawn weight: elite (703, npc_elite loot)', },
29:{ "id":29,  "key":'drift_speed_min',  "value":8.0,  "note":'Min speed to enter/hold drift mode (m/s)', },
30:{ "id":30,  "key":'drift_brake_scale',  "value":0.35,  "note":'Handbrake force scale while drifting (bite, not full lock)', },
31:{ "id":31,  "key":'drift_rear_grip',  "value":0.62,  "note":'Rear lateral grip scale while drifting (front untouched)', },
32:{ "id":32,  "key":'drift_slip_assist',  "value":0.55,  "note":'Steering slip assist threshold while drifting (rad)', },
33:{ "id":33,  "key":'drift_yaw_engage',  "value":0.22,  "note":'Yaw stability engage angle while drifting (dot domain, ~40deg max drift angle)', },
34:{ "id":34,  "key":'drift_yaw_kick',  "value":0.25,  "note":'Drift-entry yaw kick angular velocity (rad/s, x steering input)', },
35:{ "id":35,  "key":'skid_lat_slip',  "value":0.2,  "note":'Lateral slip angle threshold for tire marks (rad, ~11.5deg)', },
36:{ "id":36,  "key":'skid_lon_slip',  "value":0.2,  "note":'Longitudinal slip threshold for tire marks (lockup/wheelspin)', },
37:{ "id":37,  "key":'skid_lifetime',  "value":25.0,  "note":'Tire mark fade-out duration (sec)', },
38:{ "id":38,  "key":'skid_alpha',  "value":0.75,  "note":'Tire mark peak opacity', },
39:{ "id":39,  "key":'skid_gap',  "value":0.35,  "note":'Min segment length between mark quads (m)', },
40:{ "id":40,  "key":'skid_pool',  "value":4096.0,  "note":'Ring buffer segments per car (oldest overwritten)', },
41:{ "id":41,  "key":'env_clouds_enabled',  "value":1.0,  "note":'Volumetric cloud sky master switch (clayjohn raymarch sky shader)', },
42:{ "id":42,  "key":'env_cloud_coverage',  "value":0.3,  "note":'Base cloud coverage 0.1-1 (per-weather preset multiplies on top)', },
43:{ "id":43,  "key":'env_cloud_density',  "value":0.055,  "note":'Base cloud density (absorption)', },
44:{ "id":44,  "key":'env_cloud_wind',  "value":2.5,  "note":'Cloud wind speed', },

}


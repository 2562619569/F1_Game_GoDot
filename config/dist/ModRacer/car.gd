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
601:{ "id":601,  "name":'Brute Power',  "drive":'RWD',  "top_speed":320,  "accel":7.5,  "handling":5.5,  "weight":1500,  "perf_slots":4,  "func_slots":1,  "desc":'Straight-line monster with great impact resistance; slippery at low speed, tricky on wet/snow/mud.',  "grip_road":6,  "grip_offroad":3,  "max_torque":420.0,  "max_rpm":7500.0,  "final_drive":3.4,  "gear_ratios":[3.6, 2.2, 1.6, 1.25, 1.0, 0.8],  "front_torque_split":0.0,  "max_steering_angle":36.0,  "steering_speed":3.5,  "brake_force_multiplier":1.0,  "coefficient_of_drag":0.32,  "frontal_area":2.1,  "front_weight_distribution":0.48,  "center_of_gravity_height_offset":-0.15,  "inertia_multiplier":1.3,  "wheel":'sport_v1', },
602:{ "id":602,  "name":'Agile Sprinter',  "drive":'FWD',  "top_speed":260,  "accel":7.0,  "handling":9.0,  "weight":1100,  "perf_slots":4,  "func_slots":1,  "desc":'Rock solid on twisty tracks with high forgiveness; low top speed, weak on straights.',  "grip_road":8,  "grip_offroad":5,  "max_torque":260.0,  "max_rpm":6800.0,  "final_drive":3.6,  "gear_ratios":[3.8, 2.4, 1.7, 1.3, 1.0],  "front_torque_split":1.0,  "max_steering_angle":44.0,  "steering_speed":5.5,  "brake_force_multiplier":1.1,  "coefficient_of_drag":0.34,  "frontal_area":1.9,  "front_weight_distribution":0.62,  "center_of_gravity_height_offset":-0.25,  "inertia_multiplier":1.0,  "wheel":'sport_v1', },
603:{ "id":603,  "name":'All-Rounder',  "drive":'AWD',  "top_speed":290,  "accel":8.0,  "handling":7.5,  "weight":1300,  "perf_slots":3,  "func_slots":2,  "desc":'Strong launch grip and all-terrain adaptability; no extreme strengths.',  "grip_road":7,  "grip_offroad":8,  "max_torque":330.0,  "max_rpm":7000.0,  "final_drive":3.5,  "gear_ratios":[3.7, 2.3, 1.65, 1.28, 1.0, 0.82],  "front_torque_split":0.5,  "max_steering_angle":40.0,  "steering_speed":4.5,  "brake_force_multiplier":1.05,  "coefficient_of_drag":0.33,  "frontal_area":2.0,  "front_weight_distribution":0.52,  "center_of_gravity_height_offset":-0.2,  "inertia_multiplier":1.15,  "wheel":'sport_v1', },
701:{ "id":701,  "name":'NPC Van (Traffic)',  "drive":'RWD',  "top_speed":320,  "accel":7.5,  "handling":5.5,  "weight":1500,  "perf_slots":4,  "func_slots":1,  "desc":'NPC traffic target car; same physics params as player car 601, separate art id slot.',  "grip_road":6,  "grip_offroad":3,  "max_torque":420.0,  "max_rpm":7500.0,  "final_drive":3.4,  "gear_ratios":[3.6, 2.2, 1.6, 1.25, 1.0, 0.8],  "front_torque_split":0.0,  "max_steering_angle":36.0,  "steering_speed":3.5,  "brake_force_multiplier":1.0,  "coefficient_of_drag":0.32,  "frontal_area":2.1,  "front_weight_distribution":0.48,  "center_of_gravity_height_offset":-0.15,  "inertia_multiplier":1.3,  "wheel":'sport_v1', },
702:{ "id":702,  "name":'NPC Compact (Traffic)',  "drive":'FWD',  "top_speed":260,  "accel":7.0,  "handling":9.0,  "weight":1100,  "perf_slots":4,  "func_slots":1,  "desc":'NPC traffic target car; same physics params as player car 602, separate art id slot.',  "grip_road":8,  "grip_offroad":5,  "max_torque":260.0,  "max_rpm":6800.0,  "final_drive":3.6,  "gear_ratios":[3.8, 2.4, 1.7, 1.3, 1.0],  "front_torque_split":1.0,  "max_steering_angle":44.0,  "steering_speed":5.5,  "brake_force_multiplier":1.1,  "coefficient_of_drag":0.34,  "frontal_area":1.9,  "front_weight_distribution":0.62,  "center_of_gravity_height_offset":-0.25,  "inertia_multiplier":1.0,  "wheel":'sport_v1', },
703:{ "id":703,  "name":'NPC Pickup (Traffic)',  "drive":'AWD',  "top_speed":290,  "accel":8.0,  "handling":7.5,  "weight":1300,  "perf_slots":3,  "func_slots":2,  "desc":'NPC traffic target car; same physics params as player car 603, separate art id slot.',  "grip_road":7,  "grip_offroad":8,  "max_torque":330.0,  "max_rpm":7000.0,  "final_drive":3.5,  "gear_ratios":[3.7, 2.3, 1.65, 1.28, 1.0, 0.82],  "front_torque_split":0.5,  "max_steering_angle":40.0,  "steering_speed":4.5,  "brake_force_multiplier":1.05,  "coefficient_of_drag":0.33,  "frontal_area":2.0,  "front_weight_distribution":0.52,  "center_of_gravity_height_offset":-0.2,  "inertia_multiplier":1.15,  "wheel":'sport_v1', },

}


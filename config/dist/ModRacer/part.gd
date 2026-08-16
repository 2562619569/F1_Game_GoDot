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
101:{ "id":101,  "name":'NA Boost Engine',  "category":'engine',  "rarity":1,  "top_speed":3.0,  "accel":3.0,  "grip_road":0.0,  "grip_offroad":0.0,  "grip_wet":0.0,  "aero":0.0,  "landing":0.0,  "mass":0,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'Balanced mild power gain.',  "effect":'none',  "power":0.0,  "model":'', },
102:{ "id":102,  "name":'Supercharged Engine',  "category":'engine',  "rarity":2,  "top_speed":6.0,  "accel":5.0,  "grip_road":0.0,  "grip_offroad":0.0,  "grip_wet":0.0,  "aero":0.0,  "landing":0.0,  "mass":10,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'Fierce mid-range pull, slightly heavier.',  "effect":'none',  "power":0.0,  "model":'', },
103:{ "id":103,  "name":'Big Turbo Engine',  "category":'engine',  "rarity":3,  "top_speed":10.0,  "accel":7.0,  "grip_road":0.0,  "grip_offroad":-2.0,  "grip_wet":0.0,  "aero":0.0,  "landing":0.0,  "mass":20,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'Top-speed oriented, low-end lag.',  "effect":'none',  "power":0.0,  "model":'', },
201:{ "id":201,  "name":'Sport Slicks',  "category":'tires',  "rarity":2,  "top_speed":0.0,  "accel":2.0,  "grip_road":8.0,  "grip_offroad":-4.0,  "grip_wet":-2.0,  "aero":0.0,  "landing":0.0,  "mass":0,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'Huge asphalt grip, weak offroad/wet.',  "effect":'none',  "power":0.0,  "model":'slick_v1', },
202:{ "id":202,  "name":'Rally Offroad Tires',  "category":'tires',  "rarity":2,  "top_speed":-1.0,  "accel":0.0,  "grip_road":-2.0,  "grip_offroad":12.0,  "grip_wet":2.0,  "aero":0.0,  "landing":0.0,  "mass":0,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'Great on gravel/mud, slightly lower top speed.',  "effect":'none',  "power":0.0,  "model":'offroad_v1', },
203:{ "id":203,  "name":'Deep-Tread Rain Tires',  "category":'tires',  "rarity":2,  "top_speed":-1.0,  "accel":0.0,  "grip_road":-1.0,  "grip_offroad":2.0,  "grip_wet":12.0,  "aero":0.0,  "landing":0.0,  "mass":0,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'Anti-slip on wet roads.',  "effect":'none',  "power":0.0,  "model":'rain_v1', },
204:{ "id":204,  "name":'All-Terrain Tires',  "category":'tires',  "rarity":3,  "top_speed":0.0,  "accel":1.0,  "grip_road":4.0,  "grip_offroad":6.0,  "grip_wet":6.0,  "aero":0.0,  "landing":0.0,  "mass":0,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'No weak spot all-rounder.',  "effect":'none',  "power":0.0,  "model":'allterrain_v1', },
301:{ "id":301,  "name":'Low-Drag Wing',  "category":'aero',  "rarity":1,  "top_speed":4.0,  "accel":0.0,  "grip_road":0.0,  "grip_offroad":0.0,  "grip_wet":0.0,  "aero":-3.0,  "landing":0.0,  "mass":0,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'Less drag, higher sprint speed.',  "effect":'none',  "power":0.0,  "model":'', },
302:{ "id":302,  "name":'High-Downforce Wing',  "category":'aero',  "rarity":2,  "top_speed":-2.0,  "accel":1.0,  "grip_road":3.0,  "grip_offroad":1.0,  "grip_wet":1.0,  "aero":8.0,  "landing":0.0,  "mass":0,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'Much more stable in high-speed corners.',  "effect":'none',  "power":0.0,  "model":'', },
401:{ "id":401,  "name":'Reinforced Suspension',  "category":'chassis',  "rarity":2,  "top_speed":0.0,  "accel":0.0,  "grip_road":1.0,  "grip_offroad":3.0,  "grip_wet":0.0,  "aero":0.0,  "landing":10.0,  "mass":15,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'Stable landings, impact resistant.',  "effect":'none',  "power":0.0,  "model":'', },
402:{ "id":402,  "name":'Lightweight Chassis',  "category":'chassis',  "rarity":3,  "top_speed":2.0,  "accel":3.0,  "grip_road":0.0,  "grip_offroad":0.0,  "grip_wet":0.0,  "aero":0.0,  "landing":3.0,  "mass":-80,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'Less weight, quicker, weaker to impacts.',  "effect":'none',  "power":0.0,  "model":'', },
501:{ "id":501,  "name":'Rocket Launcher',  "category":'tactical',  "rarity":2,  "top_speed":0.0,  "accel":0.0,  "grip_road":0.0,  "grip_offroad":0.0,  "grip_wet":0.0,  "aero":0.0,  "landing":0.0,  "mass":0,  "cooldown":20.0,  "ammo":2,  "duration":0.0,  "desc":'Locks nearest car ahead, slows and spins it.',  "effect":'slow_spin',  "power":30.0,  "model":'', },
502:{ "id":502,  "name":'Tactical Stealth',  "category":'tactical',  "rarity":3,  "top_speed":0.0,  "accel":0.0,  "grip_road":0.0,  "grip_offroad":0.0,  "grip_wet":0.0,  "aero":0.0,  "landing":0.0,  "mass":0,  "cooldown":30.0,  "ammo":1,  "duration":5.0,  "desc":'Semi-transparent, untargetable, immune to tracking.',  "effect":'stealth',  "power":0.5,  "model":'', },
503:{ "id":503,  "name":'Super Nitrous',  "category":'tactical',  "rarity":2,  "top_speed":0.0,  "accel":0.0,  "grip_road":0.0,  "grip_offroad":0.0,  "grip_wet":0.0,  "aero":0.0,  "landing":0.0,  "mass":0,  "cooldown":15.0,  "ammo":3,  "duration":3.0,  "desc":'Instant strong thrust burst.',  "effect":'nitro_push',  "power":2.0,  "model":'', },

}


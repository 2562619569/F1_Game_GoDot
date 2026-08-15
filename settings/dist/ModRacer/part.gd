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
101:{ "id":101,  "name":'自然吸气强化引擎',  "category":'engine',  "rarity":1,  "top_speed":3.0,  "accel":3.0,  "grip_road":0.0,  "grip_offroad":0.0,  "grip_wet":0.0,  "aero":0.0,  "landing":0.0,  "mass":0,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'均衡小幅提升动力。', },
102:{ "id":102,  "name":'机械增压引擎',  "category":'engine',  "rarity":2,  "top_speed":6.0,  "accel":5.0,  "grip_road":0.0,  "grip_offroad":0.0,  "grip_wet":0.0,  "aero":0.0,  "landing":0.0,  "mass":10,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'中段加速凶悍，略增重量。', },
103:{ "id":103,  "name":'大马力涡轮引擎',  "category":'engine',  "rarity":3,  "top_speed":10.0,  "accel":7.0,  "grip_road":0.0,  "grip_offroad":-2.0,  "grip_wet":0.0,  "aero":0.0,  "landing":0.0,  "mass":20,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'极限极速取向，低速扭矩迟滞。', },
201:{ "id":201,  "name":'运动热熔胎',  "category":'tires',  "rarity":2,  "top_speed":0.0,  "accel":2.0,  "grip_road":8.0,  "grip_offroad":-4.0,  "grip_wet":-2.0,  "aero":0.0,  "landing":0.0,  "mass":0,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'铺装路抓地极强，越野雨雪衰减。', },
202:{ "id":202,  "name":'拉力越野胎',  "category":'tires',  "rarity":2,  "top_speed":-1.0,  "accel":0.0,  "grip_road":-2.0,  "grip_offroad":12.0,  "grip_wet":2.0,  "aero":0.0,  "landing":0.0,  "mass":0,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'砂石泥地表现优异，极速略降。', },
203:{ "id":203,  "name":'深纹雨胎',  "category":'tires',  "rarity":2,  "top_speed":-1.0,  "accel":0.0,  "grip_road":-1.0,  "grip_offroad":2.0,  "grip_wet":12.0,  "aero":0.0,  "landing":0.0,  "mass":0,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'暴雨湿滑路面防滑利器。', },
204:{ "id":204,  "name":'全地形复合胎',  "category":'tires',  "rarity":3,  "top_speed":0.0,  "accel":1.0,  "grip_road":4.0,  "grip_offroad":6.0,  "grip_wet":6.0,  "aero":0.0,  "landing":0.0,  "mass":0,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'无明显短板的全能胎。', },
301:{ "id":301,  "name":'低阻尾翼',  "category":'aero',  "rarity":1,  "top_speed":4.0,  "accel":0.0,  "grip_road":0.0,  "grip_offroad":0.0,  "grip_wet":0.0,  "aero":-3.0,  "landing":0.0,  "mass":0,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'直线减阻，冲刺极速提升。', },
302:{ "id":302,  "name":'大下压力尾翼',  "category":'aero',  "rarity":2,  "top_speed":-2.0,  "accel":1.0,  "grip_road":3.0,  "grip_offroad":1.0,  "grip_wet":1.0,  "aero":8.0,  "landing":0.0,  "mass":0,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'高速过弯稳定性大幅提升。', },
401:{ "id":401,  "name":'强化悬挂',  "category":'chassis',  "rarity":2,  "top_speed":0.0,  "accel":0.0,  "grip_road":1.0,  "grip_offroad":3.0,  "grip_wet":0.0,  "aero":0.0,  "landing":10.0,  "mass":15,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'飞跳落地稳定，抗撞击。', },
402:{ "id":402,  "name":'轻量化底盘',  "category":'chassis',  "rarity":3,  "top_speed":2.0,  "accel":3.0,  "grip_road":0.0,  "grip_offroad":0.0,  "grip_wet":0.0,  "aero":0.0,  "landing":3.0,  "mass":-80,  "cooldown":0.0,  "ammo":0,  "duration":0.0,  "desc":'减重提速能，抗撞变弱。', },
501:{ "id":501,  "name":'火箭筒',  "category":'tactical',  "rarity":2,  "top_speed":0.0,  "accel":0.0,  "grip_road":0.0,  "grip_offroad":0.0,  "grip_wet":0.0,  "aero":0.0,  "landing":0.0,  "mass":0,  "cooldown":20.0,  "ammo":2,  "duration":0.0,  "desc":'锁定前方最近车辆发射，造成减速打转。', },
502:{ "id":502,  "name":'战术隐身',  "category":'tactical',  "rarity":3,  "top_speed":0.0,  "accel":0.0,  "grip_road":0.0,  "grip_offroad":0.0,  "grip_wet":0.0,  "aero":0.0,  "landing":0.0,  "mass":0,  "cooldown":30.0,  "ammo":1,  "duration":5.0,  "desc":'半透明且无法被锁定，免疫追踪攻击。', },
503:{ "id":503,  "name":'超级氮气',  "category":'tactical',  "rarity":2,  "top_speed":0.0,  "accel":0.0,  "grip_road":0.0,  "grip_offroad":0.0,  "grip_wet":0.0,  "aero":0.0,  "landing":0.0,  "mass":0,  "cooldown":15.0,  "ammo":3,  "duration":3.0,  "desc":'瞬间喷射提供极强推力。', },

}


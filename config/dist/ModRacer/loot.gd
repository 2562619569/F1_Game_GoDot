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
1:{ "id":1,  "route":'main',  "drop_count":6,  "rarity_weights":'60|30|10|0',  "category_pool":'engine|tires|aero|chassis|tactical',  "guarantee_rarity":0, },
2:{ "id":2,  "route":'hazard',  "drop_count":3,  "rarity_weights":'0|20|50|30',  "category_pool":'engine|tires|aero|chassis|tactical',  "guarantee_rarity":2, },
3:{ "id":3,  "route":'npc_common',  "drop_count":1,  "rarity_weights":'75|25|0|0',  "category_pool":'engine|tires|aero|chassis|tactical',  "guarantee_rarity":0, },
4:{ "id":4,  "route":'npc_rare',  "drop_count":1,  "rarity_weights":'20|50|30|0',  "category_pool":'engine|tires|aero|chassis|tactical',  "guarantee_rarity":1, },
5:{ "id":5,  "route":'npc_elite',  "drop_count":1,  "rarity_weights":'0|15|45|40',  "category_pool":'engine|tires|aero|chassis|tactical',  "guarantee_rarity":2, },

}


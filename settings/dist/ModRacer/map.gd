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
1:{ "id":1,  "name":'环湖高速公路',  "terrain":'asphalt',  "weather":'sunny',  "straight_ratio":70,  "corner_count":4,  "jump_count":0,  "hazard_branch":False,  "desc":'长直道为主，极速车的天堂。', },
2:{ "id":2,  "name":'砂石荒漠峡谷',  "terrain":'gravel',  "weather":'sandstorm',  "straight_ratio":40,  "corner_count":8,  "jump_count":6,  "hazard_branch":True,  "desc":'陡坡跳台+泥地打滑，越野胎与强化悬挂主场。', },
3:{ "id":3,  "name":'雨雾山道',  "terrain":'asphalt',  "weather":'storm',  "straight_ratio":30,  "corner_count":14,  "jump_count":2,  "hazard_branch":True,  "desc":'暴雨湿滑连续弯，雨胎+大下压尾翼克制。', },
4:{ "id":4,  "name":'冰雪极地走廊',  "terrain":'snow',  "weather":'snow',  "straight_ratio":50,  "corner_count":9,  "jump_count":4,  "hazard_branch":True,  "desc":'低温积雪路面，抓地与防滑是生死线。', },

}


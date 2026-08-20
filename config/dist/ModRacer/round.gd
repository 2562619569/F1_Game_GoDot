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
1:{ "id":1,  "name":'Round 1',  "is_final":False,  "time_limit":240,  "map_pool":'1|2',  "points":[3, 2, 1, 0, 0, 0, 0, 0], },
2:{ "id":2,  "name":'Round 2',  "is_final":False,  "time_limit":270,  "map_pool":'2|3',  "points":[3, 2, 1, 0, 0, 0, 0, 0], },
3:{ "id":3,  "name":'Round 3',  "is_final":False,  "time_limit":270,  "map_pool":'3|4',  "points":[3, 2, 1, 0, 0, 0, 0, 0], },
4:{ "id":4,  "name":'Final Showdown',  "is_final":True,  "time_limit":300,  "map_pool":'1|2|3|4',  "points":[12, 8, 4, 0, 0, 0, 0, 0], },

}


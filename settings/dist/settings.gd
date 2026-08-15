# warnings-disable
extends Node
# 这个脚本你需要挂到游戏的Autoload才能全局读表

var car = load('res://settings/dist/ModRacer/car.gd').new()
var map = load('res://settings/dist/ModRacer/map.gd').new()
var part = load('res://settings/dist/ModRacer/part.gd').new()

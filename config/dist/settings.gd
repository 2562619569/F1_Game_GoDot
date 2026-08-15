# warnings-disable
extends Node
# 这个脚本你需要挂到游戏的Autoload才能全局读表

var car = load('res://config/dist/ModRacer/car.gd').new()
var game = load('res://config/dist/ModRacer/game.gd').new()
var loot = load('res://config/dist/ModRacer/loot.gd').new()
var map = load('res://config/dist/ModRacer/map.gd').new()
var part = load('res://config/dist/ModRacer/part.gd').new()
var rank_reward = load('res://config/dist/ModRacer/rank_reward.gd').new()
var round = load('res://config/dist/ModRacer/round.gd').new()

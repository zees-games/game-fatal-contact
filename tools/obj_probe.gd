extends Node

## Object growth probe: `--objlog 1` on perf_bench prints the engine's object, node, resource and orphan counts every `period` seconds
## (OBJLOG lines), independent of the profiler (`--profiler off` has no growth block). Non-node, non-resource objects are the remainder.

var period := 10.0
var _t := 0.0
var _t0 := 0.0


func _process(delta: float) -> void:
	_t += delta
	_t0 += delta
	if _t < period:
		return
	_t = 0.0
	var objs := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var res := int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
	print("OBJLOG t=%d objects=%d nodes=%d resources=%d orphans=%d other=%d" % [
		int(_t0), objs, nodes, res, int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)), objs - nodes - res])

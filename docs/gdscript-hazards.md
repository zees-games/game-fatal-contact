The GDScript performance hazards the gd-perf gate flags on Fatal Contact's server tick and client frame, and the fix for each. The gate is gs-ci's `scripts/check-gd-perf.py`, run by `python3 tools/gd_perf_lint.py` and by `./game.sh test`; read this before writing GDScript in a hot file.

## What is hot

| Item | Where |
| --- | --- |
| Hot files | `ci/efficiency/gd-perf-hot.txt`, one glob per line (server tick first, then the client frame) |
| Cold functions | `cold+:` lines in the hot list, plus gs-ci's default (`_ready`, `setup*`, `build*`, `_on_*`, `load*`, `reset*`, ...): typing is still checked there, per-tick kinds are not |
| Ratchet | `ci/efficiency/gd-perf.tsv`, key `path::func::kind`, count = sites. It only shrinks |
| Linked addons | `addons: linked` lints every linked addon against its own hot list and baseline |

## The hazards

| Kind | Flags | Why it costs | Fix |
| --- | --- | --- | --- |
| `untyped_var` | `var x = ...`, `var x` | Variant ops, no typed opcodes | `var x: T = ...` or `var x := ...` |
| `untyped_param` | `func f(a)` | every use of `a` is a Variant op | `func f(a: T)` |
| `no_return_type` | `func f():` | the caller gets a Variant | `-> T` (`-> void`) |
| `untyped_array` | `Array` / `Dictionary` with no element type | Variant element reads, no type check | `Array[T]`, `Dictionary[K, V]`, `PackedVector3Array`, `PackedInt32Array` |
| `alloc` | `[..]` / `{..}` literals, `Array()`, `.duplicate()`, `Physics*QueryParameters3D.new()` in a per-tick func | a heap allocation per call, churn every tick | a member buffer reused with `.clear()` / `.resize()`; one query object per owner; a `const` for a fixed list |
| `node_lookup` | `$Path`, `get_node*`, `find_child*`, `get_nodes_in_group` | a tree walk and a string hash per call | `@onready var` or a member set once in `setup` |
| `singleton_lookup` | `Engine.get_singleton`, `get_world_3d()`, `.direct_space_state`, `get_tree()`, `ProjectSettings.get_setting` | a lookup by name each call | look it up once (setup, or once a tick outside the loop) and hold it in a typed member |
| `string_build` | `print*`, `str()`, `%`, `.format()`, `+ "..."` | a String allocation per call, even when nobody reads it | build only under a debug/verbose/log flag (`if _verbose:` is recognised); a `StringName` const for ids; cache a label's text and set it only when the value changes |
| `dynamic_call` | `call`, `callv`, `has_method`, `get/set("name")`, `Callable()`, `.bind()`, `emit_signal` | a method or property lookup by name per call | type the receiver (`as FcPlayer`) and call directly; probe `has_method` once and cache the answer. A `.get()` on a name declared `Dictionary` in the file is a hash read and is not counted |
| `emit_in_loop` | a signal `.emit(` inside `for` / `while` | each emit walks the connection list | collect into a buffer and emit once after the loop |
| `empty_process` | `_process` / `_physics_process` whose body is `pass` | the engine still calls it every frame | delete it, or `set_process(false)` |

The scan is text-only: it does not know types, so it is a guard for new code, not a proof.

## Allow lines

A real exception is a trailing comment on the flagged line, naming the kind and the reason:

```gdscript
_occlusion_query = PhysicsRayQueryParameters3D.new()  # perf-lint: allow alloc once a body
```

`allow all <reason>` covers every kind on that line. Prefer a real fix; an allow line needs a reason a reviewer can check (once a tick, once a process, only while a profile is on, a shared signature).

## godot-rust: typed arrays into a `VarArray` param

A typed `Array[T]` passed to a Rust `#[func]` whose parameter is `VarArray` (an untyped `Array`) fails at the call with error 1337: the typed array does not convert. Keep the GDScript side untyped and say so on the line:

```gdscript
var rows: Array = []  # perf-lint: allow untyped_array passed to a Rust #[func] VarArray param (typed fails, error 1337)
```

Typing the Rust parameter (`Array<T>`) is the other way out, and belongs to the Rust port, not to a lint pass.

## Running it

| Command | Does |
| --- | --- |
| `python3 tools/gd_perf_lint.py` | the gate: 0 new/worse passes |
| `python3 tools/gd_perf_lint.py --by-file` | counts per file and kind, worst first |
| `python3 tools/gd_perf_lint.py --top 30` | the largest keys |
| `python3 tools/gd_perf_lint.py --update` | lower the baseline after a fix (never raises it) |

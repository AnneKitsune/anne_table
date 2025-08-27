# Fast, Generic, Simple In-Memory Database Table for Zig
This library provides `Table(T)`, a generic database-like table.
It is optimized for consistency/generality first (all keys are uuids), performance second (backed by an `ArrayHashMap`).

# Usage
1. Add to your project's build.zig.zon
2. Add the module to your module's imports
3. Use the following code as a cheatsheet:
```zig
const MyStruct = struct {
    a: u32,
};

// Init
var table = Table(MyStruct).init();
defer table.deinit(std.testing.allocator);

// Add
const key1 = try table.add(allocator, .{ .u = 0 });
const key2 = try table.add(allocator, .{ .u = 1 });

// Get
_ = table.get(key1).?;
table.getMut(key2).?.a = 55;

// Remove
table.remove(key1);

// Save/Load
try table.save(&writer.interface);
try table.load(std.testing.allocator, &reader.interface);

// Reset
table.clear();

// Iter
var iter = table.iter();
while (iter.next()) |pair| {
    const cur_key = pair.key_ptr.*;
    const cur_value = pair.value_ptr.*;
}

// Iter keys
for (table.keys()) |key| {}
// Iter values
for (table.values()) |value| {}
// Iter values mutable
for (table.valuesMut()) |value_ptr| {}
```

# Origins
This was invented in an attempt to keep the simplicity of a traditional bitset/vector-backed entity-component-system while improving on both speed and generality.

This turned out to be significantly more general than anticipated, as it can be used for practically all aspects of software development (it's quite literally a fast in-memory database with less features).
As for performance, it is a slight improvement over comparable rust entity-component-system such as `world_dispatcher`, `specs` and more.

However, for non-comparable ECS such as `legion` and `bevy_ecs`, we are significantly behind in terms of performance. If you value raw performance more than reusability, using an archetypal ECS will be better.

However, do keep in mind that since these are significantly less general, you will often move data in and out of the ECS into other structures.

This is not the case here as almost all data structures can be expressed as a 3 normal form database (with often some loss of performance.)

In exchange for the performance loss, you get the following:
- One table to rule them all; writing generic code that works over any of your data is trivial. (data inspector, serialization, editor, you name it.)
- Trivial save/load: dump the entire database into tsv files and load it back up later.
- Trivial references (foreign keys) between tables: it's always uuids.
- Optimally fast single-table iteration, get by key, insert and remove operation complexity.

Whether this or a more performant (and complex) alternative is better is entirely project-dependent.



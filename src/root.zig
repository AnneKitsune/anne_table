//! This library provides `Table(T)`, a generic database-like table.
//! It is optimized for consistency first (all keys are uuids), performance second (backed by an `ArrayHashMap`).
//!
//! This was invented in an attempt to keep the simplicity of a traditional bitset/vector-backed entity-component-system while improving on both speed and generality.
//! This turned out to be significantly more general than anticipated, as it can be used for practically all aspects of software development (it's quite literally a fast in-memory database with less features).
//! As for performance, it is a slight improvement over comparable rust entity-component-system such as `world_dispatcher`, `specs` and more. However, for non-comparable ECS such as `legion` and `bevy_ecs`, we are significantly behind in terms of performance. If you value raw performance more than reusability, using an archetypal ECS will be better. However, do keep in mind that since these are significantly less general, you will often move data in and out of the ECS into other structures. This is not the case here as almost all data structures can be expressed as a 3 normal form database (with often some loss of performance.)
//!
//! In exchange for the performance loss, you get the following:
//! - One table to rule them all; writing generic code that works over any of your data is trivial. (data inspector, serialization, editor, you name it.)
//! - Trivial save/load: dump the entire database into tsv files and load it back up later.
//! - Trivial references (foreign keys) between tables: it's always uuids.
//! - Optimally fast single-table iteration, get by key, insert and remove operation complexity.
//!
//! Whether this or a more performant (and complex) alternative is better is entirely project-dependent.

const std = @import("std");

const tsv = @import("tsv.zig");

const uuid = @import("uuid");
const benchmark = @import("benchmark");

const Map = @import("map.zig").Map;

/// Re-export of `anne_uuid`.
pub const Uuid = uuid.Uuid;

/// A generic database table structure.
///
/// It is specialized to use `Uuid` (a `u128`) as the key.
/// The generic type must be a flat struct: it must contain only fields of simple types (ints, floats, enums, bools, etc..) as well as strings.
///
/// You can technically have a simple type directly (`Table(u32)`) but you will not be able to save/load it as the tsv (de)serializer expects a struct. This can be useful for testing purposes.
///
/// For structs with strings specifically, they must have a `deinit(std.mem.Allocator)` function that will free the strings. This will be called automatically when `Table.deinit(std.mem.Allocator)` is called.
pub fn Table(comptime T: type) type {
    return struct {
        // fast iteration while still being a hashmap.
        // however will consume more RAM and needs one more indirection.
        // in practice I got more performance than my rust bitset ECS when doing a table join; but significantly less than `legion` due to the architectural differences.
        data: Map(T),

        const S = @This();

        /// Creates a new empty `Table(T)`.
        pub fn init() S {
            return S{
                .data = .empty,
            };
        }

        /// Deinits the table as well as any contained data that has an associated `deinit(std.mem.Allocator)` function.
        pub fn deinit(self: *S, allocator: std.mem.Allocator) void {
            if (@typeInfo(T) == .@"struct" and @hasDecl(T, "deinit")) {
                for (self.data.values()) |*v| {
                    v.deinit(self.data.allocator);
                }
            }
            self.data.deinit(allocator);
        }

        /// Inserts a new value with a random uuid. Prefer using this instead of `addWithKey`.
        /// # Errors
        /// - The memory allocation can fail if your allocator runs out of memory and if the internal data storage needs to be doing an allocation at this particular time.
        pub fn add(self: *S, allocator: std.mem.Allocator, value: T) !Uuid {
            const u = Uuid.new();
            try self.data.put(allocator, u, value);
            return u;
        }

        /// Inserts a new value with a fixed uuid. Prefer using `add`.
        ///
        /// # Caveat
        /// It is best to avoid using hardcoded uuids or generating them yourself.
        /// However, there are some cases where it makes sense for performance or replication reasons to provide your own uuids.
        ///
        /// # Errors
        /// - The memory allocation can fail if your allocator runs out of memory and if the internal data storage needs to be doing an allocation at this particular time.
        pub fn addWithKey(self: *S, allocator: std.mem.Allocator, key: Uuid, value: T) !void {
            try self.data.put(allocator, key, value);
        }

        /// Returns a copy of the data associated with the given uuid.
        pub inline fn get(self: *const S, key: Uuid) ?T {
            return self.data.get(key);
        }

        /// Returns a mutable pointer to the data associated with the given uuid.
        pub inline fn getMut(self: *S, key: Uuid) ?*T {
            return self.data.getPtr(key);
        }

        /// Removes data using the provided uuid key.
        pub inline fn remove(self: *S, key: Uuid) void {
            if (@typeInfo(T) == .@"struct" and @hasDecl(T, "deinit")) {
                if (self.getMut(key)) |val| {
                    val.deinit(self.data.allocator);
                }
            }
            _ = self.data.swapRemove(key);
        }

        /// Returns an iterator over key-value pairs.
        pub inline fn iter(self: *const S) Map(T).Iterator {
            return self.data.iterator();
        }

        /// Returns a slice of the keys contained within this struct.
        pub inline fn keys(self: *const S) []const Uuid {
            return self.data.keys();
        }

        /// Returns a slice of the values contained within this struct.
        pub inline fn values(self: *const S) []const T {
            return self.data.values();
        }

        /// Returns a mutable slice of the values contained within this struct.
        pub inline fn valuesMut(self: *S) []T {
            return self.data.values();
        }

        /// Erases all the data.
        pub inline fn clear(self: *S) void {
            if (@typeInfo(T) == .@"struct" and @hasDecl(T, "deinit")) {
                for (self.valuesMut()) |*val| {
                    val.deinit(self.data.allocator);
                }
            }
            self.data.clearRetainingCapacity();
        }

        /// Creates a copy of the table.
        /// # Safety
        /// Be careful when using this as it does *not* clone internal strings, only the slices (pointers). If you use this on a struct containing strings, expect double-free errors.
        ///
        /// # Errors
        /// - OutOfMemory if there is not enough memory available in the allocator.
        pub fn clone(self: *const S, allocator: std.mem.Allocator) !S {
            // TODO make copies of internal strings to improve on safety.
            const cloned = try self.data.clone(allocator);
            return S{
                .data = cloned,
            };
        }

        /// Returns the number of entries contained within this struct.
        pub inline fn count(self: *const S) usize {
            return self.data.count();
        }

        /// Loads data from a tsv input stream.
        /// # Notice
        /// This uses a limited (de)serializer for tsv that only supports flat structures (which you should be using. search "3 normal form" for more info) due to the specific way we (de)serialize the data.
        /// # Errors
        /// Will error if:
        /// - A line is longer than 4096 characters (be careful of unbounded strings; these can lead to denial of service.)
        /// - There is an empty line (delete it.)
        /// - There is a number of field that doesn't correspond to the number in the struct plus the uuid. (did you modify the struct since creating this file?)
        pub fn load(self: *S, allocator: std.mem.Allocator, reader: *std.Io.Reader) !void {
            try tsv.parse(T, reader, &self.data, allocator);
        }

        /// Saves data to a tsv output stream.
        /// # Notice
        /// This uses a limited (de)serializer for tsv that only supports flat structures (which you should be using. search "3 normal form" for more info) due to the specific way we (de)serialize the data.
        /// # Errors
        /// - Writer errors can happen for various reasons
        pub fn save(self: *const S, writer: *std.Io.Writer) !void {
            try tsv.write(T, &self.data, writer);
        }
    };
}

const TestStruct = struct {
    u: u32,
};
const TestStructs = Table(TestStruct);

test "all Table fn" {
    var table = TestStructs.init();
    defer table.deinit(std.testing.allocator);

    _ = try table.add(std.testing.allocator, .{ .u = 0 });
    _ = try table.add(std.testing.allocator, .{ .u = 1 });

    var iter = table.iter();
    var keys: [2]Uuid = undefined;
    var i: usize = 0;
    while (iter.next()) |pair| {
        keys[i] = pair.key_ptr.*;
        i += 1;
    }

    _ = table.get(keys[1]) orelse return error.MissingValueForKey;
    table.getMut(keys[0]).?.u = 55;
    table.remove(keys[1]);

    var cloned = try table.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expectEqual(table.count(), 1);
    table.clear();
    try std.testing.expectEqual(table.count(), 0);
}

test "ser/deser Table" {
    var table = Table(TestStruct).init();
    defer table.deinit(std.testing.allocator);
    _ = try table.add(std.testing.allocator, .{ .u = 5 });

    var file = try std.fs.cwd().createFile("test_save.tsv", .{ .read = true });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var writer = file.writer(buf[0..]);
    try table.save(&writer.interface);
    try writer.end();

    table.clear();
    try file.seekTo(0);

    var reader = file.reader(buf[0..]);
    try table.load(std.testing.allocator, &reader.interface);

    try std.testing.expectEqual(1, table.count());
    try std.testing.expectEqual(table.values()[0].u, 5);
}

test "Benchmark Table create+insert 1" {
    const b = struct {
        fn bench(ctx: *benchmark.Context) void {
            while (ctx.run()) {
                var table = Table(u32).init();
                defer table.deinit(std.testing.allocator);

                _ = table.add(std.testing.allocator, 1) catch unreachable;
                table.clear();
            }
        }
    }.bench;
    benchmark.benchmark("Benchmark Table create+insert 1", b);
}

test "Benchmark Table insert 100k" {
    const b = struct {
        fn bench(ctx: *benchmark.Context) void {
            var table = Table(u32).init();
            defer table.deinit(std.testing.allocator);

            while (ctx.run()) {
                for (0..100000) |i| {
                    _ = table.add(std.testing.allocator, @intCast(i)) catch unreachable;
                }
                table.clear();
            }
        }
    }.bench;
    benchmark.benchmark("Benchmark Table insert 100k", b);
}

fn benchIterSpeed(ctx: *benchmark.Context) void {
    const A = struct {
        v1: f32 = 1.0,
        v2: f32 = 1.0,
        v3: f32 = 1.0,
    };
    const B = struct {
        v1: f32 = 1.0,
        v2: f32 = 1.0,
        v3: f32 = 1.0,
        a_uuid: Uuid,
    };
    const alloc = std.testing.allocator;

    var a = Table(A).init();
    defer a.deinit(alloc);
    var b = Table(B).init();
    defer b.deinit(alloc);

    var count = @as(u32, 0);
    while (count < 10000) : (count += 1) {
        const u = a.add(alloc, .{}) catch unreachable;
        _ = b.add(alloc, .{ .a_uuid = u }) catch unreachable;
    }

    while (ctx.run()) {
        for (b.values()) |bv| {
            var av = a.getMut(bv.a_uuid).?;
            av.v1 += bv.v1;
            av.v2 += bv.v2;
            av.v3 += bv.v3;
        }
    }
}
test "Benchmark Table join iter speed 1..1 ref" {
    benchmark.benchmark("Table join iter speed 1..1 ref", benchIterSpeed);
}

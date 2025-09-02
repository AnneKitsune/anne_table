const std = @import("std");

const Uuid = @import("uuid").Uuid;

const UuidContext = struct {
    pub const hash = hash_uuid;
    pub const eql = eq_uuid;
};

pub inline fn hash_uuid(ctx: UuidContext, u: Uuid) u32 {
    _ = ctx;
    return @as(u32, @truncate(u.value));
}

pub inline fn eq_uuid(ctx: UuidContext, a: Uuid, b: Uuid, idx: usize) bool {
    _ = ctx;
    _ = idx;
    return a.value == b.value;
}

pub fn Map(comptime ty: type) type {
    return std.ArrayHashMapUnmanaged(Uuid, ty, UuidContext, false);
}

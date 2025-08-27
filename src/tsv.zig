//! Extremely simplified subset of tsv
//! Assumes that the first field is the Uuid key.
//! This is specifically made to be used with `Table(T)` where `T` is a flat structure.
//! Strings are supported by allocating them using the provided allocator. If `T` has a string value, it also *must* have a `deinit(std.mem.Allocator)` function deallocating the strings.

const std = @import("std");

const Uuid = @import("uuid").Uuid;
const UuidType = @import("uuid").UuidType;
const table = @import("root.zig");

const Map = @import("map.zig").Map;

const LINE_BUF_LEN = 4096;

pub const TsvError = error{
    EnumNotFound,
    MissingField,
    ParsedTooManyFields,
    WrongTypeParsed,
    InvalidUuid,
};

fn parsePrimitive(comptime ty: type, input: []const u8, allocator: std.mem.Allocator) !ty {
    switch (@typeInfo(ty)) {
        .int => {
            return try std.fmt.parseInt(ty, input, 10);
        },
        .float => return std.fmt.parseFloat(ty, input),
        .@"bool" => {
            if (std.mem.eql(u8, input, "true")) {
                return true;
            } else if (std.mem.eql(u8, input, "false")) {
                return false;
            } else {
                return TsvError.WrongTypeParsed;
            }
        },
        .@"enum" => |info| {
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, input)) {
                    return @enumFromInt(field.value);
                }
            }
            return error.EnumNotFound;
        },
        @typeInfo([]u8) => {
            const escaped_tab_count = std.mem.count(u8, input, "\\t");
            const mem = try allocator.alloc(u8, input.len - escaped_tab_count);
            const replacements = std.mem.replace(u8, input, "\\t", "\t", mem);
            std.debug.assert(escaped_tab_count == replacements);
            return mem;
        },
        else => {},
    }

    if (ty == Uuid) {
        const v = try std.fmt.parseInt(UuidType, input, 10);
        return Uuid{
            .value = v,
        };
    }

    @compileError("Cannot parse type '" ++ @typeName(ty) ++ "'");
}

/// Maximum line length = LINE_BUF_LEN.
pub fn parse(comptime ty: type, reader: *std.Io.Reader, ret: *Map(ty), allocator: std.mem.Allocator) !void {
    if (@typeInfo(ty) != .@"struct") {
        @compileError("Expected ty to be of struct type.");
    }
    //var line_iterator = std.mem.split(u8, input, "\n");
    var line_buf: [LINE_BUF_LEN]u8 = undefined;
    var line_writer = std.Io.Writer.fixed(line_buf[0..]);
    while (true) {
        // read line
        const line_len = try reader.streamDelimiterEnding(&line_writer, '\n');

        // reset the writer to the start of the buffer
        line_writer.end = 0;
        // drop the '\n' stuck in the reader
        if(reader.peek(1)) |reader_next| {
            if (reader_next[0] == '\n') {
                reader.toss(1);
            }
        } else |_| {}

        //line_writer = std.Io.Writer.fixed(line_buf[0..]);
        if (line_len == 0) {
            break;
        }
        const line = line_buf[0..line_len];
        if (line[0] == '#') continue;

        var field_iterator = std.mem.splitScalar(u8, line, '\t');
        var built_ty: ty = undefined;

        const uuid_str = field_iterator.next() orelse return error.MissingField;
        const uuid_val = std.fmt.parseInt(UuidType, uuid_str, 10) catch return error.InvalidUuid;
        const uuid = Uuid{
            .value = uuid_val,
        };

        inline for (@typeInfo(ty).@"struct".fields) |field| {
            const field_str = field_iterator.next() orelse return error.MissingField;
            @field(built_ty, field.name) = try parsePrimitive(field.type, field_str, allocator);
        }

        if (field_iterator.next()) |_| {
            return error.ParsedTooManyFields;
        }

        if (@typeInfo(ty) == .@"struct" and @hasDecl(ty, "deinit")) {
            if (ret.getPtr(uuid)) |removed| {
                removed.deinit(allocator);
            }
        }
        try ret.put(allocator, uuid, built_ty);
    }
}

pub fn write(comptime ty: type, input: *const Map(ty), writer: *std.Io.Writer) !void {
    if (@typeInfo(ty) != .@"struct") {
        @compileError("Expected ty to be of struct type");
    }

    try writer.print("#uuid", .{});
    inline for (@typeInfo(ty).@"struct".fields) |field| {
        try writer.print("\t{s}", .{field.name});
    }
    try writer.print("\n", .{});

    var it = input.iterator();
    while (it.next()) |pair| {
        const uuid = pair.key_ptr.*;
        const value = pair.value_ptr.*;

        try writer.print("{}", .{uuid.value});

        inline for (@typeInfo(ty).@"struct".fields) |field| {
            const v = @field(value, field.name);
            const v_ty = @TypeOf(v);
            switch (@typeInfo(v_ty)) {
                .int, .float => {
                    try writer.print("\t{}", .{v});
                    continue;
                },
                .@"bool" => {
                    if (v) {
                        try writer.print("\ttrue", .{});
                    } else {
                        try writer.print("\tfalse", .{});
                    }
                    continue;
                },
                .@"enum" => {
                    try writer.print("\t{}", .{@intFromEnum(v)});
                    continue;
                },
                @typeInfo([]u8) => {
                    try writer.print("\t", .{});
                    for (v) |char| {
                        if (char != '\t') {
                            try writer.print("{s}", .{char});
                        } else {
                            try writer.print("\\t", .{});
                        }
                    }
                    continue;
                },
                else => {},
            }

            if (v_ty == Uuid) {
                try writer.print("\t{}", .{v.value});
                continue;
            }

            @compileError("Cannot serialize field of type '" ++ @typeName(v_ty) ++ "'");
        }
        try writer.print("\n", .{});
    }
    try writer.flush();
}

test "Parse all supported types" {
    const TestEnum = enum {
        henlo,
    };
    const TestStruct = struct {
        a: []u8,
        b: i32,
        c: f32,
        d: bool,
        e: TestEnum,
        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.a);
        }
    };

    var data = Map(TestStruct).empty;
    defer data.deinit(std.testing.allocator);

    const test_content = "155\thenlouste\t-55\t-55.55\ttrue\thenlo";
    var reader = std.io.Reader.fixed(test_content);
    try parse(TestStruct, &reader, &data, std.testing.allocator);
    defer data.values()[0].deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("henlouste", data.values()[0].a);
    try std.testing.expectEqual(@as(i32, -55), data.values()[0].b);
    try std.testing.expectEqual(@as(f32, -55.55), data.values()[0].c);
    try std.testing.expect(data.values()[0].d);
    try std.testing.expectEqual(TestEnum.henlo, data.values()[0].e);
}

test "Parse string with tab" {
    const TestStruct = struct {
        a: []u8,
        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.a);
        }
    };

    var data = Map(TestStruct).empty;
    defer data.deinit(std.testing.allocator);

    const test_content = "155\then\\tlouste";
    var reader = std.io.Reader.fixed(test_content);
    try parse(TestStruct, &reader, &data, std.testing.allocator);
    defer data.values()[0].deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hen\tlouste", data.values()[0].a);
}

test "Parse line too long" {
    const TestStruct = struct {
        a: []u8,
        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.a);
        }
    };

    var data = Map(TestStruct).empty;
    defer data.deinit(std.testing.allocator);

    var test_content: [4200]u8 = @splat('a');
    test_content[test_content.len - 1] = '\n';

    var reader = std.io.Reader.fixed(test_content[0..]);
    const maybe_err = parse(TestStruct, &reader, &data, std.testing.allocator);
    try std.testing.expectError(error.WriteFailed, maybe_err);
}

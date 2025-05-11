// BSD-3-Clause : Copyright © 2025 Abigale Raeck.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Type = std.builtin.Type;

const writer_type_name = "preserves_name";
const name_custom_handler = "preservesStringify";

fn BackingInt(T: type) type {
    if (std.meta.containerLayout(T) != .@"packed") @compileError("Not a packed type: " ++ @typeName(T));

    return std.meta.Int(.unsigned, @bitSizeOf(T));
}

fn intFromPacked(value: anytype) BackingInt(@TypeOf(value)) {
    return @bitCast(value);
}

pub fn ComposeWriter(Base: type) type {
    return struct {
        fn PreservesError(W: type, A: type) type {
            const E = W.Error || (if (A == Allocator) A.Error else error{});

            return E!void;
        }

        const OrderedStructField = struct {
            field: Type.StructField,
            symbol: []const u8,

            pub fn lessThan(context: void, lhs: @This(), rhs: @This()) bool {
                return ordering(context, lhs.symbol, rhs.symbol);
            }
        };

        fn orderStructFieldsForDictionary(comptime fields: []const Type.StructField) [fields.len]OrderedStructField {
            var syrupified: [fields.len]OrderedStructField = undefined;
            var array = std.BoundedArray(u8, 100){}; // todo: fix field name len

            for (fields, 0..) |field, idx| {
                writeSymbol(array.writer(), field.name) catch unreachable;

                syrupified[idx] = .{
                    .field = field,
                    .symbol = array.constSlice() ++ "",
                };

                array.clear();
            }

            std.mem.sort(OrderedStructField, &syrupified, {}, OrderedStructField.lessThan);

            return syrupified;
        }

        // zig fmt: off
        pub const writeBoolean = Base.writeBoolean;
        pub const writeFloat   = Base.writeFloat;
        pub const writeDouble  = Base.writeDouble;
        pub const writeInteger = Base.writeInteger;
        pub const writeBinary  = Base.writeBinary;
        pub const writeString  = Base.writeString;
        pub const writeSymbol  = Base.writeSymbol;

        pub const beginDictionary = Base.beginDictionary;
        pub const beginSequence   = Base.beginSequence;
        pub const beginRecord     = Base.beginRecord;
        pub const beginSet        = Base.beginSet;

        pub const endDictionary = Base.endDictionary;
        pub const endSequence   = Base.endSequence;
        pub const endRecord     = Base.endRecord;
        pub const endSet        = Base.endSet;

        pub const ordering = Base.ordering;
        // zig fmt: on

        pub fn writeDictionaryGeneric(writer: anytype, allocator: anytype, value: anytype) PreservesError(@TypeOf(writer), @TypeOf(allocator)) {
            const Value = @TypeOf(value);

            try beginDictionary(writer);
            switch (@typeInfo(Value)) {
                .@"struct" => |st| {
                    inline for (orderStructFieldsForDictionary(st.fields)) |ofield| {
                        try writer.writeAll(ofield.symbol);
                        try _write(writer, allocator, @field(value, ofield.field.name));
                    }
                },
                else => @compileError("Invalid type to convert to Dictionary: " ++ @typeName(Value)),
            }
            try endDictionary(writer);
        }

        pub fn writeSequenceGeneric(writer: anytype, allocator: anytype, value: anytype) PreservesError(@TypeOf(writer), @TypeOf(allocator)) {
            const Value = @TypeOf(value);

            try beginSequence(writer);
            switch (@typeInfo(Value)) {
                .@"struct" => |st| {
                    inline for (st.fields) |field| try _write(writer, allocator, @field(value, field.name));
                },
                else => {
                    for (value) |v| try _write(writer, allocator, v);
                },
            }
            try endSequence(writer);
        }

        pub fn writeRecordGeneric(writer: anytype, allocator: anytype, value: anytype) PreservesError(@TypeOf(writer), @TypeOf(allocator)) {
            const Value = @TypeOf(value);
            const name = @typeName(Value);

            switch (@typeInfo(Value)) {
                .@"struct" => |st| {
                    try beginRecord(writer);
                    if (@hasDecl(Value, writer_type_name)) {
                        try _write(writer, allocator, Value.preserves_name);
                    } else {
                        try writeSymbol(writer, name);
                    }

                    for (st.fields) |field| {
                        try _write(writer, allocator, @field(value, field.name));
                    }
                    try endRecord(writer);
                },
                .@"union" => |uni| {
                    if (uni.tag_type == null) @compileError("Union missing tag type: " ++ name);
                    try beginRecord(writer);
                    try writeSymbol(writer, @tagName(value));
                    try _write(writer, allocator, @field(value, @tagName(value)));
                    try endRecord(writer);
                },
                else => @compileError("Invalid type to convert to Record: " ++ @typeName(Value)),
            }
        }

        pub fn writeSetGeneric(writer: anytype, allocator: anytype, value: anytype) PreservesError(@TypeOf(writer), @TypeOf(allocator)) {
            if (@TypeOf(allocator) != Allocator) @compileError("Missing Allocator needed for writing generic Sets");
            const parts = try allocator.alloc([]const u8, value.len);
            defer allocator.free(parts);

            // Fix: There are better ways then fifo and duplicating syrupOver
            var fifo = std.fifo.LinearFifo(u8, .Dynamic).init(allocator);
            defer fifo.deinit();

            var idx: usize = 0;
            defer for (0..idx) |x| allocator.free(parts[x]);
            while (idx < value.len) : (idx += 1) {
                try _write(fifo.writer(), allocator, value[idx]);

                parts[idx] = try fifo.toOwnedSlice();
            }

            std.mem.sort([]const u8, parts, {}, ordering);

            try beginSet(writer);
            for (parts) |p| try writer.writeAll(p);
            try endSet(writer);
        }

        // * Supported Type Defaults
        // | Zig Type        | Preserves Type         |
        // |-----------------+------------------------|
        // | bool            | bool                   |
        // | int             | int                    |
        // | signed int      | int                    |
        // | comptime_int    | int                    |
        // | f32             | float                  |
        // | f64             | double                 |
        // | comptime_float  | double                 |
        // | struct          | dictionary             |
        // | packed struct   | int                    |
        // | .{…} tuple      | sequence               |
        // | enum            | symbol                 |
        // | enum_literal    | symbol                 |
        // | * ⍰             | preserveOf(⍰)          |
        // | [] ⍰            | sequence               |
        // | [*:0] u8        | string                 |
        // | [*:⍰] ⍰         | sequence               |
        // | [*] ⍰           | -                      |
        // | [*c] ⍰          | -                      |
        // | [:0]u8          | string                 |
        // | []u8            | string                 |
        // | [:0] const u8   | string                 |
        // | [] const u8     | string                 |
        // | [_:0] u8        | string                 |
        // | [_] u8          | string                 |
        // | [_] ⍰           | sequence               |
        // | ?⍰              | false or preserveOf(⍰) |
        // | union           | record                 |
        // | packed union    | int                    |
        // | ???             | set                    |
        // | ???             | binary                 |
        //
        // If a struct or union has the following method, it is called over the auto convert types.
        // ~fn preservesStringify(self: Self, writer: @This()) Error!void {…}~
        //
        // If using the record type: any structs with a decl ~preserves_name~ will be used as the record name over the ~@typeName(…)~
        pub fn writeWithAllocator(writer: anytype, allocator: Allocator, value: anytype) PreservesError(@TypeOf(writer), @TypeOf(allocator)) {
            try _write(writer, allocator, value);
        }

        pub fn write(writer: anytype, value: anytype) @TypeOf(writer).Error!void {
            try _write(writer, {}, value);
        }

        fn _write(writer: anytype, allocator: anytype, value: anytype) PreservesError(@TypeOf(writer), @TypeOf(allocator)) {
            const Value = @TypeOf(value);
            const info = @typeInfo(Value);
            const name = @typeName(Value);

            switch (info) {
                .@"struct", .@"enum", .@"union" => if (@hasDecl(Value, name_custom_handler)) {
                    return @call(.auto, @field(Value, name_custom_handler), .{ value, @This() });
                },
                else => {},
            }

            switch (Value) {
                [:0]u8, []u8, [:0]const u8, []const u8 => {
                    return writeString(writer, value);
                },
                else => {},
            }

            switch (info) {
                .bool => try writeBoolean(writer, value),
                .comptime_int, .int => try writeInteger(writer, value),
                .comptime_float, .float => switch (Value) {
                    f32 => try writeFloat(writer, value),
                    comptime_float, f64 => try writeDouble(writer, value),
                    else => @compileError("Unsuported float type: " ++ name),
                },
                .enum_literal, .@"enum" => try writeSymbol(writer, @tagName(value)),
                .@"struct" => |st| {
                    if (st.layout == .@"packed") return writeInteger(writer, intFromPacked(value));
                    if (st.is_tuple) return writeSequenceGeneric(writer, allocator, value);

                    try writeDictionaryGeneric(writer, allocator, value);
                },
                .@"union" => |uni| {
                    if (uni.layout == .@"packed") return writeInteger(writer, intFromPacked(value));
                    try writeRecordGeneric(writer, allocator, value);
                },
                .pointer => |pt| {
                    const err_str = "Unsuported pointer type: " ++ name;
                    switch (pt.size) {
                        .one => try _write(writer, allocator, value.*),
                        .slice => try writeSequenceGeneric(writer, allocator, value), // strings get caught in the former switch statement.
                        .many => {
                            if (pt.sentinel()) |s| {
                                const span = std.mem.span(value);

                                if (pt.child == u8 and s == 0) return writeString(writer, span);
                                try writeSequenceGeneric(writer, allocator, span);
                            } else {
                                @compileError("Missing Sentinel: " ++ err_str);
                            }
                        },
                        .c => @compileError(err_str),
                    }
                },
                .array => |arri| {
                    if (arri.child == u8) return writeString(value);

                    try writeSequenceGeneric(writer, allocator, value);
                },
                .optional => {
                    if (value) |v| {
                        try _write(writer, allocator, v);
                    } else {
                        try writeBoolean(writer, false);
                    }
                },
                else => @compileError("Unimplemented: " ++ name),
            }
        }
    };
}

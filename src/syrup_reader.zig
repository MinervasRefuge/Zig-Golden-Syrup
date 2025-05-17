// BSD-3-Clause : Copyright © 2025 Abigale Raeck.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Scanner = @import("SyrupScanner.zig");

const toValue = std.mem.bytesToValue;
const toNative = std.mem.bigToNative;
const Type = std.builtin.Type;

const ScannerError = error{ SyntaxError, UnexpectedEndOfInput, Overflow }; // Scanner.Error; // no BufferUnderrun
const PlanError = error{PlanPersists};

fn ParseError(T: type) type {
    return ScannerError || Plan(T).Error;
}

pub fn parse(reader: anytype, allocator: Allocator, comptime T: type) ParseError(T)!T {
    return parseWithSize(reader, allocator, 64, T);
}

pub fn parseWithSize(reader: anytype, allocator: Allocator, buffer_size: comptime_int, comptime T: type) ParseError(T)!T {
    var plan: Plan(T) = .{};
    var scanner: Scanner = .{};
    var buffer: [buffer_size]u8 = undefined;
    var token: Scanner.Token = undefined;

    while (true) {
        token = scanner.next() catch |err| switch (err) {
            error.BufferUnderrun => {
                const len = try reader.read(&buffer);
                if (len == 0) {
                    plan.cleanUp(allocator);
                    return error.UnexpectedEndOfInput;
                }
                scanner.feedInput(buffer[0..len]);
                continue;
            },
            else => |se| return se,
        };

        if (plan.next(&token, allocator)) |value| {
            return value;
        } else |err| switch (err) {
            error.PlanPersists => {},
            else => |e| {
                plan.cleanUp(allocator);
                return e;
            },
        }
    }
}

fn Plan(T: type) type {
    //todo custom planner
    return switch (@typeInfo(T)) {
        .int => PlanInteger(T),
        .float => PlanFloating(T),
        .@"struct" => PlanStruct(T),
        .pointer => |pi| switch (pi.size) {
            .one => PlanSingularPointer(T),
            .slice => PlanString,
            else => @compileError("Unsuported Ptr Type: " ++ @typeName(T)),
        },
        .optional => PlanOptional(T),
        else => @compileError("Unsuported Type: " ++ @typeName(T)),
    };
}

fn PlanSingularPointer(P: type) type {
    const info = @typeInfo(P).pointer;
    std.debug.assert(info.size == .one);

    return struct {
        plan: Plan(info.child) = .{},

        pub const Error = PlanError || Plan(info.child).Error || Allocator.Error;

        pub fn next(self: *@This(), token: *const Scanner.Token, allocator: Allocator) Error!P {
            const value = try self.plan.next(token, allocator);
            const ptr = try allocator.create(info.child);
            ptr.* = value;

            return ptr;
        }

        fn cleanUp(self: *@This(), allocator: Allocator) void {
            self.plan.cleanUp(allocator);
        }
    };
}

fn PlanOptional(O: type) type {
    const info = @typeInfo(O).optional;
    std.debug.assert(info.child != bool or info.child != *bool or info.child != *const bool);

    return struct {
        state: enum { start, found } = .start,
        plan: Plan(info.child) = .{},

        pub const Error = PlanError || error{UnexpectedToken} || Plan(info.child).Error;

        pub fn next(self: *@This(), token: *const Scanner.Token, allocator: Allocator) Error!O {
            state_loop: switch (self.state) {
                .start => switch (token.*) {
                    .boolean => |b| switch (b) {
                        true => return error.UnexpectedToken,
                        false => return null,
                    },
                    else => {
                        self.state = .found;
                        continue :state_loop .found;
                    },
                },
                .found => {
                    if (try self.plan.next(token, allocator)) |value| {
                        return value;
                    }
                },
            }

            return error.PlanPersists;
        }

        fn cleanUp(self: *@This(), allocator: Allocator) void {
            self.plan.cleanUp(allocator);
        }
    };
}

fn PlanInteger(N: type) type {
    const info = @typeInfo(N).int;

    return struct {
        pub const Error = PlanError || error{ IllFit, UnexpectedToken };

        pub fn next(self: *@This(), token: *const Scanner.Token, allocator: Allocator) Error!N {
            _ = self;
            _ = allocator;

            switch (token.*) {
                .partial_number => |n| {
                    _ = n;
                    return error.PlanPersists;
                },
                .integer => |i| {
                    if (info.signedness == .signed) {
                        if (std.math.cast(N, i[1])) |v| {
                            return if (i[2] == .negative) v * -1 else v;
                        }

                        return error.IllFit;
                    } else {
                        if (i[2] == .negative) return error.IllFit;
                        return if (std.math.cast(N, i[1])) |v| v else error.IllFit;
                    }
                },
                else => return error.UnexpectedToken,
            }
        }

        fn cleanUp(self: *@This(), allocator: Allocator) void {
            _ = self;
            _ = allocator;
        }
    };
}

fn parseFloating(T: type, slice: [@sizeOf(T)]u8) T {
    _ = @typeInfo(T).float;
    const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
    const big = toValue(Int, slice);
    return @bitCast(toNative(Int, big));
}

fn PlanFloating(F: type) type {
    const info = @typeInfo(F).float;
    std.debug.assert(info.bits == 32 or info.bits == 64);

    return struct {
        part: std.BoundedArray(u8, 8) = .{},

        pub const Error = PlanError || error{ IllFit, UnexpectedToken };

        pub fn next(self: *@This(), token: *const Scanner.Token, allocator: Allocator) Error!F {
            _ = allocator;

            switch (token.*) {
                .partial_float, .partial_double => |part| {
                    self.part.append(part.slice) catch return error.IllFit;
                    return error.PlanPersists;
                },
                .float => |f| {
                    if (self.part.len == 0) {
                        if (f.len == 4) {
                            return parseFloating(f32, f);
                        }

                        return error.IllFit;
                    }

                    self.part.append(f) catch return error.IllFit;

                    if (self.part.len == 4) {
                        return parseFloating(f32, self.part.buffer);
                    }

                    return error.IllFit;
                },
                .double => |d| {
                    if (self.part.len == 0) {
                        if (d.len == 8) {
                            return parseFloating(f64, d);
                        }

                        return error.IllFit;
                    }

                    self.part.append(d) catch return error.IllFit;

                    if (self.part.len == 8) {
                        return parseFloating(f64, self.part.buffer);
                    }

                    return error.IllFit;
                },
                else => return error.UnexpectedToken,
            }
        }

        fn cleanUp(self: *@This(), allocator: Allocator) void {
            _ = allocator;
            self.part.clear();
        }
    };
}

fn PlanForStringLike(part: anytype, full: anytype) type {
    return struct {
        slice: []u8 = undefined,
        cursor: ?usize = null,

        pub const Error = PlanError || error{UnexpectedToken} || (if (full != .binary) error{InvalidUTF8} else error{}) || Allocator.Error;

        fn next(self: *@This(), token: *const Scanner.Token, allocator: Allocator) Error![]u8 {
            switch (token.*) {
                .partial_number => {},
                part => |p| {
                    if (self.cursor == null) {
                        self.slice = try allocator.alloc(u8, p.remanding + p.slice.len);
                        self.cursor = 0;
                    }

                    std.debug.assert(self.cursor != null);
                    const curse = self.cursor.?;

                    if (p.slice.len + curse >= self.slice.len) @panic("BufferTooSmall"); // Scanner failure, shouldn't happen?

                    @memcpy(self.slice[curse..][0..p.slice.len], p.slice);
                },
                full => |f| {
                    if (self.cursor) |curse| {
                        if (f.len + curse >= self.slice.len) @panic("BufferTooSmall"); // Scanner failure, shouldn't happen?

                        @memcpy(self.slice[curse..][0..f.len], f);

                        if (comptime full != .binary) {
                            if (!std.unicode.utf8ValidateSlice(self.slice)) return error.InvalidUTF8;
                        }

                        defer self.cursor = null;
                        return self.slice;
                    } else {
                        if (comptime full != .binary) {
                            if (!std.unicode.utf8ValidateSlice(f)) return error.InvalidUTF8;
                        }

                        return try allocator.dupe(u8, f);
                    }
                },
                else => return error.UnexpectedToken,
            }

            return error.PlanPersists;
        }

        fn cleanUp(self: *@This(), allocator: Allocator) void {
            if (self.cursor != null) {
                allocator.free(self.slice);
                self.cursor = null;
            }
        }
    };
}

const PlanSymbol = PlanForStringLike(.partial_symbol, .symbol);
const PlanString = PlanForStringLike(.partial_string, .string);
const PlanBinary = PlanForStringLike(.partial_binary, .binary);

fn PlanStruct(T: type) type {
    const info = @typeInfo(T).@"struct";

    const FieldEnum = std.meta.FieldEnum(T);
    var bit_fields: [info.fields.len]Type.StructField = undefined;
    var plan_fields: [info.fields.len]Type.StructField = undefined;
    var lookup_data: [info.fields.len]std.meta.Tuple(&.{ []const u8, FieldEnum }) = undefined;
    var sub_errors = error{};

    for (&plan_fields, &bit_fields, &lookup_data, info.fields) |*plan, *bit, *lookup, field| {
        const P = Plan(field.type);
        sub_errors = sub_errors || P.Error;
        const default_plan: P = .{};
        plan.* = .{
            .name = field.name,
            .type = P,
            .default_value_ptr = &default_plan,
            .is_comptime = false,
            .alignment = 0,
        };

        const default_bit = false;
        bit.* = .{
            .name = field.name,
            .type = bool,
            .default_value_ptr = &default_bit,
            .is_comptime = false,
            .alignment = 0,
        };

        lookup.* = .{ field.name, @field(FieldEnum, field.name) };
    }

    // zig fmt: off
    const Backing   = std.meta.Int(.unsigned, info.fields.len);
    const FieldBits = @Type(.{ .@"struct" = .{ .is_tuple = false, .layout = .@"packed", .decls = &.{}, .fields = &bit_fields } });
    const Plans     = @Type(.{ .@"struct" = .{ .is_tuple = false, .layout = .auto,      .decls = &.{}, .fields = &plan_fields } });
    const found_all: FieldBits = @bitCast(@as(Backing, std.math.maxInt(Backing)));
    const SubError = sub_errors;
    // zig fmt: on

    // todo: change plans to be a (union?) set of parsing types rather then every field
    //       since only one field is parsed at a time.

    const static_lookup: std.StaticStringMap(FieldEnum) = .initComptime(lookup_data);

    return struct {
        state: enum { start, key, value, end } = .start,
        found: FieldBits = .{},
        field: FieldEnum = undefined,
        ersatz: T = undefined,

        key_symbol: PlanSymbol = .{},
        value_plans: Plans = .{},

        const UniqueError = error{ UnexpectedToken, KeyFoundBefore, UnknownKey, ExpectedDictionaryStart, ExpectedDictionaryEnd };
        pub const Error = PlanError || UniqueError || SubError || Allocator.Error;

        fn next(self: *@This(), token: *const Scanner.Token, allocator: Allocator) Error!T {
            switch (self.state) {
                .start => {
                    if (token.* == .dictionary_start) {
                        self.state = .key;
                    } else {
                        self.cleanUp(allocator);
                        return error.ExpectedDictionaryStart;
                    }
                },
                .key => { // fix: there's a way todo this without allocation.
                    const key = try self.key_symbol.next(token, allocator);
                    defer allocator.free(key);

                    if (static_lookup.get(key)) |field| {
                        switch (field) {
                            inline else => |fenum| if (@field(self.found, @tagName(fenum))) {
                                self.cleanUp(allocator);
                                return error.KeyFoundBefore;
                            },
                        }
                        self.field = field;
                        self.state = .value;
                    } else {
                        self.cleanUp(allocator);
                        return error.UnknownKey;
                    }
                },
                .value => {
                    switch (self.field) {
                        inline else => |fenum| {
                            const field = @tagName(fenum);
                            if (@field(self.value_plans, field).next(token, allocator)) |value| { // found a complete value
                                @field(self.found, field) = true;
                                @field(self.ersatz, field) = value;
                            } else |err| {

                                //self.cleanUp(allocator);
                                return err;
                            }
                        },
                    }

                    self.state = if (self.found == found_all) .end else .key;
                },
                .end => {
                    if (token.* == .dictionary_end) {
                        return self.ersatz;
                    } else {
                        self.cleanUp(allocator);
                        return error.ExpectedDictionaryEnd;
                    }
                },
            }

            return error.PlanPersists;
        }

        fn cleanUp(self: *@This(), allocator: Allocator) void {
            inline for (info.fields) |field| {
                @field(self.value_plans, field.name).cleanUp(allocator);

                // fix: this isn't complete enough to free all data. (sub types may have ptrs)
                switch (@typeInfo(field.type)) {
                    .pointer => |pi| {
                        if (@field(self.found, field.name)) {
                            switch (pi.size) {
                                .one => allocator.destroy(@field(self.ersatz, field.name)),
                                .many, .slice => allocator.free(@field(self.ersatz, field.name)),
                                .c => unreachable,
                            }

                            @field(self.found, field.name) = false;
                        }
                    },
                    else => {},
                }
            }
        }
    };
}

const DebugAllocator = std.heap.DebugAllocator(.{});
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const eqDeep = std.testing.expectEqualDeep;

test "Simple Number" {
    var dba = DebugAllocator{};
    defer _ = dba.deinit();
    var fba = std.io.fixedBufferStream("1020+");

    try eq(1020, try parse(fba.reader(), dba.allocator(), usize));
}

test "Simple signed Number" {
    var dba = DebugAllocator{};
    defer _ = dba.deinit();
    var fba = std.io.fixedBufferStream("998-");

    try eq(-998, try parse(fba.reader(), dba.allocator(), isize));
}

test "Pointer to Number" {
    var dba = DebugAllocator{};
    defer _ = dba.deinit();
    var fba = std.io.fixedBufferStream("1923+");

    const out = try parse(fba.reader(), dba.allocator(), *usize);
    defer dba.allocator().destroy(out);
    try eq(@as(usize, 1923), out.*);
}

test "String Slice" {
    var dba = DebugAllocator{};
    defer _ = dba.deinit();
    var fba = std.io.fixedBufferStream("6\"rabbit");

    const out = try parse(fba.reader(), dba.allocator(), []const u8);
    defer dba.allocator().free(out);
    try eqStr("rabbit", out);
}

// test "String EOF" {
//     var dba = DebugAllocator{};
//     defer _ = dba.deinit();
//     var fba = std.io.fixedBufferStream("6\"parcel"[0..6]);
//     const out = try parse(fba.reader(), dba.allocator(), []const u8);
//     defer dba.allocator().free(out);
//     try eqStr("rabbit", out);
// }

test "Pointer to struct of two Number + slice" {
    var dba = DebugAllocator{};
    defer _ = dba.deinit();

    const T = struct { p1: usize, p2: isize, p3: []const u8 };

    { // general
        var fba = std.io.fixedBufferStream("{2'p11923+2'p243-2'p35\"Hello}");
        const out = try parse(fba.reader(), dba.allocator(), T);
        defer dba.allocator().free(out.p3);
        try eqDeep(T{ .p1 = 1923, .p2 = -43, .p3 = "Hello" }, out);
    }

    { // reorder
        var fba = std.io.fixedBufferStream("{2'p11923+2'p35\"Hello2'p243-}");
        const out = try parse(fba.reader(), dba.allocator(), T);
        defer dba.allocator().free(out.p3);
        try eqDeep(T{ .p1 = 1923, .p2 = -43, .p3 = "Hello" }, out);
    }

    { // EOF
        var fba = std.io.fixedBufferStream("{2'p11923+2'p35\"Hel");
        try eq(error.UnexpectedEndOfInput, parse(fba.reader(), dba.allocator(), T));
    }

    { // Expected End of Dictionary
        var fba = std.io.fixedBufferStream("{2'p11923+2'p35\"Hello4-");
        try eq(error.ExpectEndOfDictionary, parse(fba.reader(), dba.allocator(), T));
    }
}

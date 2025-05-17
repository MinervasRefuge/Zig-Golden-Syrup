// BSD-3-Clause : Copyright © 2025 Abigale Raeck.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Scanner = @import("SyrupScanner.zig");

const toValue = std.mem.bytesToValue;
const toNative = std.mem.bigToNative;
const Type = std.builtin.Type;

pub fn parseFor(reader: anytype, allocator: Allocator, comptime T: type) !T {
    return parseForWithSize(reader, allocator, 64, T);
}

pub fn parseForWithSize(reader: anytype, allocator: Allocator, buffer_size: comptime_int, comptime T: type) !T {
    var syrup = SyrupReader(@TypeOf(reader), buffer_size){
        .allocator = allocator,
        .scanner = .{},
        .reader = reader,
    };

    return syrup.parse(T);
}

pub fn SyrupReader(Reader: type, buffer_size: comptime_int) type {
    return struct {
        allocator: Allocator,
        scanner: Scanner,
        reader: Reader,
        buffer: [buffer_size]u8 = undefined,

        const Self = @This();

        // remove BufferUnderrun from Scanner.Error since it's caught.
        const TokenError = Reader.Error || error{ SyntaxError, UnexpectedEndOfInput, Overflow };

        fn nextToken(self: *Self) TokenError!Scanner.Token {
            while (true) {
                return self.scanner.next() catch |err| switch (err) {
                    error.BufferUnderrun => {
                        const len = try self.reader.read(&self.buffer);
                        if (len == 0) {
                            return error.UnexpectedEndOfInput;
                        }
                        self.scanner.feedInput(self.buffer[0..len]);
                        continue;
                    },
                    else => |se| return se,
                };
            }
        }

        pub fn parse(self: *Self, comptime T: type) !T {
            var plan = Plan(T){};

            if (plan.parsePart(self)) |value| return value else |err| {
                plan.resetPart(self.allocator);
                return err;
            }
        }

        fn Plan(T: type) type {
            //todo custom planner
            return switch (@typeInfo(T)) {
                .int => PlanInteger(T),
                .float => PlanFloating(T),
                .@"struct" => PlanStruct(T),
                .pointer => |pi| switch (pi.size) {
                    .slice => PlanString,
                    else => @compileError("Unsuported Ptr Type: " ++ @typeName(T)),
                },
                .optional => PlanOptional(T),
                else => @compileError("Unsuported Type: " ++ @typeName(T)),
            };
        }

        fn PlanOptional(Op: type) type {
            const info = @typeInfo(Op).optional;
            std.debug.assert(info.child != bool or info.child != *bool or info.child != *const bool);

            return struct {
                state: enum { start, found } = .start,
                plan: Plan(info.child) = .{},

                //pub const Error = TokenError || error{UnexpectedToken} || Plan(info.child).Error;

                pub fn parsePart(self: *@This(), syrup: *Self) !Op {
                    state_loop: switch (self.state) {
                        .start => switch (try syrup.nextToken()) { // this doesn't work as I am now one token ahead of where I need to be
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
                            return self.plan.parsePart(syrup);
                        },
                    }

                    unreachable;
                }

                fn resetPart(self: *@This(), allocator: Allocator) void {
                    self.plan.resetPart(allocator);
                    self.state = .start;
                }

                fn destroyPart(allocator: Allocator, value: Op) void {
                    if (value) |v| {
                        Plan(info.child).destroyPart(allocator, v);
                    }
                }
            };
        }

        fn PlanInteger(N: type) type {
            const info = @typeInfo(N).int;

            return struct {
                const PlanError = TokenError || error{ UnexpectedToken, IllFit };

                pub fn parsePart(self: *@This(), syrup: *Self) PlanError!N {
                    _ = self;

                    lp: switch (try syrup.nextToken()) {
                        .partial_number => |n| {
                            _ = n;
                            continue :lp try syrup.nextToken();
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

                fn resetPart(self: *@This(), allocator: Allocator) void {
                    _ = self;
                    _ = allocator;
                }

                fn destroyPart(allocator: Allocator, value: N) void {
                    _ = allocator;
                    _ = value;
                }
            };
        }

        fn PlanFloating(F: type) type {
            const info = @typeInfo(F).float;
            std.debug.assert(info.bits == 32 or info.bits == 64);

            return struct {
                part: std.BoundedArray(u8, @sizeOf(F)) = .{},

                pub const PlanError = TokenError || error{ IllFit, UnexpectedToken };

                fn transform(TF: type, slice: [@sizeOf(TF)]u8) TF {
                    _ = @typeInfo(TF).float;
                    const Int = std.meta.Int(.unsigned, @bitSizeOf(TF));
                    const big = toValue(Int, slice);
                    return @bitCast(toNative(Int, big));
                }

                pub fn parsePart(self: *@This(), syrup: *Self) PlanError!F {
                    state_loop: switch (try syrup.nextToken()) {
                        .partial_float, .partial_double => |part| {
                            self.part.append(part.slice) catch return error.IllFit;
                            continue :state_loop try syrup.nextToken();
                        },
                        .float => |f| {
                            if (self.part.len == 0) {
                                if (f.len == 4) {
                                    return transform(f32, f);
                                }

                                return error.IllFit;
                            }

                            self.part.append(f) catch return error.IllFit;

                            if (self.part.len == 4) {
                                return transform(f32, self.part.buffer);
                            }

                            return error.IllFit;
                        },
                        .double => |d| {
                            if (self.part.len == 0) {
                                if (d.len == 8) {
                                    return transform(f64, d);
                                }

                                return error.IllFit;
                            }

                            self.part.append(d) catch return error.IllFit;

                            if (self.part.len == 8) {
                                return transform(f64, self.part.buffer);
                            }

                            return error.IllFit;
                        },
                        else => return error.UnexpectedToken,
                    }

                    unreachable;
                }

                fn resetPart(self: *@This(), allocator: Allocator) void {
                    _ = allocator;
                    self.part.clear();
                }

                fn destroyPart(allocator: Allocator, value: F) void {
                    _ = allocator;
                    _ = value;
                }
            };
        }

        fn PlanForStringLike(part: anytype, full: anytype) type {
            return struct {
                slice: []u8 = undefined,
                cursor: ?usize = null,

                const PlanError = TokenError || error{ UnexpectedToken, InvalidUTF8 } || Allocator.Error;

                fn parsePart(self: *@This(), syrup: *Self) PlanError![]u8 {
                    lp: switch (try syrup.nextToken()) {
                        .partial_number => {},
                        part => |p| {
                            if (self.cursor == null) {
                                self.slice = try syrup.allocator.alloc(u8, p.remanding + p.slice.len);
                                self.cursor = 0;
                            }

                            std.debug.assert(self.cursor != null);
                            const curse = self.cursor.?;

                            if (p.slice.len + curse >= self.slice.len) @panic("BufferTooSmall"); // Scanner failure, shouldn't happen?

                            @memcpy(self.slice[curse..][0..p.slice.len], p.slice);
                            continue :lp try syrup.nextToken();
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

                                return try syrup.allocator.dupe(u8, f);
                            }
                        },
                        else => return error.UnexpectedToken,
                    }

                    unreachable;
                }

                fn resetPart(self: *@This(), allocator: Allocator) void {
                    if (self.cursor != null) {
                        allocator.free(self.slice);
                        self.cursor = null;
                    }
                }

                fn destroyPart(allocator: Allocator, value: []const u8) void {
                    allocator.free(value);
                }
            };
        }

        // zig fmt: off
        const PlanSymbol = PlanForStringLike(.partial_symbol, .symbol);
        const PlanString = PlanForStringLike(.partial_string, .string);
        const PlanBinary = PlanForStringLike(.partial_binary, .binary);
        // zig fmt: on

        fn PlanStruct(T: type) type {
            const info = @typeInfo(T).@"struct";

            const FieldEnum = std.meta.FieldEnum(T);
            var bit_fields: [info.fields.len]Type.StructField = undefined;
            var plan_fields: [info.fields.len]Type.StructField = undefined;
            var lookup_data: [info.fields.len]std.meta.Tuple(&.{ []const u8, FieldEnum }) = undefined;

            for (&plan_fields, &bit_fields, &lookup_data, info.fields) |*plan, *bit, *lookup, field| {
                const P = Plan(field.type);
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
            // zig fmt: on

            // todo: change plans to be a (union?) set of parsing types rather then every field
            //       since only one field is parsed at a time. Unless it's a recursive type?
            //       can contain duplicate Plans that don't need to be duplicated.

            const static_lookup: std.StaticStringMap(FieldEnum) = .initComptime(lookup_data);

            return struct {
                state: enum { start, key, value, end } = .start,
                found: FieldBits = .{},
                field: FieldEnum = undefined,
                ersatz: T = undefined,

                key_symbol: PlanSymbol = .{},
                value_plans: Plans = .{},

                //const PlanError = TokenError || error{ UnexpectedToken, InvalidUTF8 } || Allocator.Error;

                fn parsePart(self: *@This(), syrup: *Self) !T {
                    state_loop: switch (self.state) {
                        .start => {
                            if (try syrup.nextToken() == .dictionary_start) {
                                self.state = .key;
                                continue :state_loop self.state;
                            } else {
                                return error.ExpectedDictionaryStart;
                            }
                        },
                        .key => { // fix: there's a way todo this without allocation.
                            const key = try self.key_symbol.parsePart(syrup);
                            defer syrup.allocator.free(key);

                            if (static_lookup.get(key)) |field| {
                                switch (field) {
                                    inline else => |fenum| if (@field(self.found, @tagName(fenum)))
                                        return error.KeyFoundBefore,
                                }
                                self.field = field;
                                self.state = .value;
                                continue :state_loop self.state;
                            } else {
                                return error.UnknownKey;
                            }
                        },
                        .value => {
                            switch (self.field) {
                                inline else => |fenum| {
                                    const field = @tagName(fenum);
                                    const value = try @field(self.value_plans, field).parsePart(syrup);
                                    @field(self.found, field) = true;
                                    @field(self.ersatz, field) = value;
                                },
                            }

                            self.state = if (self.found == found_all) .end else .key;
                            continue :state_loop self.state;
                        },
                        .end => {
                            if (try syrup.nextToken() == .dictionary_end) {
                                self.found = .{};
                                self.state = .start;
                                return self.ersatz;
                            } else {
                                return error.ExpectedDictionaryEnd;
                            }
                        },
                    }

                    unreachable;
                }

                fn resetPart(self: *@This(), allocator: Allocator) void {
                    inline for (info.fields) |field| {
                        if (@field(self.found, field.name)) { // if the value was complete it needs to be deleted
                            Plan(field.type).destroyPart(allocator, @field(self.ersatz, field.name));
                            @field(self.found, field.name) = false;
                        }

                        @field(self.value_plans, field.name).resetPart(allocator);
                    }

                    self.key_symbol.resetPart(allocator);
                    self.state = .start;
                }

                fn destroyPart(allocator: Allocator, value: T) void {
                    inline for (std.meta.fields(Plans)) |field| {
                        field.type.destroyPart(allocator, @field(value, field.name));
                    }
                }
            };
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

    try eq(1020, try parseFor(fba.reader(), dba.allocator(), usize));
}

test "Simple signed Number" {
    var dba = DebugAllocator{};
    defer _ = dba.deinit();
    var fba = std.io.fixedBufferStream("998-");

    try eq(-998, try parseFor(fba.reader(), dba.allocator(), isize));
}

test "String Slice" {
    var dba = DebugAllocator{};
    defer _ = dba.deinit();
    var fba = std.io.fixedBufferStream("6\"rabbit");

    const out = try parseFor(fba.reader(), dba.allocator(), []const u8);
    defer dba.allocator().free(out);
    try eqStr("rabbit", out);
}

test "Pointer to struct of two Number + slice" {
    var dba = DebugAllocator{};
    defer _ = dba.deinit();

    const T = struct { p1: usize, p2: isize, p3: []const u8 };

    { // general
        var fba = std.io.fixedBufferStream("{2'p11923+2'p243-2'p35\"Hello}");
        const out = try parseFor(fba.reader(), dba.allocator(), T);
        defer dba.allocator().free(out.p3);
        try eqDeep(T{ .p1 = 1923, .p2 = -43, .p3 = "Hello" }, out);
    }
}

// BSD-3-Clause : Copyright © 2025 Abigale Raeck.
const std = @import("std");

const SyrupWriterPartial = @import("SyrupWriterPartial.zig");
const PreservesBinaryWriterPartial = @import("PreservesBinaryWriterPartial.zig");

const ComposeWriter = @import("compose_writer.zig").ComposeWriter;

pub const PreservesBinaryWriter = ComposeWriter(PreservesBinaryWriterPartial);

// Not ready for use
const syrup_reader = @import("syrup_reader.zig");
const syrup_reader2 = @import("syrup_reader2.zig");

pub const SyrupScanner = @import("SyrupScanner.zig");
pub const SyrupWriter = ComposeWriter(SyrupWriterPartial);

//
//
//

test {
    std.testing.refAllDeclsRecursive(@This());
}

const eqStr = std.testing.expectEqualStrings;
const Type = std.builtin.Type;

//
// Composites

// dictionaries
// sequences
// records
test "SyrupWriter.writeSetGeneric" {
    var dba = std.heap.DebugAllocator(.{}).init;
    defer _ = dba.deinit();

    // python: syrup_encode(set(range(34)))
    const python_syrup = "#0+1+10+11+12+13+14+15+16+17+18+19+2+20+21+22+23+24+25+26+27+28+29+3+30+31+32+33+4+5+6+7+8+9+$";
    const numbers = [_]u16{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33 };
    var as = std.BoundedArray(u8, python_syrup.len){};

    try SyrupWriter.writeSetGeneric(as.writer(), dba.allocator(), &numbers);
    try eqStr(python_syrup, as.constSlice());
}

//
// General

test "syrup write: enum literal" {
    var as = std.BoundedArray(u8, 100){};

    try SyrupWriter.write(as.writer(), .direct);
    try eqStr("6'direct", as.constSlice());
}

test "syrup write: struct packed" {
    var as = std.BoundedArray(u8, 100){};

    {
        const ContA = packed struct {
            is: bool,
            byte: u8,
            items: u16,
            qx: u2,
            qy: u2,
        };

        const data = ContA{ .is = true, .byte = 129, .items = 5349, .qx = 0, .qy = 1 };
        try SyrupWriter.write(as.writer(), data);
        try eqStr("136956675+", as.constSlice());
    }
}

test "syrup write: tuples" {
    var as = std.BoundedArray(u8, 100){};
    const data = .{ @as([]const u8, "bicycle"), @as(usize, 54) };

    try SyrupWriter.write(as.writer(), data);
    try eqStr("[7\"bicycle54+]", as.constSlice());
}

test "syrup write: struct" {
    var as = std.BoundedArray(u8, 100){};
    const data = .{
        .pt1 = [_]u16{ 5, 4, 3, 10, 20 },
        .pt2 = @as(isize, -105),
        .pt3 = @as(?i32, null),
    };

    try SyrupWriter.write(as.writer(), data);
    try eqStr("{3'pt1[5+4+3+10+20+]3'pt2105-3'pt3f}", as.constSlice());
}

test "syrup write: monthly-sea-ice-extent-in-the-arctic.zon" {
    const MSIEITA = struct {
        code: []const u8,
        cite: []const u8,
        data: []const Row,

        const Row = std.meta.Tuple(&.{ Year, Month, f64 });
        const Year = init: {
            const start = 1980;
            const end = 2025;
            var ef: [end - start + 1]Type.EnumField = undefined;

            for (&ef, 0..) |*f, idx| f.* = .{
                .name = std.fmt.comptimePrint("{d}", .{idx + start}),
                .value = idx,
            };

            break :init @Type(.{ .@"enum" = .{
                .tag_type = u8,
                .fields = &ef,
                .decls = &.{},
                .is_exhaustive = true,
            } });
        };
        const Month = enum { @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"10", @"11", @"12" };
    };
    const data: MSIEITA = @import("monthly-sea-ice-extent-in-the-arctic.zon");
    const syrup = @embedFile("monthly-sea-ice-extent-in-the-arctic.syrup"); // generated from python
    var as = std.BoundedArray(u8, syrup.len){};

    try SyrupWriter.write(as.writer(), data);
    try eqStr(syrup, as.constSlice());
}

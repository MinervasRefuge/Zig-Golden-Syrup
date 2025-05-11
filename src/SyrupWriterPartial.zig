// BSD-3-Clause : Copyright © 2025 Abigale Raeck.
const std = @import("std");

// https://github.com/ocapn/syrup/blob/master/draft-specification.md
//
// Booleans:           t or f
// Floats:             F<ieee-single-float>          (big endian)
// Doubles:            D<ieee-double-float>          (big endian)
// Positive integers:  <int>+
// Negative integers:  <int>-
// Binary data:        3:cat
// Strings:            6"björn                       (utf-8 encoded)
// Symbols:            6'update                      (utf-8 encoded)
// Dictionaries:       {<key1><val1><key2><val2>}    (sorted by key)
// Sequences:          [<item1><item2><item3>]
// Records:            <<label><val1><val2><val3>>   (the outer <> actually appear)
// Sets:               #<item1><item2><item3>$       (sorted)

const toBig = std.mem.nativeToBig;
const asBytes = std.mem.asBytes;
const Type = std.builtin.Type;

//
// Atoms

pub fn writeBoolean(writer: anytype, value: bool) @TypeOf(writer).Error!void {
    try writer.writeByte(if (value) 't' else 'f');
}

pub fn writeFloat(writer: anytype, value: f32) @TypeOf(writer).Error!void {
    const big = toBig(u32, @bitCast(value));
    const array = asBytes(&big);

    try writer.writeByte('F');
    try writer.writeAll(array);
}

pub fn writeDouble(writer: anytype, value: f64) @TypeOf(writer).Error!void {
    const big = toBig(u64, @bitCast(value));
    const array = asBytes(&big);

    try writer.writeByte('D');
    try writer.writeAll(array);
}

pub fn writeInteger(writer: anytype, value: anytype) @TypeOf(writer).Error!void {
    switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => {},
        else => @compileError("Not an int"),
    }

    try writer.print("{d}{c}", .{ @abs(value), @as(u8, if (value >= 0) '+' else '-') });
}

pub fn writeBinary(writer: anytype, value: []const u8) @TypeOf(writer).Error!void {
    try writer.print("{d}:", .{value.len});
    try writer.writeAll(value);
}

pub fn writeString(writer: anytype, value: []const u8) @TypeOf(writer).Error!void {
    std.debug.assert(std.unicode.utf8ValidateSlice(value));
    try writer.print("{d}\"{s}", .{ value.len, value });
}

pub fn writeSymbol(writer: anytype, value: []const u8) @TypeOf(writer).Error!void {
    std.debug.assert(std.unicode.utf8ValidateSlice(value));
    try writer.print("{d}'{s}", .{ value.len, value });
}

//
// Dictionary

pub fn beginDictionary(writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByte('{');
}

pub fn endDictionary(writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByte('}');
}

//
// Sequence

pub fn beginSequence(writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByte('[');
}

pub fn endSequence(writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByte(']');
}

//
// Record

pub fn beginRecord(writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByte('<');
}

pub fn endRecord(writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByte('>');
}

//
// Sets

pub fn beginSet(writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByte('#');
}

pub fn endSet(writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByte('$');
}

/// https://github.com/ocapn/syrup/blob/master/draft-specification.md#sorting-algorithm
pub fn ordering(context: void, lhs: []const u8, rhs: []const u8) bool {
    _ = context;
    var idx: usize = 0;
    while (true) : (idx += 1) {
        if (lhs.len == idx and rhs.len == idx) return false;

        if (lhs.len == idx) return true;
        if (rhs.len == idx) return false;

        if (lhs[idx] < rhs[idx]) return true;
        if (lhs[idx] > rhs[idx]) return false;
    }
}

//
//
//

//const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

test writeBoolean {
    var array = std.BoundedArray(u8, 2){};
    const w = array.writer();

    try writeBoolean(w, true);
    try writeBoolean(w, false);

    try eqStr("t", array.constSlice()[0..1]);
    try eqStr("f", array.constSlice()[1..2]);
}

test "Float" {
    return error.SkipZigTest;
}

test writeDouble {
    var array = std.BoundedArray(u8, 10){};
    const w = array.writer();

    try writeDouble(w, 123.456);

    try eqStr("D@^\xdd/\x1a\x9f\xbew", array.constSlice());
}

test writeInteger {
    var array = std.BoundedArray(u8, 10){};
    const w = array.writer();
    {
        defer array.clear();
        try writeInteger(w, 0);
        try eqStr("0+", array.constSlice());
    }
    {
        defer array.clear();
        try writeInteger(w, -10);
        try eqStr("10-", array.constSlice());
    }
    {
        defer array.clear();
        try writeInteger(w, 10235);
        try eqStr("10235+", array.constSlice());
    }

    {
        defer array.clear();
        try writeInteger(w, 9925);
        try eqStr("9925+", array.constSlice());
    }
    {
        defer array.clear();
        try writeInteger(w, -64339);
        try eqStr("64339-", array.constSlice());
    }
}

test writeBinary {
    var array = std.BoundedArray(u8, 10){};
    const w = array.writer();
    {
        defer array.clear();
        // Invalid Sequence Identifier Unicode
        const val = [_]u8{ 0xa0, 0xa1 };
        try writeBinary(w, &val);
        try eqStr("2:\xa0\xa1", array.constSlice());
    }
    {
        defer array.clear();
        const val = [_]u8{ 'a', 'b', 'c' };
        try writeBinary(w, &val);
        try eqStr("3:abc", array.constSlice());
    }
}

test writeString {
    var array = std.BoundedArray(u8, 20){};
    const w = array.writer();
    {
        defer array.clear();
        try writeString(w, "graveyard shift");
        try eqStr("15\"graveyard shift", array.constSlice());
    }
    {
        defer array.clear();
        try writeString(w, "Naïve");
        try eqStr("6\"Naïve", array.constSlice());
    }
}

test writeSymbol {
    var array = std.BoundedArray(u8, 15){};
    const w = array.writer();

    {
        defer array.clear();
        try writeSymbol(w, "tensegrity");
        try eqStr("10'tensegrity", array.constSlice());
    }
    {
        defer array.clear();
        try writeSymbol(w, "Kārlis");
        try eqStr("7'Kārlis", array.constSlice());
    }
}

// BSD-3-Clause : Copyright © 2025 Abigale Raeck.
const std = @import("std");

const writeVarInt = std.leb.writeUleb128;
const toBig = std.mem.nativeToBig;
const asBytes = std.mem.asBytes;

// https://preserves.dev/preserves-binary.html

const Tag = enum(u8) {
    // Tag values 82, 83, 88…AF, and B8…BF are reserved.
    // zig fmt: off
    false      = 0x80,
    true       = 0x81,
    end        = 0x84,
    annotation = 0x85,
    embedded   = 0x86,
    float      = 0x87,

    signed_integer = 0xB0,
    string         = 0xB1,
    binary         = 0xB2, // also known as a byte string
    symbol         = 0xB3,
    record         = 0xB4,
    sequence       = 0xB5,
    set            = 0xB6,
    dictionary     = 0xB7,
    // zig fmt: on

    inline fn int(self: @This()) u8 {
        return @intFromEnum(self);
    }
};

//
// Atoms

pub fn writeBoolean(writer: anytype, value: bool) @TypeOf(writer).Error!void {
    // (tag)
    try writer.writeByte((if (value) Tag.true else Tag.false).int());
}

pub fn writeFloat(writer: anytype, value: f32) @TypeOf(writer).Error!void {
    try writeDouble(writer, value);
}

pub fn writeDouble(writer: anytype, value: f64) @TypeOf(writer).Error!void {
    // (tag, len (8), value)
    const big = toBig(u64, @bitCast(value));
    try writer.writeAll(&[_]u8{ Tag.float.int(), 8 });
    try writer.writeAll(asBytes(&big));
}

// #+begin_quote
// For SignedInteger, it is the big-endian two’s-complement
// binary representation of the number, taking exactly as many
// whole bytes as needed to unambiguously identify the value
// and its sign. intbytes(0) is special-cased to be the empty
// byte sequence;
// #+end_quote
pub fn writeInteger(writer: anytype, value: anytype) @TypeOf(writer).Error!void {
    // (tag, varint(len), fitted_val[..])
    const Value = @TypeOf(value);
    const info = @typeInfo(Value).int;
    if (info.signedness == .unsigned) @compileError("Signed Ints only");

    try writer.writeByte(Tag.signed_integer.int());

    if (value == 0) { // special case
        try writer.writeByte(0x00);
        return;
    }

    const highest_bit = switch (info.signedness) {
        .signed => @bitSizeOf(Value) - @clz(@abs(value)) + 1, // signed twos complement,
        .unsigned => @bitSizeOf(Value) - @clz(value),
    };
    const fit = std.math.divCeil(usize, highest_bit, 8) catch unreachable;
    try writeVarInt(writer, fit);

    const size = @sizeOf(Value);
    const big = toBig(Value, value);
    try writer.writeAll(asBytes(&big)[size - fit .. size]);
}

pub fn writeBinary(writer: anytype, value: []const u8) @TypeOf(writer).Error!void {
    // (tag, varint(len), binary)
    try writer.writeByte(@intFromEnum(Tag.binary));
    try writeVarInt(writer, value.len);
    try writer.writeAll(value);
}

pub fn writeString(writer: anytype, value: []const u8) @TypeOf(writer).Error!void {
    // (tag, varint(len), utf8)
    try writer.writeByte(@intFromEnum(Tag.string));
    try writeVarInt(writer, value.len);
    std.debug.assert(std.unicode.utf8ValidateSlice(value));
    try writer.writeAll(value);
}

pub fn writeSymbol(writer: anytype, value: []const u8) @TypeOf(writer).Error!void {
    // (tag, varint(len), utf8)
    try writer.writeByte(@intFromEnum(Tag.symbol));
    try writeVarInt(writer, value.len);
    std.debug.assert(std.unicode.utf8ValidateSlice(value));
    try writer.writeAll(value);
}

//
// Dictionary
// (tag, [K,V]*, end)

pub fn beginDictionary(writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByte(Tag.dictionary.int());
}

pub fn endDictionary(writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByte(Tag.end.int());
}

//
// Sequence
// (tag, [V]*, end)

pub fn beginSequence(writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByte(Tag.sequence.int());
}

pub fn endSequence(writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByte(Tag.end.int());
}

//
// Record
// (tag, L, [V]*, end)

pub fn beginRecord(writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByte(Tag.record.int());
}

pub fn endRecord(writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByte(Tag.end.int());
}

//
// Sets
// (tag, [V]*, end)

pub fn beginSet(writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByte(Tag.set.int());
}

pub fn endSet(writer: anytype) @TypeOf(writer).Error!void {
    try writer.writeByte(Tag.end.int());
}

// Other
// - annotation
// - embedded

// todo: Check
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

const toNative = std.mem.bigToNative;
const toValue = std.mem.bytesToValue;
const eq = std.testing.expectEqual;
const eqSlice = std.testing.expectEqualSlices;
const eqStr = std.testing.expectEqualStrings;

fn readVarIntFromSlice(slice: []const u8) !isize {
    var fbs = std.io.fixedBufferStream(slice);
    return std.leb.readUleb128(isize, fbs.reader());
}

test writeBoolean {
    var array = std.BoundedArray(u8, 2){};
    const w = array.writer();

    try writeBoolean(w, true);
    try writeBoolean(w, false);

    const s = array.constSlice();
    try eq(Tag.true.int(), s[0]);
    try eq(Tag.false.int(), s[1]);
}

test writeDouble {
    var array = std.BoundedArray(u8, 10){};
    const w = array.writer();

    {
        defer array.clear();
        const val: f64 = 54.2156;
        try writeDouble(w, val);

        const s = array.constSlice();
        try eq(1 + 1 + 8, s.len);
        try eq(Tag.float.int(), s[0]);
        try eq(8, try readVarIntFromSlice(s[1..]));
        try eq(val, @as(f64, @bitCast(toNative(u64, toValue(u64, s[2..])))));
    }
}

test writeInteger {
    var array = std.BoundedArray(u8, 6){};
    const w = array.writer();

    { // one byte positive
        defer array.clear();
        const val: isize = 101;
        try writeInteger(w, val);

        const s = array.constSlice();
        try eq(1 + 1 + 1, s.len);
        try eq(Tag.signed_integer.int(), s[0]);
        try eq(1, try readVarIntFromSlice(s[1..]));
        try eq(val, s[2]);
    }
    { // two bytes positive
        defer array.clear();
        const val: isize = 0x08_F1;
        try writeInteger(w, val);

        const s = array.constSlice();
        try eq(1 + 1 + 2, s.len);
        try eq(Tag.signed_integer.int(), s[0]);
        try eq(2, try readVarIntFromSlice(s[1..]));
        try eq(val, toNative(i16, toValue(i16, s[2..])));
    }
    { // zero bytes
        defer array.clear();
        const val: isize = 0x00;
        try writeInteger(w, val);

        const s = array.constSlice();
        try eq(1 + 1 + 0, s.len);
        try eq(Tag.signed_integer.int(), s[0]);
        try eq(0, try readVarIntFromSlice(s[1..]));
    }
    { // two bytes negative
        defer array.clear();
        const val: isize = -1435; // 1010 0110 0101
        try writeInteger(w, val);

        const s = array.constSlice();
        try eq(1 + 1 + 2, s.len);
        try eq(Tag.signed_integer.int(), s[0]);
        try eq(2, try readVarIntFromSlice(s[1..]));
        try eq(val, toNative(i16, toValue(i16, s[2..])));
    }
    { // three bytes negative
        defer array.clear();
        const val: isize = -34203; // 1111 1111 0111 1010 0110 0101
        try writeInteger(w, val);

        const s = array.constSlice();
        try eq(1 + 1 + 3, s.len);
        try eq(Tag.signed_integer.int(), s[0]);
        try eq(3, try readVarIntFromSlice(s[1..]));
        try eq(val, toNative(i24, toValue(i24, s[2..])));
    }
    { // three bytes positive
        defer array.clear();
        const val: isize = 34203; // 0000 0000 1000 0101 1001 1011
        try writeInteger(w, val);

        const s = array.constSlice();
        try eq(1 + 1 + 3, s.len);
        try eq(Tag.signed_integer.int(), s[0]);
        try eq(3, try readVarIntFromSlice(s[1..]));
        try eq(val, toNative(i24, toValue(i24, s[2..])));
    }
}

test writeBinary {
    var array = std.BoundedArray(u8, 20){};
    const w = array.writer();

    {
        defer array.clear();
        const val = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
        try writeBinary(w, &val);

        const s = array.constSlice();
        try eq(1 + 1 + val.len, s.len);
        try eq(Tag.binary.int(), s[0]);
        try eq(12, try readVarIntFromSlice(s[1..]));
        try eqSlice(u8, &val, s[2..]);
    }
}

test writeString {
    var array = std.BoundedArray(u8, 20){};
    const w = array.writer();

    {
        defer array.clear();
        const val = "Hello World!";
        try writeString(w, val);

        const s = array.constSlice();
        try eq(1 + 1 + val.len, s.len);
        try eq(Tag.string.int(), s[0]);
        try eq(12, try readVarIntFromSlice(s[1..]));
        try eqStr(val, s[2..]);
    }
}

test writeSymbol {
    var array = std.BoundedArray(u8, 20){};
    const w = array.writer();

    {
        defer array.clear();
        const val = @tagName(.Plant);
        try writeSymbol(w, val);

        const s = array.constSlice();
        try eq(1 + 1 + val.len, s.len);
        try eq(Tag.symbol.int(), s[0]);
        try eq(5, try readVarIntFromSlice(s[1..]));
        try eqStr(val, s[2..]);
    }
}

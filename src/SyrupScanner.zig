// BSD-3-Clause : Copyright © 2025 Abigale Raeck.
const std = @import("std");

pub const Token = union(enum) {
    boolean: bool,
    float: []const u8,
    double: []const u8,
    integer: std.meta.Tuple(&.{ []const u8, usize, enum { positive, negative } }),
    binary: []const u8,
    string: []const u8,
    symbol: []const u8,

    partial_float: Remainder,
    partial_double: Remainder,
    partial_binary: Remainder,
    partial_string: Remainder,
    partial_symbol: Remainder,

    dictionary_start,
    sequence_start,
    record_start,
    set_start,

    dictionary_end,
    sequence_end,
    record_end,
    set_end,

    partial_number: []const u8,

    end_of_document, // todo
};

pub const Remainder = struct { remanding: usize, slice: []const u8 };

const State = enum {
    value,
    number,
    float,
    double,
    binary,
    string,
    symbol,
    record_label,
};

const PFrame = enum {
    dictionary,
    sequence,
    record,
    set,
};

state: State = .value,
cursor: usize = 0,
input: []const u8 = "",
prefixed_length: usize = 0,
is_end_of_input: bool = false,

// todo: consider tracking the enters and exits on collection types
// stack_trace: std.ArrayList(PFrame) = .init(allocator: Allocator)

pub fn feedInput(self: *@This(), input: []const u8) void {
    self.input = if (self.is_end_of_input) "" else input;
}

pub fn removeUnreadInput(self: *@This()) []const u8 {
    const out = self.input[self.cursor..];
    self.input = "";
    self.cursor = 0;

    return out;
}

pub fn endInput(self: *@This()) void {
    self.is_end_of_input = true;
}

pub const Error = error{ SyntaxError, UnexpectedEndOfInput, BufferUnderrun, Overflow };

pub fn next(self: *@This()) Error!Token {
    if (self.isAtTheEnd()) {
        return if (self.is_end_of_input and self.state == .value)
            .end_of_document
        else
            error.BufferUnderrun;
    }

    state_loop: switch (self.state) {
        .value => {
            switch (self.input[self.cursor]) {
                't' => {
                    self.chomp();
                    return .{ .boolean = true };
                },
                'f' => {
                    self.chomp();
                    return .{ .boolean = false };
                },
                '0'...'9' => |n| {
                    // if usize overflows should the assumtion be that it could only be a large int
                    // should that be it's own state? that can only end in + or -
                    try self.accumulatePossiblePrefixLength(n);
                    self.cursor += 1;
                    self.state = .number;
                    continue :state_loop .number;
                },
                'F' => {
                    self.chomp();
                    self.prefixed_length = 4;
                    self.state = .float;
                    continue :state_loop .float;
                },
                'D' => {
                    self.chomp();
                    self.prefixed_length = 8;
                    self.state = .double;
                    continue :state_loop .double;
                },
                '{' => return self.enterCollection(.dictionary),
                '}' => return self.exitCollection(.dictionary),
                '[' => return self.enterCollection(.sequence),
                ']' => return self.exitCollection(.sequence),
                '<' => {
                    self.state = .record_label;
                    return self.enterCollection(.record);
                },
                '>' => return self.exitCollection(.record),
                '#' => return self.enterCollection(.set),
                '$' => return self.exitCollection(.set),
                else => return error.SyntaxError,
            }
        },
        .number => {
            if (self.isAtTheEnd()) {
                return .{ .partial_number = self.sliceToEnd() };
            }

            switch (self.input[self.cursor]) {
                '0'...'9' => |n| {
                    try self.accumulatePossiblePrefixLength(n);
                    self.cursor += 1;
                    continue :state_loop .number;
                },
                '+' => {
                    const val = self.prefixed_length;
                    self.prefixed_length = 0;
                    self.state = .value;
                    return .{ .integer = .{ self.sliceToSkipCurrent(), val, .positive } };
                },
                '-' => {
                    const val = self.prefixed_length;
                    self.prefixed_length = 0;
                    self.state = .value;
                    return .{ .integer = .{ self.sliceToSkipCurrent(), val, .negative } };
                },
                ':' => {
                    self.chomp();
                    self.state = .binary;
                    continue :state_loop .binary;
                },
                '"' => {
                    self.chomp();
                    self.state = .string;
                    continue :state_loop .string;
                },
                '\'' => {
                    self.chomp();
                    self.state = .symbol;
                    continue :state_loop .symbol;
                },
                else => return error.SyntaxError,
            }

            unreachable;
        },
        .float => return self.sliceWithAccumulation(.partial_float, .float),
        .double => return self.sliceWithAccumulation(.partial_double, .double),
        .binary => return self.sliceWithAccumulation(.partial_binary, .binary),
        .string => return self.sliceWithAccumulation(.partial_string, .string),
        .symbol => return self.sliceWithAccumulation(.partial_symbol, .symbol),
        .record_label => {
            // ensure that the record has at least on value for the label
            if (self.input[self.cursor] == '>') return error.SyntaxError;

            self.state = .value;
            continue :state_loop .value;
        },
    }

    unreachable;
}

//
// Utilities

fn sliceWithAccumulation(self: *@This(), comptime part: std.meta.Tag(Token), comptime fin: std.meta.Tag(Token)) Error!Token {
    //std.debug.print("input: {s} len:{d} acc: {d} cursor: {d}\n", .{ self.input, self.input.len, self.accumulated_length, self.cursor });

    if (self.input.len == 0) return error.BufferUnderrun;

    if (self.input.len < self.prefixed_length) {
        return @unionInit(Token, @tagName(part), self.sliceRemanding());
    } else {
        self.state = .value;
        self.cursor += self.prefixed_length - 1;
        self.prefixed_length = 0;
        return @unionInit(Token, @tagName(fin), self.sliceToIncludeCurrent());
    }
}

fn sliceRemanding(self: *@This()) Remainder {
    self.prefixed_length -= self.input.len;
    return .{ .remanding = self.prefixed_length, .slice = self.sliceToEnd() };
}

fn isAtTheEnd(self: *const @This()) bool {
    return self.cursor >= self.input.len;
}

fn accumulatePossiblePrefixLength(self: *@This(), digit: u8) error{Overflow}!void {
    self.prefixed_length = try std.math.mul(usize, self.prefixed_length, 10);
    self.prefixed_length = try std.math.add(usize, self.prefixed_length, digit - '0');
    //self.accumulated_length *= 10;
    //self.accumulated_length += digit - '0';
}

fn chomp(self: *@This()) void {
    self.input = self.input[self.cursor + 1 ..];
    self.cursor = 0;
}

fn sliceToIncludeCurrent(self: *@This()) []const u8 {
    const out = self.input[0 .. self.cursor + 1];
    self.input = self.input[self.cursor + 1 ..];
    self.cursor = 0;

    return out;
}

fn sliceToSkipCurrent(self: *@This()) []const u8 {
    const out = self.input[0..self.cursor];
    self.input = self.input[self.cursor + 1 ..];
    self.cursor = 0;

    return out;
}

fn sliceToEnd(self: *@This()) []const u8 {
    const out = self.input;
    self.input = "";
    self.cursor = 0;

    return out;
}

// todo: Consider tracking collection levels
fn enterCollection(self: *@This(), comptime frame: PFrame) Token {
    self.chomp();

    return switch (frame) {
        .dictionary => .dictionary_start,
        .record => .record_start,
        .sequence => .sequence_start,
        .set => .set_start,
    };
}

// todo: Consider tracking collection levels
fn exitCollection(self: *@This(), comptime frame: PFrame) Token {
    self.chomp();

    return switch (frame) {
        .dictionary => .dictionary_end,
        .record => .record_end,
        .sequence => .sequence_end,
        .set => .set_end,
    };
}

//
//
//

const eq = std.testing.expectEqual;
const eqDeep = std.testing.expectEqualDeep;
const dprint = std.debug.print;

fn expectContainsScalar(comptime T: type, sequence: []T, value: T) error{TestExpectsScalarMember}!void {
    if (std.mem.indexOfScalar(T, sequence, value) == null) {
        dprint("Expected member {any} in sequence {any}\n", .{ value, sequence });
        return error.TestExpectsScalarMember;
    }
}

//
// Scanner Behaviours

test "scanner: empty" {
    var scanner: @This() = .{};

    try eq(error.BufferUnderrun, scanner.next());
}

test "scanner: .part_number" {
    var scanner: @This() = .{};
    const data = "432";

    scanner.feedInput(data);

    try eqDeep(Token{ .partial_number = "432" }, try scanner.next());
    try eq(error.BufferUnderrun, scanner.next());
}

test "scanner: .end_of_document empty" {
    var scanner: @This() = .{};

    scanner.endInput();
    try eqDeep(.end_of_document, try scanner.next());
}

test "scanner: .end_of_document full" {
    var scanner: @This() = .{};
    const data = "tf10+";

    try eq(error.BufferUnderrun, scanner.next());

    scanner.feedInput(data);
    scanner.endInput();

    try eqDeep(Token{ .boolean = true }, try scanner.next());
    try eqDeep(Token{ .boolean = false }, try scanner.next());
    try eqDeep(Token{ .integer = .{ "10", 10, .positive } }, try scanner.next());
    try eqDeep(.end_of_document, try scanner.next());
    try eqDeep(.end_of_document, try scanner.next());
}

//
// Atom types

test "Boolean" {
    var scanner: @This() = .{};
    const data = "tfttff";

    scanner.feedInput(data);
    try eqDeep(Token{ .boolean = true }, try scanner.next());
    try eqDeep(Token{ .boolean = false }, try scanner.next());
    try eqDeep(Token{ .boolean = true }, try scanner.next());
    try eqDeep(Token{ .boolean = true }, try scanner.next());
    try eqDeep(Token{ .boolean = false }, try scanner.next());
    try eqDeep(Token{ .boolean = false }, try scanner.next());
    try eq(error.BufferUnderrun, scanner.next());
}

test "Float" {
    var scanner: @This() = .{};
    const data = "Fabcd";

    scanner.feedInput(data);
    scanner.endInput();

    try eqDeep(Token{ .float = data[1..] }, try scanner.next());
    try eq(.end_of_document, scanner.next());
}

test "Double" {
    var scanner: @This() = .{};
    const data = "D@^\xdd/\x1a\x9f\xbew"; // 123.456

    scanner.feedInput(data);

    try eqDeep(Token{ .double = data[1..] }, try scanner.next());
    try eq(error.BufferUnderrun, scanner.next());
}

test "Integer: Complete Negative" {
    var scanner: @This() = .{};
    const data = "483-";

    scanner.feedInput(data);

    try eqDeep(Token{ .integer = .{ "483", 483, .negative } }, try scanner.next());
    try eq(error.BufferUnderrun, scanner.next());
}

test "Integer: Complete Positive" {
    var scanner: @This() = .{};
    const data = "50349+";

    scanner.feedInput(data);

    try eqDeep(Token{ .integer = .{ "50349", 50349, .positive } }, try scanner.next());
    try eq(error.BufferUnderrun, scanner.next());
}

test "Integer: Consecutive" {
    var scanner: @This() = .{};
    const data = "5000+374-211+1-0+";

    scanner.feedInput(data);

    try eqDeep(Token{ .integer = .{ "5000", 5000, .positive } }, try scanner.next());
    try eqDeep(Token{ .integer = .{ "374", 374, .negative } }, try scanner.next());
    try eqDeep(Token{ .integer = .{ "211", 211, .positive } }, try scanner.next());
    try eqDeep(Token{ .integer = .{ "1", 1, .negative } }, try scanner.next());
    try eqDeep(Token{ .integer = .{ "0", 0, .positive } }, try scanner.next());
    try eq(error.BufferUnderrun, scanner.next());
}

test "Binary" {
    const bin = [_]u8{ 0xB1, 0xD2, 0x46, 0x19, 0x04, 0x31, 0x2E, 0x1F, 0x4B, 0x36, 0x8d, 0x75, 0x63, 0xD1, 0x5C, 0xB8, 0x25, 0x72, 0x02, 0x7A };
    const data = std.fmt.comptimePrint("{d}:", .{bin.len}) ++ bin;
    var scanner: @This() = .{};

    scanner.feedInput(data);
    try eqDeep(Token{ .binary = &bin }, try scanner.next());
    try eq(error.BufferUnderrun, scanner.next());
}

test "String: Complete" {
    var scanner: @This() = .{};
    const data = "17\"Odites metaclista";

    scanner.feedInput(data);

    try eqDeep(Token{ .string = "Odites metaclista" }, try scanner.next());
}

test "String: split on token string" {
    var scanner: @This() = .{};
    const data = "9\"Eucalypts";
    const slice = &.{ data[0..2], data[2..] };

    scanner.feedInput(slice[0]);
    try eq(error.BufferUnderrun, scanner.next());

    scanner.feedInput(slice[1]);
    try eqDeep(Token{ .string = "Eucalypts" }, try scanner.next());
    try eq(error.BufferUnderrun, scanner.next());
}

test "Symbol: Complete" {
    var scanner: @This() = .{};
    const data = "17'Bartlett's rātā";

    scanner.feedInput(data);

    try eqDeep(Token{ .symbol = "Bartlett's rātā" }, try scanner.next());
}

test "Symbol: .part_number .part_symbol .symbol" {
    var scanner: @This() = .{};
    const data = "29'Mechanically stabilized earth";
    const slices = &.{ data[0..1], data[1..10], data[10..] };

    scanner.feedInput(slices[0]);
    try eqDeep(Token{ .partial_number = "2" }, try scanner.next());
    try eq(error.BufferUnderrun, scanner.next());

    scanner.feedInput(slices[1]);
    try eqDeep(Token{ .partial_symbol = .{ .remanding = 22, .slice = "Mechani" } }, try scanner.next());
    try eq(error.BufferUnderrun, scanner.next());

    scanner.feedInput(slices[2]);
    try eqDeep(Token{ .symbol = "cally stabilized earth" }, try scanner.next());
    try eq(error.BufferUnderrun, scanner.next());
}

//
// Composites

test "Dictionary" {
    var scanner: @This() = .{};
    const data = "{6'vivify7\"refresh6'welter9\"commotion9'dichotomy10\"difference}";

    scanner.feedInput(data);
    try eqDeep(.dictionary_start, try scanner.next());
    try eqDeep(Token{ .symbol = "vivify" }, try scanner.next());
    try eqDeep(Token{ .string = "refresh" }, try scanner.next());
    try eqDeep(Token{ .symbol = "welter" }, try scanner.next());
    try eqDeep(Token{ .string = "commotion" }, try scanner.next());
    try eqDeep(Token{ .symbol = "dichotomy" }, try scanner.next());
    try eqDeep(Token{ .string = "difference" }, try scanner.next());
    try eqDeep(.dictionary_end, try scanner.next());
    try eq(error.BufferUnderrun, scanner.next());
}

test "Sequence" {
    var scanner: @This() = .{};
    const data = "[1+2-3+]";

    scanner.feedInput(data);
    try eqDeep(.sequence_start, try scanner.next());
    try eqDeep(Token{ .integer = .{ "1", 1, .positive } }, try scanner.next());
    try eqDeep(Token{ .integer = .{ "2", 2, .negative } }, try scanner.next());
    try eqDeep(Token{ .integer = .{ "3", 3, .positive } }, try scanner.next());
    try eqDeep(.sequence_end, try scanner.next());
    try eq(error.BufferUnderrun, scanner.next());
}

test "Record: Invalid" {
    var scanner: @This() = .{};
    const data = "<>";

    scanner.feedInput(data);
    try eqDeep(.record_start, try scanner.next());
    try eq(error.SyntaxError, scanner.next());
}

test "Record: Just the Label" {
    var scanner: @This() = .{};
    const data = "<5'label>";

    scanner.feedInput(data);
    try eqDeep(.record_start, try scanner.next());
    try eqDeep(Token{ .symbol = "label" }, try scanner.next());
    try eqDeep(.record_end, try scanner.next());
    try eq(error.BufferUnderrun, scanner.next());
}

test "Record: Many" {
    var scanner: @This() = .{};
    const data = "<5'labeltf180+30-6\"syntax>";

    scanner.feedInput(data);
    try eqDeep(.record_start, try scanner.next());
    try eqDeep(Token{ .symbol = "label" }, try scanner.next());
    try eqDeep(Token{ .boolean = true }, try scanner.next());
    try eqDeep(Token{ .boolean = false }, try scanner.next());
    try eqDeep(Token{ .integer = .{ "180", 180, .positive } }, try scanner.next());
    try eqDeep(Token{ .integer = .{ "30", 30, .negative } }, try scanner.next());
    try eqDeep(Token{ .string = "syntax" }, try scanner.next());
    try eqDeep(.record_end, try scanner.next());
    try eq(error.BufferUnderrun, scanner.next());
}

test "Sets" {
    const data = "#0+1+10+11+12+13+14+15+16+17+18+19+2+20+21+22+23+24+25+26+27+28+29+3+30+31+32+33+4+5+6+7+8+9+$";
    var values = std.BoundedArray(usize, 34){};
    var scanner: @This() = .{};

    scanner.feedInput(data);
    scanner.endInput();

    var tok = try scanner.next();
    try eqDeep(.set_start, tok);

    tok = try scanner.next();
    while (!std.meta.eql(Token{ .set_end = {} }, tok)) : (tok = try scanner.next()) {
        try values.append(tok.integer[1]);
    }

    try eqDeep(.set_end, tok);
    try eqDeep(.end_of_document, try scanner.next());

    for (0..34) |v| try expectContainsScalar(usize, &values.buffer, v);
}

//
// complex

// test "Scanner complex: 1" {
//     var scanner: @This() = .{},

// }

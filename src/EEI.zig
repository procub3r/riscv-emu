const std = @import("std");

const Self = @This();
pub const InvalidAddress = error{InvalidAddress};

pub const Exception = enum {
    illegal_instruction,
    instruction_address_misaligned,
};

// Pointers to functions in the Execution Environment
read_byte_fn: *const fn (self: *Self, addr: u32) InvalidAddress!u8,
write_byte_fn: *const fn (self: *Self, addr: u32, byte: u8) InvalidAddress!void,
exception_fn: *const fn (self: *Self, e: Exception) void,

// Read value of type T byte by byte from the EEI
pub fn read(self: *Self, comptime T: type, addr_: i32) InvalidAddress!T {
    const addr = @as(u32, @bitCast(addr_));
    var buf: [@sizeOf(T)]u8 = undefined;
    var i: u32 = 0;
    while (i < @sizeOf(T)) : (i += 1) {
        buf[i] = try self.read_byte_fn(self, addr + i);
    }
    return std.mem.bytesToValue(T, &buf);
}

// Write value of anytype byte by byte to the EEI
pub fn write(self: *Self, addr_: i32, value: anytype) InvalidAddress!void {
    const addr = @as(u32, @bitCast(addr_));
    const bytes = std.mem.asBytes(&value);
    var i: u32 = 0;
    while (i < bytes.len) : (i += 1) {
        try self.write_byte_fn(self, addr + i, bytes[i]);
    }
}

// Trigger an exception to the EEI
pub fn exception(self: *Self, e: Exception) void {
    self.exception_fn(self, e);
}

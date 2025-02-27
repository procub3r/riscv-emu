const std = @import("std");
const EEI = @import("EEI.zig");

const Self = @This();

eei: *EEI, // contains functions to talk to the execution environment
// pc and registers are i32's (and not u32's) for easy arithmetic
pc: i32 = 0, // program counter
x: [32]i32 = .{0} ** 32, // 32 registers, x0 - x31
raw_instr: u32 = 0, // currently executing instruction as a raw u32

pub fn init(eei: *EEI) Self {
    return Self{ .eei = eei };
}

// Return pc as a u32
pub fn pcUnsigned(self: *Self) u32 {
    return @bitCast(self.pc);
}

// Dump core state for debugging
pub fn dump(self: *Self) void {
    std.debug.print("pc = 0x{x:0>8}\n", .{self.pcUnsigned()});
    for (0..32) |i| {
        std.debug.print(
            "x{d:<2}= 0x{x:0>8}  ",
            .{ i, @as(u32, @bitCast(self.x[i])) },
        );
        if (i % 8 == 7) std.debug.print("\n", .{});
    }
}

// Instruction types
const InstrJ = packed struct { op: u7, rd: u5, i12_19: u8, i11: u1, i1_10: u10, i20: u1 };
// To help extract instruction immediates
const ImmJ = packed struct { zero: u1, i1_10: u10, i11: u1, i12_19: u8, i20: u1 };

// Extract immediate from an instruction
fn immediate(instr: anytype) i32 {
    const imm = switch (@TypeOf(instr)) {
        InstrJ => ImmJ{ .zero = 0, .i1_10 = instr.i1_10, .i11 = instr.i11, .i12_19 = instr.i12_19, .i20 = instr.i20 },
        else => @compileError("Invalid type"),
    };
    return @as(std.meta.Int(.signed, @bitSizeOf(@TypeOf(imm))), @bitCast(imm));
}

fn reg(self: *Self, i: u5) u32 {
    if (i == 0) return 0; // always return 0 for x0
    return self.x[i];
}

fn setReg(self: *Self, i: u5, value: i32) void {
    if (i == 0) return; // don't set value of x0
    self.x[i] = value;
}

// Trigger an illegal-instruction exception
fn illegalInstruction(self: *Self) void {
    self.eei.exception(.illegal_instruction);
}

// Step through one instruction (fetch / decode / execute it)
pub fn step(self: *Self) !void {
    self.raw_instr = try self.eei.read(u32, self.pc);
    const opcode: u7 = @truncate(self.raw_instr);

    switch (opcode) {
        // jal
        0b1101111 => {
            const instr: InstrJ = @bitCast(self.raw_instr);
            self.setReg(instr.rd, self.pc +% 4); // link
            self.jump(self.pc +% immediate(instr)); // jump
            return; // return to avoid incrementing pc at the end of this function
        },
        else => self.illegalInstruction(),
    }
    self.pc +%= 4;
}

// Jump to target by setting pc
fn jump(self: *Self, target: i32) void {
    // Target must be IALIGN (32) bit aligned
    if (@as(u32, @bitCast(target)) % 4 != 0) {
        self.eei.exception(.instruction_address_misaligned);
    }
    self.pc = target;
}

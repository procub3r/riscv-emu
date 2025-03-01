const std = @import("std");
const EEI = @import("EEI.zig");

const Self = @This();

eei: *EEI, // contains functions to talk to the execution environment
// pc and registers are i32's (and not u32's) for easy arithmetic
pc: i32 = 0, // program counter
x: [32]i32 = .{0} ** 32, // 32 registers, x0 - x31
raw_instr: u32 = 0, // currently executing instruction as a raw u32

// CSRs.
mhartid: i32,
mtvec: i32 = 0,
mnstatus: i32 = 0,
mstatus: i32 = 0,
medeleg: i32 = 0,
mideleg: i32 = 0,
mie: i32 = 0,
mepc: i32 = 0,
mcause: i32 = 0,
satp: i32 = 0,
pmpaddr: [64]i32 = .{0} ** 64,
pmpcfg: [4]i32 = .{0} ** 4,

pub fn init(eei: *EEI, hartid: i32) Self {
    return Self{ .eei = eei, .mhartid = hartid };
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
const InstrI = packed struct { op: u7, rd: u5, fn3: u3, rs1: u5, i0_11: u12 };
const InstrB = packed struct { op: u7, i11: u1, i1_4: u4, fn3: u3, rs1: u5, rs2: u5, i5_10: u6, i12: u1 };
const InstrU = packed struct { op: u7, rd: u5, i12_31: u20 };
const InstrR = packed struct { op: u7, rd: u5, fn3: u3, rs1: u5, rs2: u5, fn7: u7 };
const InstrS = packed struct { op: u7, i0_4: u5, fn3: u3, rs1: u5, rs2: u5, i5_11: u7 };
// To help extract instruction immediates
const ImmJ = packed struct { zero: u1, i1_10: u10, i11: u1, i12_19: u8, i20: u1 };
const ImmI = packed struct { i0_11: u12 };
const ImmB = packed struct { zero: u1, i1_4: u4, i5_10: u6, i11: u1, i12: u1 };
const ImmU = packed struct { zero: u12, i12_31: u20 };
const ImmS = packed struct { i0_4: u5, i5_11: u7 };

// Extract immediate from an instruction
fn immediate(instr: anytype) i32 {
    const imm = switch (@TypeOf(instr)) {
        InstrJ => ImmJ{ .zero = 0, .i1_10 = instr.i1_10, .i11 = instr.i11, .i12_19 = instr.i12_19, .i20 = instr.i20 },
        InstrI => ImmI{ .i0_11 = instr.i0_11 },
        InstrB => ImmB{ .zero = 0, .i1_4 = instr.i1_4, .i5_10 = instr.i5_10, .i11 = instr.i11, .i12 = instr.i12 },
        InstrU => ImmU{ .zero = 0, .i12_31 = instr.i12_31 },
        InstrS => ImmS{ .i0_4 = instr.i0_4, .i5_11 = instr.i5_11 },
        else => @compileError("Invalid type"),
    };
    return @as(std.meta.Int(.signed, @bitSizeOf(@TypeOf(imm))), @bitCast(imm));
}

fn reg(self: *Self, i: u5) i32 {
    if (i == 0) return 0; // always return 0 for x0
    return self.x[i];
}

fn setReg(self: *Self, i: u5, value: i32) void {
    if (i == 0) return; // don't set value of x0
    self.x[i] = value;
}

fn CSRPtr(self: *Self, csr: u12) *i32 {
    var csr_ptr: *i32 = undefined;
    switch (csr) {
        0xf14 => csr_ptr = &self.mhartid,
        0x305 => csr_ptr = &self.mtvec,
        0x744 => csr_ptr = &self.mnstatus,
        0x300 => csr_ptr = &self.mstatus,
        0x302 => csr_ptr = &self.medeleg,
        0x303 => csr_ptr = &self.mideleg,
        0x304 => csr_ptr = &self.mie,
        0x341 => csr_ptr = &self.mepc,
        0x342 => csr_ptr = &self.mcause,
        0x180 => csr_ptr = &self.satp,
        0x3b0...0x3ef => csr_ptr = &self.pmpaddr[csr - 0x3b0],
        0x3a0...0x3a3 => csr_ptr = &self.pmpcfg[csr - 0x3a0],
        else => self.eei.exception(.illegal_instruction),
    }
    return csr_ptr;
}

fn CSR(self: *Self, csr: u12) i32 {
    return self.CSRPtr(csr).*;
}

fn setCSR(self: *Self, csr: u12, value: i32) void {
    self.CSRPtr(csr).* = value;
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
        // lui
        0b0110111 => {
            const instr: InstrU = @bitCast(self.raw_instr);
            self.setReg(instr.rd, immediate(instr));
        },
        // auipc
        0b0010111 => {
            const instr: InstrU = @bitCast(self.raw_instr);
            self.setReg(instr.rd, self.pc +% immediate(instr));
        },
        // store
        0b0100011 => {
            const instr: InstrS = @bitCast(self.raw_instr);
            const addr = immediate(instr) +% self.reg(instr.rs1);
            switch (instr.fn3) {
                0b010 => try self.eei.write(addr, self.reg(instr.rs2)),
                else => self.illegalInstruction(),
            }
        },
        // jal
        0b1101111 => {
            const instr: InstrJ = @bitCast(self.raw_instr);
            self.setReg(instr.rd, self.pc +% 4); // link
            self.jump(self.pc +% immediate(instr)); // jump
            return; // return to avoid incrementing pc at the end of this function
        },
        // reg
        0b0110011 => {
            const instr: InstrR = @bitCast(self.raw_instr);
            const rs1 = self.reg(instr.rs1);
            const rs2 = self.reg(instr.rs2);
            var value: i32 = undefined;
            switch (instr.fn7) {
                0b0000000 => {
                    switch (instr.fn3) {
                        0b000 => value = rs1 +% rs2, // add
                        else => self.illegalInstruction(),
                    }
                },
                else => self.illegalInstruction(),
            }
            self.setReg(instr.rd, value);
        },
        // imm
        0b0010011 => {
            const instr: InstrI = @bitCast(self.raw_instr);
            const imm = immediate(instr);
            const imm_unsigned: u32 = @bitCast(imm);
            const shamt: u5 = @truncate(imm_unsigned);
            const imm_upper: u7 = @truncate(imm_unsigned >> 5);
            var value: i32 = undefined;
            switch (instr.fn3) {
                // addi
                0b000 => value = self.reg(instr.rs1) +% imm,
                // ori
                0b110 => value = self.reg(instr.rs1) | imm,
                // slli
                0b001 => {
                    if (imm_upper != 0b0000000) self.illegalInstruction();
                    value = self.reg(instr.rs1) << shamt;
                },
                else => self.illegalInstruction(),
            }
            self.setReg(instr.rd, value);
        },
        // branch
        0b1100011 => {
            const instr: InstrB = @bitCast(self.raw_instr);
            var condition: bool = undefined;
            switch (instr.fn3) {
                0b000 => condition = self.reg(instr.rs1) == self.reg(instr.rs2), // beq
                0b001 => condition = self.reg(instr.rs1) != self.reg(instr.rs2), // bne
                0b100 => condition = self.reg(instr.rs1) < self.reg(instr.rs2), // blt
                0b101 => condition = self.reg(instr.rs1) >= self.reg(instr.rs2), // bge
                else => self.illegalInstruction(),
            }
            if (condition) {
                self.jump(self.pc +% immediate(instr));
                return;
            }
        },
        // fence is a nop because memory accesses are emulated in order always.
        // pause (under the fence opcode) is also a nop.
        0b0001111 => {},
        // system
        0b1110011 => {
            const instr: InstrI = @bitCast(self.raw_instr);
            switch (self.raw_instr >> 7) {
                0b0011000_00010_00000_000_00000 => {
                    const target = self.mepc >> 2 << 2;
                    self.jump(target);
                    return;
                },
                else => {},
            }
            switch (instr.fn3) {
                0b000 => {
                    switch (instr.i0_11) {
                        // ecall
                        0b000000000000 => {
                            // TODO: actual privilege mode stuff and generate an exception.
                            // you're not supposed to directly jump to mtvec lol
                            self.jump(self.mtvec);
                            return;
                        },
                        else => self.illegalInstruction(),
                    }
                },
                // csrrw
                0b001 => {
                    const rs1 = self.reg(instr.rs1);
                    if (instr.rd != 0) self.setReg(instr.rd, self.CSR(instr.i0_11));
                    self.setCSR(instr.i0_11, rs1);
                },
                // csrrs
                0b010 => {
                    const rs1 = self.reg(instr.rs1);
                    const csr = self.CSR(instr.i0_11);
                    self.setReg(instr.rd, csr);
                    self.setCSR(instr.i0_11, csr | rs1);
                },
                // csrrwi
                0b101 => {
                    if (instr.rd != 0) self.setReg(instr.rd, self.CSR(instr.i0_11));
                    self.setCSR(instr.i0_11, instr.rs1);
                },
                else => self.illegalInstruction(),
            }
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

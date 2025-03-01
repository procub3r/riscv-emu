const std = @import("std");
const EEI = @import("EEI.zig");
const Core = @import("Core.zig");

const Self = @This();

eei: EEI = undefined, // interface into the test environment used by the core
core: Core = undefined,
entry_point: usize = 0, // entry point of the test executable
// Emulated memory. Only stores memory starting from `entry_point` because
// none of the test binaries use any memory before that. As a result, an
// offset (with value `entry_point`) must be subtracted from all memory accesses
memory: [0x10000]u8 = undefined,

pub fn init(self: *Self) void {
    self.eei = EEI{
        .read_byte_fn = readByte,
        .write_byte_fn = writeByte,
        .exception_fn = exception,
    };
    self.core = Core.init(&self.eei, 0);
}

// Load an ELF test binary's segments to emulated memory
// and set core's program counter to the entry point.
pub fn loadBinary(self: *Self, bin_path: []const u8) !void {
    const elf_file = try std.fs.cwd().openFile(bin_path, .{});
    defer elf_file.close();
    const elf_hdr = try std.elf.Header.read(elf_file);
    self.entry_point = elf_hdr.entry;

    // Loop through all program headers
    var phdrs = elf_hdr.program_header_iterator(elf_file);
    while (try phdrs.next()) |phdr| {
        // Ignore non loadable segments
        if (phdr.p_type != std.elf.PT_LOAD) continue;
        // Calculate start and end offsets of segment in emulated memory
        const start = phdr.p_vaddr - self.entry_point;
        const end = start + phdr.p_filesz;
        // Load the segment from the file to emulated memory
        try elf_file.seekableStream().seekTo(phdr.p_offset);
        try elf_file.reader().readNoEof(self.memory[start..end]);
    }

    // Set the core's program counter to the entry point
    self.core.pc = @bitCast(@as(u32, @intCast(elf_hdr.entry)));
}

// Progress the test environment
pub fn step(self: *Self) !?void {
    try self.core.step();
    const tohost: u32 = 0x80001000;
    const val = try self.eei.read(i32, @bitCast(tohost));
    std.debug.print("tohost: {}\n", .{val});
    if (val != 0) return null;
}

// Dump state of the test environment for debugging
pub fn dump(self: *Self) void {
    self.core.dump();
}

// Implement the EEI interface
fn readByte(eei: *EEI, addr_: u32) EEI.InvalidAddress!u8 {
    const self: *Self = @fieldParentPtr("eei", eei);
    const addr = addr_ - self.entry_point;
    if (addr >= self.memory.len) return error.InvalidAddress;
    return self.memory[addr];
}

fn writeByte(eei: *EEI, addr_: u32, byte: u8) EEI.InvalidAddress!void {
    const self: *Self = @fieldParentPtr("eei", eei);
    const addr = addr_ - self.entry_point;
    if (addr >= self.memory.len) return error.InvalidAddress;
    self.memory[addr] = byte;
}

fn exception(eei: *EEI, e: EEI.Exception) void {
    const self: *Self = @fieldParentPtr("eei", eei);
    std.debug.print("Exception ", .{});
    switch (e) {
        .illegal_instruction => {
            std.debug.panic(
                "{} @ addr 0x{x:0>8}: 0x{x:0>8}\n",
                .{ e, self.core.pcUnsigned(), self.core.raw_instr },
            );
        },
        .instruction_address_misaligned => {
            std.debug.print(
                "{} @ addr 0x{x:0>8}\n",
                .{ e, self.core.pcUnsigned() },
            );
        },
        // else => std.debug.print("{}\n", .{e}),
    }
}

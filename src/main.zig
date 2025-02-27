const std = @import("std");
const TestEnv = @import("TestEnv.zig");

pub fn main() !void {
    std.debug.print("Run `zig build test`\n", .{});
}

test "riscv-tests" {
    // Create test execution environment
    var test_env = TestEnv{};
    test_env.init();

    // Load a binary compiled from riscv-tests
    try test_env.loadBinary("deps/riscv-tests/isa/rv32ui-p-add");

    // Execute the binary!
    while (try test_env.step()) |_| {
        test_env.dump();
    }
}

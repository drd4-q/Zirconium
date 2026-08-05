const std = @import("std");
const ValueMod = @import("value.zig");
const Value = ValueMod.Value;

// Syscall numbers
const SYS_WRITE: u64 = 1;
const SYS_READ: u64 = 2;
const SYS_SLEEP: u64 = 10;
const SYS_TIME: u64 = 11;

fn syscall3(num: u64, arg1: u64, arg2: u64, arg3: u64) u64 {
    return asm volatile (
        \\syscall
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

fn syscall1(num: u64, arg1: u64) u64 {
    return asm volatile (
        \\syscall
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [arg1] "{rdi}" (arg1),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

fn serialWriteKernel(str: []const u8) void {
    _ = syscall3(SYS_WRITE, 3, @intFromPtr(str.ptr), str.len);
}

fn vgaWriteKernel(str: []const u8) void {
    _ = syscall3(SYS_WRITE, 1, @intFromPtr(str.ptr), str.len);
}

fn readFromStdin(buf: []u8) usize {
    return syscall3(SYS_READ, 0, @intFromPtr(buf.ptr), buf.len);
}

fn sleepKernel(ms: u64) void {
    _ = syscall1(SYS_SLEEP, ms);
}

fn getTimeKernel() u64 {
    return syscall1(SYS_TIME, 0);
}

pub fn luaPrint(args: []Value) Value {
    for (args, 0..) |arg, i| {
        if (i > 0) {
            vgaWriteKernel("\t");
        }
        switch (arg.type) {
            .nil => vgaWriteKernel("nil"),
            .boolean => {
                if (arg.boolean_val) {
                    vgaWriteKernel("true");
                } else {
                    vgaWriteKernel("false");
                }
            },
            .number => {
                var buf: [32]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{arg.number_val}) catch "error";
                vgaWriteKernel(str);
            },
            .string => {
                const str = arg.string_val orelse "";
                vgaWriteKernel(str);
            },
            else => vgaWriteKernel("<value>"),
        }
    }
    vgaWriteKernel("\n");
    return Value.nil();
}

pub fn luaType(args: []Value) Value {
    if (args.len == 0) return Value.nil();
    const type_name = switch (args[0].type) {
        .nil => "nil",
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .table => "table",
        .function, .native_fn, .closure => "function",
    };
    return Value.fromString(type_name);
}

pub fn luaToString(args: []Value) Value {
    if (args.len == 0) return Value.fromString("");
    switch (args[0].type) {
        .nil => return Value.fromString("nil"),
        .boolean => {
            if (args[0].boolean_val) return Value.fromString("true");
            return Value.fromString("false");
        },
        .number => {
            var buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{args[0].number_val}) catch "error";
            return Value.fromString(str);
        },
        .string => return args[0],
        else => return Value.fromString("<value>"),
    }
}

pub fn luaToNumber(args: []Value) Value {
    if (args.len == 0) return Value.nil();
    switch (args[0].type) {
        .number => return args[0],
        .string => {
            const str = args[0].string_val orelse return Value.nil();
            const num = std.fmt.parseFloat(f64, str) catch return Value.nil();
            return Value.fromNumber(num);
        },
        else => return Value.nil(),
    }
}

pub fn luaVgaWrite(args: []Value) Value {
    if (args.len == 0) return Value.nil();
    switch (args[0].type) {
        .string => {
            const str = args[0].string_val orelse "";
            vgaWriteKernel(str);
        },
        else => {},
    }
    return Value.nil();
}

pub fn luaSerialWrite(args: []Value) Value {
    if (args.len == 0) return Value.nil();
    switch (args[0].type) {
        .string => {
            const str = args[0].string_val orelse "";
            serialWriteKernel(str);
        },
        else => {},
    }
    return Value.nil();
}

pub fn luaSleep(args: []Value) Value {
    if (args.len == 0) return Value.nil();
    switch (args[0].type) {
        .number => {
            const ms = @as(u64, @intFromFloat(args[0].number_val));
            sleepKernel(ms);
        },
        else => {},
    }
    return Value.nil();
}

pub fn luaReadKey(args: []Value) Value {
    _ = args;
    var buf: [1]u8 = undefined;
    const count = readFromStdin(&buf);
    if (count > 0) {
        return Value.fromString(buf[0..1]);
    }
    return Value.nil();
}

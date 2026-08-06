const std = @import("std");
const ValueMod = @import("value.zig");
const Value = ValueMod.Value;

// Lua API runs in kernel mode — call kernel subsystems directly.
// No syscall instruction needed (that's only for ring-3 user programs).
const vga = @import("root").vga;
const serial = @import("root").serial;
const timer = @import("../drivers/timer.zig");
const kb = @import("../drivers/keyboard.zig");

fn vgaWriteKernel(str: []const u8) void {
    vga.write(str);
}

fn serialWriteKernel(str: []const u8) void {
    serial.serialWrite(str);
}

fn sleepKernel(ms: u64) void {
    timer.sleep(@intCast(ms));
}

fn getTimeKernel() u64 {
    timer.updateTime();
    return @as(u64, timer.hours) * 3600 + @as(u64, timer.minutes) * 60 + @as(u64, timer.seconds);
}

fn readKeyKernel() ?u8 {
    return kb.pollKey();
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
            .function, .native_fn, .closure, .lua_func => vgaWriteKernel("<function>"),
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
        .function, .native_fn, .closure, .lua_func => "function",
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
        .function, .native_fn, .closure, .lua_func => return Value.fromString("<function>"),
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
    // Poll keyboard — returns ASCII code as number, or nil if no key pressed.
    // Lua code: local ch = read_key(); if ch then vga_write(tostring(ch)) end
    if (readKeyKernel()) |ch| {
        return Value.fromNumber(@floatFromInt(ch));
    }
    return Value.nil();
}

// Additional Lua standard library functions
pub fn luaTime(args: []Value) Value {
    _ = args;
    return Value.fromNumber(@floatFromInt(getTimeKernel()));
}

pub fn luaError(args: []Value) Value {
    if (args.len > 0 and args[0].type == .string) {
        vgaWriteKernel("error: ");
        vgaWriteKernel(args[0].string_val orelse "(nil)");
        vgaWriteKernel("\n");
    }
    return Value.nil();
}

pub fn luaAssert(args: []Value) Value {
    if (args.len == 0 or !args[0].isTruthy()) {
        vgaWriteKernel("assertion failed!\n");
    }
    if (args.len > 0) return args[0];
    return Value.nil();
}

pub fn luaIpairs(args: []Value) Value {
    _ = args;
    // Stub — not fully implemented
    return Value.nil();
}

pub fn luaPairs(args: []Value) Value {
    _ = args;
    // Stub — not fully implemented
    return Value.nil();
}

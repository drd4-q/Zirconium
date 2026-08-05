const std = @import("std");
const root = @import("root");
const vga = root.vga;
const port = root.serial;
const vm_mod = @import("../lua/vm.zig");
const parser_mod = @import("../lua/parser.zig");
const ast_mod = @import("../lua/ast.zig");
const value_mod = @import("../lua/value.zig");
const Value = value_mod.Value;

var vm: ?vm_mod.VM = null;
var arena: std.heap.ArenaAllocator = undefined;

fn initLua() void {
    var gpa = std.heap.FixedBufferAllocator.init(&_heap_buf);
    arena = std.heap.ArenaAllocator.init(gpa.allocator());
    vm = vm_mod.VM.init(arena.allocator());
}

var _heap_buf: [65536]u8 = [_]u8{0} ** 65536;

fn printBanner() void {
    vga.setColor(.light_cyan, .black);
    vga.write("  Lua 5.x (zig port) — Bare-metal kernel REPL\n");
    vga.write("  Type 'exit' to return to shell\n");
    vga.write("  Kernel API: print(), vga_write(), serial_write(), sleep(), read_key()\n\n");
    vga.setColor(.white, .black);
}

fn printError(msg: []const u8) void {
    vga.setColor(.light_red, .black);
    vga.write("  Error: ");
    vga.write(msg);
    vga.write("\n");
    vga.setColor(.white, .black);
}

fn printResult(val: Value) void {
    vga.setColor(.light_green, .black);
    vga.write("  => ");
    switch (val.type) {
        .nil => vga.write("nil"),
        .boolean => {
            if (val.boolean_val) {
                vga.write("true");
            } else {
                vga.write("false");
            }
        },
        .number => {
            var buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{val.number_val}) catch "error";
            vga.write(str);
        },
        .string => {
            const str = val.string_val orelse "";
            vga.write("'");
            vga.write(str);
            vga.write("'");
        },
        else => vga.write("<value>"),
    }
    vga.write("\n");
    vga.setColor(.white, .black);
}

pub fn run() void {
    if (vm == null) {
        initLua();
    }

    vga.clear();
    printBanner();

    var cmd_buf: [1024]u8 = undefined;
    var cmd_len: usize = 0;

    while (true) {
        vga.setColor(.light_green, .black);
        vga.write("lua> ");
        vga.setColor(.white, .black);

        cmd_len = readLine(&cmd_buf, 1024);
        if (cmd_len == 0) continue;

        const input = cmd_buf[0..cmd_len];

        // Check for exit
        if (std.mem.eql(u8, input, "exit") or std.mem.eql(u8, input, "quit")) {
            vga.setColor(.yellow, .black);
            vga.write("  Goodbye!\n");
            vga.setColor(.white, .black);
            return;
        }

        // Parse and evaluate
        var parser = parser_mod.Parser.init(input, arena.allocator());
        const stmts = parser.parse() catch |err| {
            switch (err) {
                error.SyntaxError => printError("Syntax error"),
                error.OutOfMemory => printError("Out of memory"),
            }
            continue;
        };

        const result = vm.?.eval(stmts) catch |err| {
            switch (err) {
                error.TypeError => printError("Type error"),
                error.RuntimeError => printError("Runtime error"),
                error.DivisionByZero => printError("Division by zero"),
                error.Overflow => printError("Overflow"),
                error.OutOfMemory => printError("Out of memory"),
            }
            continue;
        };

        printResult(result);
    }
}

fn readLine(buf: []u8, max_len: usize) usize {
    var pos: usize = 0;
    while (pos < max_len) {
        if (readKey()) |ch| {
            if (ch == '\n' or ch == '\r') {
                vga.putChar('\n');
                return pos;
            } else if (ch == 0x08) { // backspace
                if (pos > 0) {
                    pos -= 1;
                    vga.putChar(0x08);
                    vga.putChar(' ');
                    vga.putChar(0x08);
                }
            } else if (ch >= 0x20 and ch < 0x7F) {
                buf[pos] = ch;
                pos += 1;
                vga.putChar(ch);
            }
        } else {
            asm volatile ("hlt");
        }
    }
    return pos;
}

fn readKey() ?u8 {
    // Use the keyboard driver directly for now
    const kb = @import("../drivers/keyboard.zig");
    return kb.pollKey();
}

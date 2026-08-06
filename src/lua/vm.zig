const std = @import("std");
const ast = @import("ast.zig");
const ValueMod = @import("value.zig");
const Value = ValueMod.Value;
const Table = ValueMod.Table;
const Api = @import("api.zig");

pub const VMError = error{
    OutOfMemory,
    TypeError,
    RuntimeError,
    DivisionByZero,
    Overflow,
};

pub const VM = struct {
    globals: Table,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VM {
        var globals = Table.init(allocator) orelse unreachable;

        // === Core functions ===
        globals.set(Value.fromString("print"),   Value.fromNativeFn(&Api.luaPrint),   allocator);
        globals.set(Value.fromString("type"),    Value.fromNativeFn(&Api.luaType),    allocator);
        globals.set(Value.fromString("tostring"),Value.fromNativeFn(&Api.luaToString),allocator);
        globals.set(Value.fromString("tonumber"),Value.fromNativeFn(&Api.luaToNumber),allocator);
        globals.set(Value.fromString("assert"),  Value.fromNativeFn(&Api.luaAssert),  allocator);
        globals.set(Value.fromString("error"),   Value.fromNativeFn(&Api.luaError),   allocator);
        globals.set(Value.fromString("ipairs"),  Value.fromNativeFn(&Api.luaIpairs),  allocator);
        globals.set(Value.fromString("pairs"),   Value.fromNativeFn(&Api.luaPairs),   allocator);

        // === Kernel API ===
        globals.set(Value.fromString("vga_write"),   Value.fromNativeFn(&Api.luaVgaWrite),   allocator);
        globals.set(Value.fromString("serial_write"), Value.fromNativeFn(&Api.luaSerialWrite), allocator);
        globals.set(Value.fromString("sleep"),        Value.fromNativeFn(&Api.luaSleep),       allocator);
        globals.set(Value.fromString("read_key"),     Value.fromNativeFn(&Api.luaReadKey),     allocator);
        globals.set(Value.fromString("time"),         Value.fromNativeFn(&Api.luaTime),        allocator);

        // === math table ===
        const math_table = allocator.create(Table) catch unreachable;
        math_table.* = Table.init(allocator) orelse unreachable;
        math_table.set(Value.fromString("floor"),  Value.fromNativeFn(&luaMathFloor),  allocator);
        math_table.set(Value.fromString("ceil"),   Value.fromNativeFn(&luaMathCeil),   allocator);
        math_table.set(Value.fromString("abs"),    Value.fromNativeFn(&luaMathAbs),    allocator);
        math_table.set(Value.fromString("sqrt"),   Value.fromNativeFn(&luaMathSqrt),   allocator);
        math_table.set(Value.fromString("max"),    Value.fromNativeFn(&luaMathMax),    allocator);
        math_table.set(Value.fromString("min"),    Value.fromNativeFn(&luaMathMin),    allocator);
        math_table.set(Value.fromString("pi"),     Value.fromNumber(3.14159265358979), allocator);
        math_table.set(Value.fromString("huge"),   Value.fromNumber(std.math.inf(f64)), allocator);
        globals.set(Value.fromString("math"), Value.fromTable(math_table), allocator);

        // === string table ===
        const str_table = allocator.create(Table) catch unreachable;
        str_table.* = Table.init(allocator) orelse unreachable;
        str_table.set(Value.fromString("len"),  Value.fromNativeFn(&luaStringLen),  allocator);
        str_table.set(Value.fromString("sub"),  Value.fromNativeFn(&luaStringSub),  allocator);
        str_table.set(Value.fromString("rep"),  Value.fromNativeFn(&luaStringRep),  allocator);
        str_table.set(Value.fromString("upper"),Value.fromNativeFn(&luaStringUpper),allocator);
        str_table.set(Value.fromString("lower"),Value.fromNativeFn(&luaStringLower),allocator);
        globals.set(Value.fromString("string"), Value.fromTable(str_table), allocator);

        return .{
            .globals = globals,
            .allocator = allocator,
        };
    }


    pub fn eval(self: *VM, stmts: []ast.Stmt) VMError!Value {
        var result = Value.nil();
        for (stmts) |stmt| {
            result = try self.execStmt(stmt);
        }
        return result;
    }

    fn execStmt(self: *VM, stmt: ast.Stmt) VMError!Value {
        return switch (stmt) {
            .expression => |expr| self.evalExpr(expr),
            .assignment => |a| blk: {
                for (a.values, 0..) |val_expr, i| {
                    const val = try self.evalExpr(val_expr);
                    if (i < a.targets.len) {
                        try self.setVariable(a.targets[i], val);
                    }
                }
                break :blk Value.nil();
            },
            .local_assignment => |la| blk: {
                for (la.values, 0..) |val_expr, i| {
                    const val = try self.evalExpr(val_expr);
                    if (i < la.names.len) {
                        self.globals.set(Value.fromString(la.names[i]), val, self.allocator);
                    }
                }
                break :blk Value.nil();
            },
            .if_stmt => |if_stmt| blk: {
                const cond = try self.evalExpr(if_stmt.condition);
                if (cond.isTruthy()) {
                    break :blk try self.execBlock(if_stmt.then_body);
                }
                for (if_stmt.elseif_clauses) |elif| {
                    const elif_cond = try self.evalExpr(elif.condition);
                    if (elif_cond.isTruthy()) {
                        break :blk try self.execBlock(elif.body);
                    }
                }
                if (if_stmt.else_body) |else_body| {
                    break :blk try self.execBlock(else_body);
                }
                break :blk Value.nil();
            },
            .while_stmt => |ws| blk: {
                while (true) {
                    const cond = try self.evalExpr(ws.condition);
                    if (!cond.isTruthy()) break;
                    const result = try self.execBlock(ws.body);
                    if (result.type == .number and result.number_val == -1) { // break sentinel
                        break;
                    }
                }
                break :blk Value.nil();
            },
            .repeat_stmt => |rs| blk: {
                while (true) {
                    const result = try self.execBlock(rs.body);
                    if (result.type == .number and result.number_val == -1) break;
                    const cond = try self.evalExpr(rs.condition);
                    if (cond.isTruthy()) break;
                }
                break :blk Value.nil();
            },
            .for_num_stmt => |fs| blk: {
                const start = try self.evalExpr(fs.start_val);
                const end = try self.evalExpr(fs.end_val);
                var step: f64 = 1;
                if (fs.step_val) |step_expr| {
                    const s = try self.evalExpr(step_expr);
                    step = s.number_val;
                }
                var i = start.number_val;
                const limit = end.number_val;
                while (if (step > 0) i <= limit else i >= limit) {
                    self.globals.set(Value.fromString(fs.var_name), Value.fromNumber(i), self.allocator);
                    const result = try self.execBlock(fs.body);
                    if (result.type == .number and result.number_val == -1) break;
                    i += step;
                }
                break :blk Value.nil();
            },
            .for_in_stmt => |fs| blk: {
                // Simplified: just evaluate iterators and run body once
                for (fs.iterators) |iter_expr| {
                    _ = try self.evalExpr(iter_expr);
                }
                break :blk try self.execBlock(fs.body);
            },
            .function_def => |fd| blk: {
                // Anonymous function — store as LuaFunc value
                const lf = self.allocator.create(LuaFunc) catch break :blk Value.nil();
                lf.* = .{ .params = fd.params, .body = fd.body };
                break :blk Value.fromLuaFunc(lf);
            },
            .local_function_def => |lfd| blk: {
                // Named local function — store in globals
                const lf = self.allocator.create(LuaFunc) catch break :blk Value.nil();
                lf.* = .{ .params = lfd.params, .body = lfd.body };
                const fn_val = Value.fromLuaFunc(lf);
                self.globals.set(Value.fromString(lfd.name), fn_val, self.allocator);
                break :blk Value.nil();
            },

            .return_stmt => |rs| blk: {
                if (rs.len > 0) {
                    break :blk try self.evalExpr(rs[0]);
                }
                break :blk Value.nil();
            },
            .break_stmt => Value.fromNumber(-1), // sentinel
            .empty => Value.nil(),
            else => Value.nil(),
        };
    }

    fn execBlock(self: *VM, stmts: []ast.Stmt) VMError!Value {
        var result = Value.nil();
        for (stmts) |stmt| {
            result = try self.execStmt(stmt);
            if (result.type == .number and result.number_val == -1) return result; // break
        }
        return result;
    }

    fn evalExpr(self: *VM, expr: ast.Expr) VMError!Value {
        return switch (expr) {
            .nil => Value.nil(),
            .boolean => |b| Value.fromBool(b),
            .number => |n| Value.fromNumber(n),
            .string => |s| Value.fromString(s),
            .identifier => |name| self.getVariable(name),
            .binary_op => |op| blk: {
                const left = try self.evalExpr(op.left.*);
                const right = try self.evalExpr(op.right.*);
                break :blk try self.evalBinaryOp(op.op, left, right);
            },
            .unary_op => |op| blk: {
                const operand = try self.evalExpr(op.operand.*);
                break :blk try self.evalUnaryOp(op.op, operand);
            },
            .function_call => |fc| blk: {
                const base = try self.evalExpr(fc.base.*);
                var args: [32]Value = undefined;
                var arg_count: usize = 0;
                for (fc.args) |arg| {
                    if (arg_count >= 32) break;
                    args[arg_count] = try self.evalExpr(arg);
                    arg_count += 1;
                }
                break :blk try self.callFunction(base, args[0..arg_count]);
            },
            .table_constructor => |fields| blk: {
                const table = self.allocator.create(Table) catch break :blk Value.nil();
                table.* = Table.init(self.allocator) orelse break :blk Value.nil();
                var array_idx: f64 = 1;
                for (fields) |field| {
                    const val = try self.evalExpr(field.value);
                    if (field.key) |key| {
                        const k = try self.evalExpr(key);
                        table.set(k, val, self.allocator);
                    } else {
                        table.set(Value.fromNumber(array_idx), val, self.allocator);
                        array_idx += 1;
                    }
                }
                break :blk Value.fromTable(table);
            },
            .method_call => |mc| blk: {
                // table:method(args) => look up method in table, call with table as first arg
                const base_val = try self.evalExpr(mc.base.*);
                var method_val = Value.nil();
                if (base_val.type == .table) {
                    if (base_val.table_val) |t| {
                        method_val = t.get(Value.fromString(mc.method)) orelse Value.nil();
                    }
                }
                var args: [33]Value = undefined;
                args[0] = base_val; // self
                var arg_count: usize = 1;
                for (mc.args) |arg| {
                    if (arg_count >= 33) break;
                    args[arg_count] = try self.evalExpr(arg);
                    arg_count += 1;
                }
                break :blk try self.callFunction(method_val, args[0..arg_count]);
            },
        };
    }

    fn evalBinaryOp(self: *VM, op: ast.Op, left: Value, right: Value) VMError!Value {
        switch (op) {
            .add => {
                if (left.type == .number and right.type == .number)
                    return Value.fromNumber(left.number_val + right.number_val);
                if (left.type == .string and right.type == .string) {
                    // String concatenation
                    const left_str = left.string_val orelse "";
                    const right_str = right.string_val orelse "";
                    const total_len = left_str.len + right_str.len;
                    var buf = self.allocator.alloc(u8, total_len) catch return VMError.OutOfMemory;
                    @memcpy(buf[0..left_str.len], left_str);
                    @memcpy(buf[left_str.len..], right_str);
                    return Value.fromString(buf);
                }
                return VMError.TypeError;
            },
            .sub => {
                if (left.type == .number and right.type == .number)
                    return Value.fromNumber(left.number_val - right.number_val);
                return VMError.TypeError;
            },
            .mul => {
                if (left.type == .number and right.type == .number)
                    return Value.fromNumber(left.number_val * right.number_val);
                return VMError.TypeError;
            },
            .div => {
                if (left.type == .number and right.type == .number) {
                    if (right.number_val == 0) return VMError.DivisionByZero;
                    return Value.fromNumber(left.number_val / right.number_val);
                }
                return VMError.TypeError;
            },
            .mod => {
                if (left.type == .number and right.type == .number) {
                    if (right.number_val == 0) return VMError.DivisionByZero;
                    return Value.fromNumber(@mod(left.number_val, right.number_val));
                }
                return VMError.TypeError;
            },
            .pow => {
                if (left.type == .number and right.type == .number)
                    return Value.fromNumber(std.math.pow(f64, left.number_val, right.number_val));
                return VMError.TypeError;
            },
            .eq => return Value.fromBool(left.equals(right)),
            .ne => return Value.fromBool(!left.equals(right)),
            .lt => {
                if (left.type == .number and right.type == .number)
                    return Value.fromBool(left.number_val < right.number_val);
                if (left.type == .string and right.type == .string) {
                    const l = left.string_val orelse "";
                    const r = right.string_val orelse "";
                    return Value.fromBool(std.mem.order(u8, l, r) == .lt);
                }
                return VMError.TypeError;
            },
            .le => {
                if (left.type == .number and right.type == .number)
                    return Value.fromBool(left.number_val <= right.number_val);
                return VMError.TypeError;
            },
            .gt => {
                if (left.type == .number and right.type == .number)
                    return Value.fromBool(left.number_val > right.number_val);
                return VMError.TypeError;
            },
            .ge => {
                if (left.type == .number and right.type == .number)
                    return Value.fromBool(left.number_val >= right.number_val);
                return VMError.TypeError;
            },
            .and_op => return if (left.isTruthy()) right else left,
            .or_op => return if (left.isTruthy()) left else right,
            .concat => {
                if (left.type == .string and right.type == .string) {
                    const left_str = left.string_val orelse "";
                    const right_str = right.string_val orelse "";
                    const total_len = left_str.len + right_str.len;
                    var buf = self.allocator.alloc(u8, total_len) catch return VMError.OutOfMemory;
                    @memcpy(buf[0..left_str.len], left_str);
                    @memcpy(buf[left_str.len..], right_str);
                    return Value.fromString(buf);
                }
                return VMError.TypeError;
            },
            .length => {
                if (left.type == .string) {
                    const str = left.string_val orelse "";
                    return Value.fromNumber(@floatFromInt(str.len));
                }
                return Value.fromNumber(0);
            },
            else => return VMError.TypeError,
        }
    }

    fn evalUnaryOp(_: *VM, op: ast.Op, operand: Value) VMError!Value {
        switch (op) {
            .negate => {
                if (operand.type == .number)
                    return Value.fromNumber(-operand.number_val);
                return VMError.TypeError;
            },
            .not => return Value.fromBool(!operand.isTruthy()),
            .length => {
                if (operand.type == .string) {
                    const str = operand.string_val orelse "";
                    return Value.fromNumber(@floatFromInt(str.len));
                }
                return Value.fromNumber(0);
            },
            else => return VMError.TypeError,
        }
    }

    fn getVariable(self: *VM, name: []const u8) Value {
        if (self.globals.get(Value.fromString(name))) |val| {
            return val;
        }
        return Value.nil();
    }

    fn setVariable(self: *VM, target: ast.Expr, value: Value) VMError!void {
        switch (target) {
            .identifier => |name| {
                self.globals.set(Value.fromString(name), value, self.allocator);
            },
            else => {},
        }
    }

    fn callFunction(self: *VM, func: Value, args: []Value) VMError!Value {
        switch (func.type) {
            .native_fn => {
                if (func.native_fn_val) |f| {
                    return f(args);
                }
                return Value.nil();
            },
            .lua_func => {
                // Call a user-defined Lua function
                if (func.lua_func_val) |lf_opaque| {
                    const lf: *LuaFunc = @ptrCast(@alignCast(lf_opaque));
                    // Save old globals state by creating a local scope overlay
                    // (simple approach: bind params into globals, save/restore old values)
                    var saved: [32]struct { name: []const u8, val: Value } = undefined;
                    const param_count = @min(lf.params.len, args.len);
                    var saved_count: usize = 0;

                    // Bind parameters
                    var i: usize = 0;
                    while (i < param_count) : (i += 1) {
                        saved[saved_count] = .{
                            .name = lf.params[i],
                            .val = self.globals.get(Value.fromString(lf.params[i])) orelse Value.nil(),
                        };
                        saved_count += 1;
                        self.globals.set(Value.fromString(lf.params[i]), args[i], self.allocator);
                    }
                    // Bind missing params to nil
                    while (i < lf.params.len) : (i += 1) {
                        saved[saved_count] = .{
                            .name = lf.params[i],
                            .val = self.globals.get(Value.fromString(lf.params[i])) orelse Value.nil(),
                        };
                        saved_count += 1;
                        self.globals.set(Value.fromString(lf.params[i]), Value.nil(), self.allocator);
                    }

                    const result = self.execBlock(lf.body) catch |err| {
                        // Restore params on error
                        var j: usize = 0;
                        while (j < saved_count) : (j += 1) {
                            self.globals.set(Value.fromString(saved[j].name), saved[j].val, self.allocator);
                        }
                        return err;
                    };

                    // Restore param bindings
                    var j: usize = 0;
                    while (j < saved_count) : (j += 1) {
                        self.globals.set(Value.fromString(saved[j].name), saved[j].val, self.allocator);
                    }

                    return result;
                }
                return Value.nil();
            },
            else => {},
        }
        return Value.nil();
    }
};

// ==============================
// LuaFunc — user-defined function
// ==============================
pub const LuaFunc = struct {
    params: []const []const u8,
    body: []ast.Stmt,
};

// ==============================
// math.* native implementations
// ==============================
fn luaMathFloor(args: []Value) Value {
    if (args.len == 0 or args[0].type != .number) return Value.nil();
    return Value.fromNumber(@floor(args[0].number_val));
}
fn luaMathCeil(args: []Value) Value {
    if (args.len == 0 or args[0].type != .number) return Value.nil();
    return Value.fromNumber(@ceil(args[0].number_val));
}
fn luaMathAbs(args: []Value) Value {
    if (args.len == 0 or args[0].type != .number) return Value.nil();
    return Value.fromNumber(@abs(args[0].number_val));
}
fn luaMathSqrt(args: []Value) Value {
    if (args.len == 0 or args[0].type != .number) return Value.nil();
    return Value.fromNumber(std.math.sqrt(args[0].number_val));
}
fn luaMathMax(args: []Value) Value {
    if (args.len == 0) return Value.nil();
    var m = args[0].number_val;
    for (args[1..]) |a| {
        if (a.type == .number and a.number_val > m) m = a.number_val;
    }
    return Value.fromNumber(m);
}
fn luaMathMin(args: []Value) Value {
    if (args.len == 0) return Value.nil();
    var m = args[0].number_val;
    for (args[1..]) |a| {
        if (a.type == .number and a.number_val < m) m = a.number_val;
    }
    return Value.fromNumber(m);
}

// ==============================
// string.* native implementations
// ==============================
fn luaStringLen(args: []Value) Value {
    if (args.len == 0 or args[0].type != .string) return Value.fromNumber(0);
    const s = args[0].string_val orelse "";
    return Value.fromNumber(@floatFromInt(s.len));
}
fn luaStringSub(args: []Value) Value {
    if (args.len < 2 or args[0].type != .string) return Value.nil();
    const s = args[0].string_val orelse "";
    const i_raw: isize = @intFromFloat(args[1].number_val);
    const j_raw: isize = if (args.len >= 3 and args[2].type == .number)
        @intFromFloat(args[2].number_val)
    else
        @intCast(s.len);
    const len: isize = @intCast(s.len);
    const i: usize = @intCast(@max(0, if (i_raw < 0) len + i_raw else i_raw - 1));
    const j: usize = @intCast(@min(len, if (j_raw < 0) len + j_raw + 1 else j_raw));
    if (i >= j or i >= s.len) return Value.fromString("");
    return Value.fromString(s[i..@min(j, s.len)]);
}
fn luaStringRep(args: []Value) Value {
    _ = args;
    // Stub — requires allocator, skip for now
    return Value.fromString("");
}
fn luaStringUpper(args: []Value) Value {
    _ = args;
    return Value.fromString(""); // Stub
}
fn luaStringLower(args: []Value) Value {
    _ = args;
    return Value.fromString(""); // Stub
}

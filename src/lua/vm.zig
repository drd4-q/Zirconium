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
        // Register built-in functions
        const print_val = Value.fromNativeFn(&Api.luaPrint);
        globals.set(Value.fromString("print"), print_val, allocator);
        const type_val = Value.fromNativeFn(&Api.luaType);
        globals.set(Value.fromString("type"), type_val, allocator);
        const tostring_val = Value.fromNativeFn(&Api.luaToString);
        globals.set(Value.fromString("tostring"), tostring_val, allocator);
        const tonumber_val = Value.fromNativeFn(&Api.luaToNumber);
        globals.set(Value.fromString("tonumber"), tonumber_val, allocator);
        const vga_write_val = Value.fromNativeFn(&Api.luaVgaWrite);
        globals.set(Value.fromString("vga_write"), vga_write_val, allocator);
        const serial_write_val = Value.fromNativeFn(&Api.luaSerialWrite);
        globals.set(Value.fromString("serial_write"), serial_write_val, allocator);
        const sleep_val = Value.fromNativeFn(&Api.luaSleep);
        globals.set(Value.fromString("sleep"), sleep_val, allocator);
        const read_key_val = Value.fromNativeFn(&Api.luaReadKey);
        globals.set(Value.fromString("read_key"), read_key_val, allocator);

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
            .function_def => blk: {
                // Function definitions are treated as expressions for now
                break :blk Value.nil();
            },
            .local_function_def => |lfd| blk: {
                self.globals.set(Value.fromString(lfd.name), Value.nil(), self.allocator);
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
                const base = try self.evalExpr(mc.base.*);
                _ = mc.method;
                _ = mc.args;
                break :blk base;
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

    fn callFunction(_: *VM, func: Value, args: []Value) VMError!Value {
        switch (func.type) {
            .native_fn => {
                if (func.native_fn_val) |f| {
                    return f(args);
                }
                return Value.nil();
            },
            else => {},
        }
        return Value.nil();
    }
};

const std = @import("std");
const LexerMod = @import("lexer.zig");
const Lexer = LexerMod.Lexer;
const Token = LexerMod.Token;
const TokenType = LexerMod.TokenType;
const ast = @import("ast.zig");

pub const ParserError = error{
    OutOfMemory,
    SyntaxError,
};

pub const Parser = struct {
    lexer: Lexer,
    current: Token,
    allocator: std.mem.Allocator,

    pub fn init(source: []const u8, allocator: std.mem.Allocator) Parser {
        var lexer = Lexer.init(source);
        const first_token = lexer.nextToken();
        return .{
            .lexer = lexer,
            .current = first_token,
            .allocator = allocator,
        };
    }

    fn advance(self: *Parser) void {
        self.current = self.lexer.nextToken();
    }

    fn expect(self: *Parser, expected: TokenType) ParserError!void {
        if (self.current.type != expected) {
            return ParserError.SyntaxError;
        }
        self.advance();
    }

    fn peek(self: *Parser) TokenType {
        return self.current.type;
    }

    fn matchToken(self: *Parser, expected: TokenType) bool {
        if (self.current.type == expected) {
            self.advance();
            return true;
        }
        return false;
    }

    pub fn parseExpression(self: *Parser) ParserError!ast.Expr {
        return self.parseSubOrExpr();
    }

    fn parseSubOrExpr(self: *Parser) ParserError!ast.Expr {
        var left = try self.parseConcatExpr();
        while (self.peek() == .plus or self.peek() == .minus) {
            const op: ast.Op = if (self.peek() == .plus) .add else .sub;
            self.advance();
            const right = try self.parseConcatExpr();
            const left_ptr = self.allocator.create(ast.Expr) catch return ParserError.OutOfMemory;
            left_ptr.* = left;
            const right_ptr = self.allocator.create(ast.Expr) catch return ParserError.OutOfMemory;
            right_ptr.* = right;
            left = .{ .binary_op = .{ .op = op, .left = left_ptr, .right = right_ptr } };
        }
        return left;
    }

    fn parseConcatExpr(self: *Parser) ParserError!ast.Expr {
        var left = try self.parseMulExpr();
        while (self.peek() == .caret) {
            self.advance();
            const right = try self.parseMulExpr();
            const left_ptr = self.allocator.create(ast.Expr) catch return ParserError.OutOfMemory;
            left_ptr.* = left;
            const right_ptr = self.allocator.create(ast.Expr) catch return ParserError.OutOfMemory;
            right_ptr.* = right;
            left = .{ .binary_op = .{ .op = .pow, .left = left_ptr, .right = right_ptr } };
        }
        return left;
    }

    fn parseMulExpr(self: *Parser) ParserError!ast.Expr {
        var left = try self.parseUnaryExpr();
        while (self.peek() == .star or self.peek() == .slash or self.peek() == .percent) {
            const op: ast.Op = switch (self.peek()) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                else => unreachable,
            };
            self.advance();
            const right = try self.parseUnaryExpr();
            const left_ptr = self.allocator.create(ast.Expr) catch return ParserError.OutOfMemory;
            left_ptr.* = left;
            const right_ptr = self.allocator.create(ast.Expr) catch return ParserError.OutOfMemory;
            right_ptr.* = right;
            left = .{ .binary_op = .{ .op = op, .left = left_ptr, .right = right_ptr } };
        }
        return left;
    }

    fn parseUnaryExpr(self: *Parser) ParserError!ast.Expr {
        if (self.peek() == .minus) {
            self.advance();
            const operand = try self.parseUnaryExpr();
            const operand_ptr = self.allocator.create(ast.Expr) catch return ParserError.OutOfMemory;
            operand_ptr.* = operand;
            return .{ .unary_op = .{ .op = .negate, .operand = operand_ptr } };
        }
        if (self.peek() == .keyword_not) {
            self.advance();
            const operand = try self.parseUnaryExpr();
            const operand_ptr = self.allocator.create(ast.Expr) catch return ParserError.OutOfMemory;
            operand_ptr.* = operand;
            return .{ .unary_op = .{ .op = .not, .operand = operand_ptr } };
        }
        if (self.peek() == .hash) {
            self.advance();
            const operand = try self.parseUnaryExpr();
            const operand_ptr = self.allocator.create(ast.Expr) catch return ParserError.OutOfMemory;
            operand_ptr.* = operand;
            return .{ .unary_op = .{ .op = .length, .operand = operand_ptr } };
        }
        return self.parsePrimaryExpr();
    }

    fn parsePrimaryExpr(self: *Parser) ParserError!ast.Expr {
        return switch (self.peek()) {
            .keyword_nil => blk: {
                self.advance();
                break :blk .nil;
            },
            .keyword_true => blk: {
                self.advance();
                break :blk .{ .boolean = true };
            },
            .keyword_false => blk: {
                self.advance();
                break :blk .{ .boolean = false };
            },
            .number_literal => blk: {
                const text = self.lexer.getTokenText(self.current);
                self.advance();
                const num = std.fmt.parseFloat(f64, text) catch 0;
                break :blk .{ .number = num };
            },
            .string_literal => blk: {
                const text = self.lexer.getTokenText(self.current);
                self.advance();
                break :blk .{ .string = text };
            },
            .identifier => blk: {
                const text = self.lexer.getTokenText(self.current);
                self.advance();
                break :blk .{ .identifier = text };
            },
            .left_paren => blk: {
                self.advance();
                const expr = try self.parseExpression();
                try self.expect(.right_paren);
                break :blk expr;
            },
            .left_brace => blk: {
                break :blk try self.parseTableConstructor();
            },
            .keyword_function => blk: {
                self.advance();
                break :blk try self.parseFunctionExpr();
            },
            else => return ParserError.SyntaxError,
        };
    }

    fn parseTableConstructor(self: *Parser) ParserError!ast.Expr {
        self.advance(); // skip {
        var fields: [64]ast.TableField = undefined;
        var field_count: usize = 0;

        while (self.peek() != .right_brace and self.peek() != .eof) {
            if (field_count >= 64) break;
            const field = try self.parseTableField();
            fields[field_count] = field;
            field_count += 1;
            _ = self.matchToken(.comma);
            _ = self.matchToken(.semicolon);
        }
        try self.expect(.right_brace);

        const fields_slice = self.allocator.dupe(ast.TableField, fields[0..field_count]) catch return ParserError.OutOfMemory;
        return .{ .table_constructor = fields_slice };
    }

    fn parseTableField(self: *Parser) ParserError!ast.TableField {
        if (self.peek() == .left_bracket) {
            self.advance();
            const key = try self.parseExpression();
            try self.expect(.right_bracket);
            try self.expect(.assign);
            const value = try self.parseExpression();
            return .{ .key = key, .value = value };
        }
        if (self.peek() == .identifier) {
            // Check if next token is = (assignment) - if so, treat as key=value
            const key_text = self.lexer.getTokenText(self.current);
            // Peek ahead to see if this is key = value
            const saved = self.current;
            self.advance();
            if (self.peek() == .assign) {
                self.advance(); // skip =
                const value = try self.parseExpression();
                const key_expr = ast.Expr{ .string = key_text };
                return .{ .key = key_expr, .value = value };
            } else {
                // Not a key=value, restore and treat as expression
                self.current = saved;
            }
        }
        const value = try self.parseExpression();
        return .{ .key = null, .value = value };
    }

    fn parseFunctionExpr(self: *Parser) ParserError!ast.Expr {
        try self.expect(.left_paren);
        var params: [32][]const u8 = undefined;
        var param_count: usize = 0;

        if (self.peek() != .right_paren) {
            while (true) {
                if (self.peek() != .identifier) return ParserError.SyntaxError;
                if (param_count >= 32) return ParserError.OutOfMemory;
                params[param_count] = self.lexer.getTokenText(self.current);
                param_count += 1;
                self.advance();
                if (!self.matchToken(.comma)) break;
            }
        }
        try self.expect(.right_paren);

        const body = try self.parseBlock();
        try self.expect(.keyword_end);

        const params_slice = self.allocator.dupe([]const u8, params[0..param_count]) catch return ParserError.OutOfMemory;
        const body_copy = self.allocator.dupe(ast.Stmt, body) catch return ParserError.OutOfMemory;

        // For now, treat function expressions as returning nil
        _ = params_slice;
        _ = body_copy;
        return .nil;
    }

    pub fn parseStatement(self: *Parser) ParserError!ast.Stmt {
        return switch (self.peek()) {
            .keyword_if => self.parseIfStmt(),
            .keyword_while => self.parseWhileStmt(),
            .keyword_repeat => self.parseRepeatStmt(),
            .keyword_for => self.parseForStmt(),
            .keyword_function => self.parseFunctionDef(),
            .keyword_local => self.parseLocalStmt(),
            .keyword_return => self.parseReturnStmt(),
            .keyword_break => blk: {
                self.advance();
                break :blk ast.Stmt.break_stmt;
            },
            .identifier, .left_paren => self.parseExpressionOrAssignment(),
            else => blk: {
                self.advance();
                break :blk .empty;
            },
        };
    }

    fn parseBlock(self: *Parser) ParserError![]ast.Stmt {
        var stmts: [256]ast.Stmt = undefined;
        var stmt_count: usize = 0;

        while (self.peek() != .keyword_end and self.peek() != .keyword_else and self.peek() != .keyword_until and self.peek() != .eof) {
            if (stmt_count >= 256) break;
            const stmt = try self.parseStatement();
            stmts[stmt_count] = stmt;
            stmt_count += 1;
            _ = self.matchToken(.semicolon);
            _ = self.matchToken(.newline);
        }

        return self.allocator.dupe(ast.Stmt, stmts[0..stmt_count]) catch return ParserError.OutOfMemory;
    }

    fn parseIfStmt(self: *Parser) ParserError!ast.Stmt {
        self.advance(); // skip if
        const condition = try self.parseExpression();
        try self.expect(.keyword_then);
        const then_body = try self.parseBlock();

        var elseif_clauses: [16]ast.ElseIfClause = undefined;
        var elseif_count: usize = 0;

        var else_body: ?[]ast.Stmt = null;

        while (self.peek() == .keyword_elseif) {
            if (elseif_count >= 16) break;
            self.advance();
            const elif_cond = try self.parseExpression();
            try self.expect(.keyword_then);
            const elif_body = try self.parseBlock();
            elseif_clauses[elseif_count] = .{ .condition = elif_cond, .body = elif_body };
            elseif_count += 1;
        }

        if (self.peek() == .keyword_else) {
            self.advance();
            else_body = try self.parseBlock();
        }

        try self.expect(.keyword_end);

        const elif_slice = self.allocator.dupe(ast.ElseIfClause, elseif_clauses[0..elseif_count]) catch return ParserError.OutOfMemory;

        return .{ .if_stmt = .{
            .condition = condition,
            .then_body = then_body,
            .elseif_clauses = elif_slice,
            .else_body = else_body,
        } };
    }

    fn parseWhileStmt(self: *Parser) ParserError!ast.Stmt {
        self.advance(); // skip while
        const condition = try self.parseExpression();
        try self.expect(.keyword_do);
        const body = try self.parseBlock();
        try self.expect(.keyword_end);
        return .{ .while_stmt = .{ .condition = condition, .body = body } };
    }

    fn parseRepeatStmt(self: *Parser) ParserError!ast.Stmt {
        self.advance(); // skip repeat
        const body = try self.parseBlock();
        try self.expect(.keyword_until);
        const condition = try self.parseExpression();
        return .{ .repeat_stmt = .{ .body = body, .condition = condition } };
    }

    fn parseForStmt(self: *Parser) ParserError!ast.Stmt {
        self.advance(); // skip for
        const var_name = self.lexer.getTokenText(self.current);
        try self.expect(.identifier);

        if (self.matchToken(.assign)) {
            const start_val = try self.parseExpression();
            try self.expect(.comma);
            const end_val = try self.parseExpression();
            var step_val: ?ast.Expr = null;
            if (self.matchToken(.comma)) {
                step_val = try self.parseExpression();
            }
            try self.expect(.keyword_do);
            const body = try self.parseBlock();
            try self.expect(.keyword_end);
            return .{ .for_num_stmt = .{
                .var_name = var_name,
                .start_val = start_val,
                .end_val = end_val,
                .step_val = step_val,
                .body = body,
            } };
        } else {
            var names: [8][]const u8 = undefined;
            var name_count: usize = 0;
            names[name_count] = var_name;
            name_count += 1;
            while (self.matchToken(.comma)) {
                if (name_count >= 8) break;
                names[name_count] = self.lexer.getTokenText(self.current);
                name_count += 1;
                try self.expect(.identifier);
            }
            try self.expect(.keyword_in);
            var iterators: [8]ast.Expr = undefined;
            var iter_count: usize = 0;
            iterators[iter_count] = try self.parseExpression();
            iter_count += 1;
            while (self.matchToken(.comma)) {
                if (iter_count >= 8) break;
                iterators[iter_count] = try self.parseExpression();
                iter_count += 1;
            }
            try self.expect(.keyword_do);
            const body = try self.parseBlock();
            try self.expect(.keyword_end);

            const names_slice = self.allocator.dupe([]const u8, names[0..name_count]) catch return ParserError.OutOfMemory;
            const iter_slice = self.allocator.dupe(ast.Expr, iterators[0..iter_count]) catch return ParserError.OutOfMemory;

            return .{ .for_in_stmt = .{
                .names = names_slice,
                .iterators = iter_slice,
                .body = body,
            } };
        }
    }

    fn parseFunctionDef(self: *Parser) ParserError!ast.Stmt {
        self.advance(); // skip function
        try self.expect(.identifier); // skip function name
        try self.expect(.left_paren);
        var params: [32][]const u8 = undefined;
        var param_count: usize = 0;
        if (self.peek() != .right_paren) {
            while (true) {
                if (self.peek() != .identifier) return ParserError.SyntaxError;
                if (param_count >= 32) return ParserError.OutOfMemory;
                params[param_count] = self.lexer.getTokenText(self.current);
                param_count += 1;
                self.advance();
                if (!self.matchToken(.comma)) break;
            }
        }
        try self.expect(.right_paren);
        const body = try self.parseBlock();
        try self.expect(.keyword_end);

        const params_slice = self.allocator.dupe([]const u8, params[0..param_count]) catch return ParserError.OutOfMemory;
        const body_copy = self.allocator.dupe(ast.Stmt, body) catch return ParserError.OutOfMemory;

        return .{ .function_def = .{ .params = params_slice, .body = body_copy } };
    }

    fn parseLocalStmt(self: *Parser) ParserError!ast.Stmt {
        self.advance(); // skip local

        if (self.peek() == .keyword_function) {
            self.advance();
            const name = self.lexer.getTokenText(self.current);
            try self.expect(.identifier);
            try self.expect(.left_paren);
            var params: [32][]const u8 = undefined;
            var param_count: usize = 0;
            if (self.peek() != .right_paren) {
                while (true) {
                    if (self.peek() != .identifier) return ParserError.SyntaxError;
                    if (param_count >= 32) return ParserError.OutOfMemory;
                    params[param_count] = self.lexer.getTokenText(self.current);
                    param_count += 1;
                    self.advance();
                    if (!self.matchToken(.comma)) break;
                }
            }
            try self.expect(.right_paren);
            const body = try self.parseBlock();
            try self.expect(.keyword_end);

            const params_slice = self.allocator.dupe([]const u8, params[0..param_count]) catch return ParserError.OutOfMemory;
            const body_copy = self.allocator.dupe(ast.Stmt, body) catch return ParserError.OutOfMemory;

            return .{ .local_function_def = .{
                .name = name,
                .params = params_slice,
                .body = body_copy,
            } };
        }

        var names: [32][]const u8 = undefined;
        var name_count: usize = 0;
        names[name_count] = self.lexer.getTokenText(self.current);
        name_count += 1;
        try self.expect(.identifier);
        while (self.matchToken(.comma)) {
            if (name_count >= 32) break;
            names[name_count] = self.lexer.getTokenText(self.current);
            name_count += 1;
            try self.expect(.identifier);
        }

        var values: [32]ast.Expr = undefined;
        var value_count: usize = 0;
        if (self.matchToken(.assign)) {
            values[value_count] = try self.parseExpression();
            value_count += 1;
            while (self.matchToken(.comma)) {
                if (value_count >= 32) break;
                values[value_count] = try self.parseExpression();
                value_count += 1;
            }
        }

        const names_slice = self.allocator.dupe([]const u8, names[0..name_count]) catch return ParserError.OutOfMemory;
        const values_slice = self.allocator.dupe(ast.Expr, values[0..value_count]) catch return ParserError.OutOfMemory;

        return .{ .local_assignment = .{ .names = names_slice, .values = values_slice } };
    }

    fn parseReturnStmt(self: *Parser) ParserError!ast.Stmt {
        self.advance(); // skip return
        var values: [32]ast.Expr = undefined;
        var value_count: usize = 0;

        if (self.peek() != .keyword_end and self.peek() != .keyword_else and self.peek() != .keyword_until and self.peek() != .eof and self.peek() != .semicolon) {
            values[value_count] = try self.parseExpression();
            value_count += 1;
            while (self.matchToken(.comma)) {
                if (value_count >= 32) break;
                values[value_count] = try self.parseExpression();
                value_count += 1;
            }
        }

        const values_slice = self.allocator.dupe(ast.Expr, values[0..value_count]) catch return ParserError.OutOfMemory;
        return .{ .return_stmt = values_slice };
    }

    fn parseExpressionOrAssignment(self: *Parser) ParserError!ast.Stmt {
        const expr = try self.parseExpression();

        if (self.matchToken(.assign)) {
            var values: [32]ast.Expr = undefined;
            var value_count: usize = 0;
            values[value_count] = try self.parseExpression();
            value_count += 1;
            while (self.matchToken(.comma)) {
                if (value_count >= 32) break;
                values[value_count] = try self.parseExpression();
                value_count += 1;
            }

            var targets: [32]ast.Expr = undefined;
            var target_count: usize = 0;
            targets[target_count] = expr;
            target_count += 1;
            while (self.matchToken(.comma)) {
                if (target_count >= 32) break;
                targets[target_count] = try self.parseExpression();
                target_count += 1;
            }

            const targets_slice = self.allocator.dupe(ast.Expr, targets[0..target_count]) catch return ParserError.OutOfMemory;
            const values_slice = self.allocator.dupe(ast.Expr, values[0..value_count]) catch return ParserError.OutOfMemory;

            return .{ .assignment = .{ .targets = targets_slice, .values = values_slice } };
        }

        return .{ .expression = expr };
    }

    pub fn parse(self: *Parser) ParserError![]ast.Stmt {
        return self.parseBlock();
    }
};

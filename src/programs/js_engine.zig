const std = @import("std");
const serial = @import("../system/serial.zig");

pub const JS_MAX_VARS: usize = 32;
pub const JS_VAR_NAME_MAX: usize = 24;
pub const JS_VAR_VAL_MAX: usize = 64;

pub const JsVar = struct {
    name: [JS_VAR_NAME_MAX]u8 = undefined,
    name_len: usize = 0,
    val: [JS_VAR_VAL_MAX]u8 = undefined,
    val_len: usize = 0,
    num_val: i64 = 0,
    is_num: bool = false,
    used: bool = false,
};

pub const JsEngine = struct {
    vars: [JS_MAX_VARS]JsVar = [_]JsVar{.{}} ** JS_MAX_VARS,
    doc_write_buf: [1024]u8 = undefined,
    doc_write_len: usize = 0,
    title_override: [48]u8 = undefined,
    title_override_len: usize = 0,

    pub fn init(self: *JsEngine) void {
        for (&self.vars) |*v| {
            v.used = false;
            v.name_len = 0;
            v.val_len = 0;
            v.num_val = 0;
            v.is_num = false;
        }
        self.doc_write_len = 0;
        self.title_override_len = 0;
    }

    pub fn setVarStr(self: *JsEngine, name: []const u8, val: []const u8) void {
        for (&self.vars) |*v| {
            if (v.used and std.mem.eql(u8, v.name[0..v.name_len], name)) {
                v.val_len = @min(val.len, JS_VAR_VAL_MAX);
                @memcpy(v.val[0..v.val_len], val[0..v.val_len]);
                v.is_num = false;
                return;
            }
        }
        for (&self.vars) |*v| {
            if (!v.used) {
                v.name_len = @min(name.len, JS_VAR_NAME_MAX);
                @memcpy(v.name[0..v.name_len], name[0..v.name_len]);
                v.val_len = @min(val.len, JS_VAR_VAL_MAX);
                @memcpy(v.val[0..v.val_len], val[0..v.val_len]);
                v.is_num = false;
                v.used = true;
                return;
            }
        }
    }

    pub fn setVarNum(self: *JsEngine, name: []const u8, val: i64) void {
        for (&self.vars) |*v| {
            if (v.used and std.mem.eql(u8, v.name[0..v.name_len], name)) {
                v.num_val = val;
                v.is_num = true;
                return;
            }
        }
        for (&self.vars) |*v| {
            if (!v.used) {
                v.name_len = @min(name.len, JS_VAR_NAME_MAX);
                @memcpy(v.name[0..v.name_len], name[0..v.name_len]);
                v.num_val = val;
                v.is_num = true;
                v.used = true;
                return;
            }
        }
    }

    pub fn executeScript(self: *JsEngine, code: []const u8) void {
        serial.serialWrite("[JS] Executing script block (");
        serial.serialWriteDec(code.len);
        serial.serialWrite(" bytes)\n");

        var pos: usize = 0;
        while (pos < code.len) {
            // Skip whitespace
            while (pos < code.len and (code[pos] == ' ' or code[pos] == '\t' or code[pos] == '\r' or code[pos] == '\n')) : (pos += 1) {}
            if (pos >= code.len) break;

            // Skip line comments //
            if (pos + 1 < code.len and code[pos] == '/' and code[pos + 1] == '/') {
                while (pos < code.len and code[pos] != '\n') : (pos += 1) {}
                continue;
            }

            // Skip block comments /* ... */
            if (pos + 1 < code.len and code[pos] == '/' and code[pos + 1] == '*') {
                pos += 2;
                while (pos + 1 < code.len and !(code[pos] == '*' and code[pos + 1] == '/')) : (pos += 1) {}
                if (pos + 1 < code.len) pos += 2;
                continue;
            }

            // document.write(...)
            if (std.mem.startsWith(u8, code[pos..], "document.write")) {
                pos += 14;
                while (pos < code.len and code[pos] != '(') : (pos += 1) {}
                if (pos < code.len and code[pos] == '(') {
                    pos += 1;
                    const str_val = self.parseStringLiteral(code, &pos);
                    if (str_val.len > 0 and self.doc_write_len + str_val.len < self.doc_write_buf.len) {
                        @memcpy(self.doc_write_buf[self.doc_write_len..][0..str_val.len], str_val);
                        self.doc_write_len += str_val.len;
                    }
                }
                while (pos < code.len and code[pos] != ';' and code[pos] != '\n') : (pos += 1) {}
                continue;
            }

            // document.title = "..."
            if (std.mem.startsWith(u8, code[pos..], "document.title")) {
                pos += 14;
                while (pos < code.len and code[pos] != '=') : (pos += 1) {}
                if (pos < code.len and code[pos] == '=') {
                    pos += 1;
                    while (pos < code.len and (code[pos] == ' ' or code[pos] == '\t')) : (pos += 1) {}
                    const title_val = self.parseStringLiteral(code, &pos);
                    if (title_val.len > 0) {
                        self.title_override_len = @min(title_val.len, 48);
                        @memcpy(self.title_override[0..self.title_override_len], title_val[0..self.title_override_len]);
                    }
                }
                while (pos < code.len and code[pos] != ';' and code[pos] != '\n') : (pos += 1) {}
                continue;
            }

            // console.log(...)
            if (std.mem.startsWith(u8, code[pos..], "console.log")) {
                pos += 11;
                while (pos < code.len and code[pos] != '(') : (pos += 1) {}
                if (pos < code.len and code[pos] == '(') {
                    pos += 1;
                    const log_val = self.parseStringLiteral(code, &pos);
                    serial.serialWrite("[JS Console] ");
                    serial.serialWrite(log_val);
                    serial.serialWrite("\n");
                }
                while (pos < code.len and code[pos] != ';' and code[pos] != '\n') : (pos += 1) {}
                continue;
            }

            // Variable assignment: var / let / const x = ...
            if (std.mem.startsWith(u8, code[pos..], "var ") or std.mem.startsWith(u8, code[pos..], "let ") or std.mem.startsWith(u8, code[pos..], "const ")) {
                while (pos < code.len and code[pos] != ' ') : (pos += 1) {}
                while (pos < code.len and code[pos] == ' ') : (pos += 1) {}
                const vname_start = pos;
                while (pos < code.len and code[pos] != ' ' and code[pos] != '=' and code[pos] != ';') : (pos += 1) {}
                const vname = code[vname_start..pos];

                while (pos < code.len and code[pos] != '=' and code[pos] != ';') : (pos += 1) {}
                if (pos < code.len and code[pos] == '=') {
                    pos += 1;
                    while (pos < code.len and (code[pos] == ' ' or code[pos] == '\t')) : (pos += 1) {}
                    if (pos < code.len and (code[pos] == '"' or code[pos] == '\'')) {
                        const sval = self.parseStringLiteral(code, &pos);
                        self.setVarStr(vname, sval);
                    } else {
                        // numeric literal
                        var num: i64 = 0;
                        var is_neg = false;
                        if (pos < code.len and code[pos] == '-') {
                            is_neg = true;
                            pos += 1;
                        }
                        while (pos < code.len and code[pos] >= '0' and code[pos] <= '9') : (pos += 1) {
                            num = num * 10 + (code[pos] - '0');
                        }
                        if (is_neg) num = -num;
                        self.setVarNum(vname, num);
                    }
                }
                while (pos < code.len and code[pos] != ';' and code[pos] != '\n') : (pos += 1) {}
                continue;
            }

            // Advance statement
            while (pos < code.len and code[pos] != ';' and code[pos] != '\n') : (pos += 1) {}
            if (pos < code.len) pos += 1;
        }
    }

    fn parseStringLiteral(_: *JsEngine, code: []const u8, pos: *usize) []const u8 {
        while (pos.* < code.len and (code[pos.*] == ' ' or code[pos.*] == '\t')) : (pos.* += 1) {}
        if (pos.* >= code.len) return "";

        const quote = code[pos.*];
        if (quote != '"' and quote != '\'') return "";
        pos.* += 1;

        const start = pos.*;
        while (pos.* < code.len and code[pos.*] != quote) : (pos.* += 1) {
            if (code[pos.*] == '\\' and pos.* + 1 < code.len) pos.* += 1;
        }
        const str_slice = code[start..pos.*];
        if (pos.* < code.len and code[pos.*] == quote) pos.* += 1;
        return str_slice;
    }
};

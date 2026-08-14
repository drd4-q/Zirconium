const std = @import("std");
const layout = @import("layout.zig");
const css = @import("css.zig");
const entities = @import("entities.zig");
const url_mod = @import("url.zig");
const js_engine = @import("../js_engine.zig");

pub const HtmlParser = struct {
    doc: *layout.Document,
    base_url: *const url_mod.Url,
    page_title: [48]u8 = undefined,
    page_title_len: usize = 0,
    js: js_engine.JsEngine = .{},

    pub fn init(doc: *layout.Document, base_url: *const url_mod.Url) HtmlParser {
        var p = HtmlParser{
            .doc = doc,
            .base_url = base_url,
        };
        p.js.init();
        return p;
    }

    pub fn parse(self: *HtmlParser, raw_html: []const u8) void {
        var in_tag = false;
        var in_script = false;
        var in_style = false;
        var in_title = false;
        var in_anchor = false;
        var in_pre = false;

        var current_href: [128]u8 = undefined;
        var current_href_len: usize = 0;

        var script_buf: [1024]u8 = undefined;
        var script_len: usize = 0;

        var tag_buf: [128]u8 = undefined;
        var tag_len: usize = 0;

        var line_buf: [layout.LINE_LEN]u8 = undefined;
        var line_len: usize = 0;
        var cur_color: u32 = 0xE0E0E0;

        var bidx: usize = 0;
        while (bidx < raw_html.len and self.doc.line_count < layout.MAX_LINES) : (bidx += 1) {
            const ch = raw_html[bidx];

            if (ch == '<') {
                in_tag = true;
                tag_len = 0;
                continue;
            }

            if (ch == '>') {
                in_tag = false;
                const tag_full = tag_buf[0..tag_len];

                // Skip HTML comments <!-- ... -->
                if (std.mem.startsWith(u8, tag_full, "!--")) continue;

                // Extract tag name (up to first space, tab, or /)
                var name_start: usize = 0;
                while (name_start < tag_full.len and (tag_full[name_start] == ' ' or tag_full[name_start] == '/')) : (name_start += 1) {}
                var name_end: usize = name_start;
                while (name_end < tag_full.len and tag_full[name_end] != ' ' and tag_full[name_end] != '/' and tag_full[name_end] != '\t') : (name_end += 1) {}
                const tag_name = tag_full[name_start..name_end];

                if (std.ascii.eqlIgnoreCase(tag_name, "script")) {
                    in_script = true;
                    script_len = 0;
                } else if (std.ascii.eqlIgnoreCase(tag_name, "/script")) {
                    in_script = false;
                    if (script_len > 0) {
                        self.js.executeScript(script_buf[0..script_len]);
                        if (self.js.doc_write_len > 0) {
                            if (line_len > 0) {
                                self.doc.appendLine(line_buf[0..line_len], cur_color);
                                line_len = 0;
                            }
                            self.doc.appendLine(self.js.doc_write_buf[0..self.js.doc_write_len], 0xA0FFA0);
                            self.js.doc_write_len = 0;
                        }
                    }
                } else if (std.ascii.eqlIgnoreCase(tag_name, "style")) {
                    in_style = true;
                } else if (std.ascii.eqlIgnoreCase(tag_name, "/style")) {
                    in_style = false;
                } else if (std.ascii.eqlIgnoreCase(tag_name, "pre")) {
                    in_pre = true;
                    if (line_len > 0) {
                        self.doc.appendLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                } else if (std.ascii.eqlIgnoreCase(tag_name, "/pre")) {
                    in_pre = false;
                    if (line_len > 0) {
                        self.doc.appendLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                } else if (std.ascii.eqlIgnoreCase(tag_name, "title")) {
                    in_title = true;
                    self.page_title_len = 0;
                } else if (std.ascii.eqlIgnoreCase(tag_name, "/title")) {
                    in_title = false;
                } else if (std.ascii.eqlIgnoreCase(tag_name, "a")) {
                    in_anchor = true;
                    cur_color = 0x38B6FF; // Link blue

                    // Extract href="..."
                    current_href_len = 0;
                    var hpos: usize = 0;
                    while (hpos + 5 < tag_full.len) : (hpos += 1) {
                        if (std.ascii.eqlIgnoreCase(tag_full[hpos .. hpos + 5], "href=")) {
                            var val_start = hpos + 5;
                            if (val_start < tag_full.len and (tag_full[val_start] == '"' or tag_full[val_start] == '\'')) val_start += 1;
                            var val_end = val_start;
                            while (val_end < tag_full.len and tag_full[val_end] != '"' and tag_full[val_end] != '\'' and tag_full[val_end] != ' ') : (val_end += 1) {}
                            const raw_href = tag_full[val_start..val_end];

                            var resolved_buf: [128]u8 = undefined;
                            const res = url_mod.Url.resolveRelative(self.base_url, raw_href, &resolved_buf);
                            current_href_len = @min(res.len, 128);
                            @memcpy(current_href[0..current_href_len], res[0..current_href_len]);
                            break;
                        }
                    }
                } else if (std.ascii.eqlIgnoreCase(tag_name, "/a")) {
                    in_anchor = false;
                    cur_color = 0xE0E0E0;
                    if (current_href_len > 0 and self.doc.line_count > 0) {
                        self.doc.registerLink(current_href[0..current_href_len], current_href[0..current_href_len], self.doc.line_count - 1);
                    }
                } else if (std.ascii.eqlIgnoreCase(tag_name, "h1") or std.ascii.eqlIgnoreCase(tag_name, "h2") or std.ascii.eqlIgnoreCase(tag_name, "h3")) {
                    if (line_len > 0) {
                        self.doc.appendLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                    cur_color = 0xFFD700; // Gold
                } else if (std.ascii.eqlIgnoreCase(tag_name, "/h1") or std.ascii.eqlIgnoreCase(tag_name, "/h2") or std.ascii.eqlIgnoreCase(tag_name, "/h3")) {
                    if (line_len > 0) {
                        self.doc.appendLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                    cur_color = 0xE0E0E0;
                } else if (std.ascii.eqlIgnoreCase(tag_name, "p") or std.ascii.eqlIgnoreCase(tag_name, "br") or std.ascii.eqlIgnoreCase(tag_name, "/p") or std.ascii.eqlIgnoreCase(tag_name, "div") or std.ascii.eqlIgnoreCase(tag_name, "/div") or std.ascii.eqlIgnoreCase(tag_name, "tr")) {
                    if (line_len > 0) {
                        self.doc.appendLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                } else if (std.ascii.eqlIgnoreCase(tag_name, "li")) {
                    if (line_len > 0) {
                        self.doc.appendLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                    line_buf[0] = ' ';
                    line_buf[1] = '*';
                    line_buf[2] = ' ';
                    line_len = 3;
                } else if (std.ascii.eqlIgnoreCase(tag_name, "hr")) {
                    if (line_len > 0) {
                        self.doc.appendLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                    self.doc.appendLine("──────────────────────────────────────────", 0x506080);
                } else if (std.ascii.eqlIgnoreCase(tag_name, "input")) {
                    var val_str: []const u8 = "[ Input Box ]";
                    var ipos: usize = 0;
                    while (ipos + 6 < tag_full.len) : (ipos += 1) {
                        if (std.ascii.eqlIgnoreCase(tag_full[ipos .. ipos + 6], "value=")) {
                            var vs = ipos + 6;
                            if (vs < tag_full.len and (tag_full[vs] == '"' or tag_full[vs] == '\'')) vs += 1;
                            var ve = vs;
                            while (ve < tag_full.len and tag_full[ve] != '"' and tag_full[ve] != '\'') : (ve += 1) {}
                            if (ve > vs) val_str = tag_full[vs..ve];
                            break;
                        }
                    }
                    if (line_len > 0) {
                        self.doc.appendLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                    self.doc.appendLine(val_str, 0x88CCFF);
                } else if (std.ascii.eqlIgnoreCase(tag_name, "button")) {
                    cur_color = 0xFFD700;
                } else if (std.ascii.eqlIgnoreCase(tag_name, "/button")) {
                    cur_color = 0xE0E0E0;
                }

                // Check for inline style="..."
                var spos: usize = 0;
                while (spos + 6 < tag_full.len) : (spos += 1) {
                    if (std.ascii.eqlIgnoreCase(tag_full[spos .. spos + 6], "style=")) {
                        var ss = spos + 6;
                        if (ss < tag_full.len and (tag_full[ss] == '"' or tag_full[ss] == '\'')) ss += 1;
                        var se = ss;
                        while (se < tag_full.len and tag_full[se] != '"' and tag_full[se] != '\'') : (se += 1) {}
                        const s = css.Style.parseInline(tag_full[ss..se]);
                        cur_color = s.fg_color;
                        break;
                    }
                }

                continue;
            }

            if (in_tag) {
                if (tag_len < tag_buf.len) {
                    tag_buf[tag_len] = ch;
                    tag_len += 1;
                }
                continue;
            }

            if (in_script) {
                if (script_len < script_buf.len) {
                    script_buf[script_len] = ch;
                    script_len += 1;
                }
                continue;
            }

            if (in_style) continue;

            if (in_title) {
                if (self.page_title_len < self.page_title.len and ch >= 0x20 and ch < 0x7F) {
                    self.page_title[self.page_title_len] = ch;
                    self.page_title_len += 1;
                }
                continue;
            }

            // HTML Entity decoding: &name;
            if (ch == '&') {
                var ent_end = bidx + 1;
                while (ent_end < raw_html.len and ent_end < bidx + 10 and raw_html[ent_end] != ';' and raw_html[ent_end] != ' ') : (ent_end += 1) {}
                if (ent_end < raw_html.len and raw_html[ent_end] == ';') {
                    const entity = raw_html[bidx + 1 .. ent_end];
                    const decoded = entities.decode(entity);
                    if (decoded.len > 0) {
                        for (decoded) |dc| {
                            if (line_len < layout.LINE_LEN - 1) {
                                line_buf[line_len] = dc;
                                line_len += 1;
                            }
                        }
                        bidx = ent_end;
                        continue;
                    }
                }
            }

            if (in_pre) {
                if (ch == '\n' or ch == '\r') {
                    if (line_len > 0) {
                        self.doc.appendLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                } else if (ch >= 0x20 and ch < 0x7F) {
                    if (line_len < layout.LINE_LEN - 1) {
                        line_buf[line_len] = ch;
                        line_len += 1;
                    }
                }
                continue;
            }

            // Standard HTML Whitespace collapsing
            if (ch == '\n' or ch == '\r' or ch == '\t' or ch == ' ') {
                if (line_len > 0 and line_buf[line_len - 1] != ' ' and line_len < layout.LINE_LEN - 1) {
                    line_buf[line_len] = ' ';
                    line_len += 1;
                }
            } else if (ch >= 0x20 and ch < 0x7F) {
                if (line_len >= layout.LINE_LEN - 1) {
                    var wrap_pos = line_len;
                    while (wrap_pos > 0 and line_buf[wrap_pos - 1] != ' ') : (wrap_pos -= 1) {}
                    if (wrap_pos > 10) {
                        self.doc.appendLine(line_buf[0 .. wrap_pos - 1], cur_color);
                        const rest_len = line_len - wrap_pos;
                        var r: usize = 0;
                        while (r < rest_len) : (r += 1) {
                            line_buf[r] = line_buf[wrap_pos + r];
                        }
                        line_len = rest_len;
                    } else {
                        self.doc.appendLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                }
                line_buf[line_len] = ch;
                line_len += 1;
            }
        }

        if (line_len > 0) {
            self.doc.appendLine(line_buf[0..line_len], cur_color);
        }
    }
};

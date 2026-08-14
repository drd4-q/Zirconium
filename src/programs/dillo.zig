const std = @import("std");
const root = @import("root");
const vga = root.vga;
const http = @import("../net/http.zig");
const net = @import("../net/mod.zig");
const vfs = @import("../fs/vfs.zig");
const kb = @import("../drivers/keyboard.zig");
const timer = @import("../drivers/timer.zig");
const serial = @import("../system/serial.zig");
const js_engine = @import("js_engine.zig");
const dillo_engine = @import("dillo_engine.zig");

pub const MAX_DILLO_LINES: usize = 64;
pub const DILLO_LINE_LEN: usize = 70;
pub const MAX_LINKS: usize = 16;

pub const DilloLink = dillo_engine.DilloLink;

pub const DilloState = struct {
    url_buf: [128]u8 = undefined,
    url_len: usize = 0,
    title_buf: [48]u8 = undefined,
    title_len: usize = 0,
    status_buf: [64]u8 = undefined,
    status_len: usize = 0,

    lines: [MAX_DILLO_LINES][DILLO_LINE_LEN]u8 = undefined,
    line_lens: [MAX_DILLO_LINES]usize = [_]usize{0} ** MAX_DILLO_LINES,
    line_colors: [MAX_DILLO_LINES]u32 = [_]u32{0xE0E0E0} ** MAX_DILLO_LINES,
    line_count: usize = 0,

    links: [MAX_LINKS]DilloLink = undefined,
    link_count: usize = 0,

    js: js_engine.JsEngine = .{},
    http_rx_raw: [8192]u8 = undefined,

    pub fn init(self: *DilloState) void {
        self.url_len = 0;
        self.title_len = 0;
        self.status_len = 0;
        self.line_count = 0;
        self.link_count = 0;
        self.js.init();

        self.loadUrl("about:dillo");
    }

    pub fn setUrl(self: *DilloState, url: []const u8) void {
        const ulen = @min(url.len, 128);
        @memcpy(self.url_buf[0..ulen], url[0..ulen]);
        self.url_len = ulen;
    }

    pub fn setStatus(self: *DilloState, status: []const u8) void {
        const slen = @min(status.len, 64);
        @memcpy(self.status_buf[0..slen], status[0..slen]);
        self.status_len = slen;
    }

    pub fn addLine(self: *DilloState, text: []const u8, color: u32) void {
        if (self.line_count >= MAX_DILLO_LINES) return;
        const idx = self.line_count;
        const tlen = @min(text.len, DILLO_LINE_LEN);
        @memcpy(self.lines[idx][0..tlen], text[0..tlen]);
        self.line_lens[idx] = tlen;
        self.line_colors[idx] = color;
        self.line_count += 1;
    }

    pub fn addLink(self: *DilloState, text: []const u8, url: []const u8, line_idx: usize) void {
        if (self.link_count >= MAX_LINKS) return;
        const l = &self.links[self.link_count];
        l.text_len = @min(text.len, 32);
        @memcpy(l.text[0..l.text_len], text[0..l.text_len]);
        l.url_len = @min(url.len, 96);
        @memcpy(l.url[0..l.url_len], url[0..l.url_len]);
        l.line_idx = line_idx;
        self.link_count += 1;
    }

    pub fn loadUrl(self: *DilloState, url: []const u8) void {
        self.setUrl(url);
        self.line_count = 0;
        self.link_count = 0;
        self.title_len = 0;
        self.js.init();

        if (std.mem.eql(u8, url, "about:dillo") or std.mem.eql(u8, url, "about:home") or url.len == 0) {
            const title = "Dillo Web Browser v3.1";
            @memcpy(self.title_buf[0..title.len], title);
            self.title_len = title.len;

            self.addLine("=== Dillo Web Browser for Zirconium ===", 0x40E0D0);
            self.addLine("Fast, standards-compliant HTML5/CSS/JS engine.", 0xCCCCCC);
            self.addLine("", 0x000000);
            self.addLine("[ Quick Navigation Bookmarks ]", 0xFFD700);
            self.addLine("  * Link 1: about:kernel (Kernel Status & Specs)", 0x38B6FF);
            self.addLink("about:kernel", "about:kernel", self.line_count - 1);
            self.addLine("  * Link 2: http://10.0.2.2/ (Host Gateway Web Server)", 0x38B6FF);
            self.addLink("http://10.0.2.2/", "http://10.0.2.2/", self.line_count - 1);
            self.addLine("  * Link 3: file:///mnt/disk/hello.txt (FAT16 Storage)", 0x38B6FF);
            self.addLink("file:///mnt/disk/hello.txt", "file:///mnt/disk/hello.txt", self.line_count - 1);
            self.addLine("  * Link 4: http://acme.com/ (ACME Laboratories)", 0x38B6FF);
            self.addLink("http://acme.com/", "http://acme.com/", self.line_count - 1);
            self.addLine("  * Link 5: http://cern.ch/ (First Web Site at CERN)", 0x38B6FF);
            self.addLink("http://cern.ch/", "http://cern.ch/", self.line_count - 1);
            self.addLine("", 0x000000);
            self.addLine("[ Standards & Capabilities ]", 0xFFD700);
            self.addLine("  - HTML5 Tag Parser & Entity Resolver (&nbsp; &amp; &quot;...)", 0xA0FFA0);
            self.addLine("  - CSS3 Color & Style Engine (Named Colors, Hex #RGB, Bold)", 0xA0FFA0);
            self.addLine("  - Embedded JavaScript Runtime (<script>, DOM, document.write)", 0xA0FFA0);
            self.addLine("  - HTTP 301/302 Redirect Tracking & Hyperlink Navigation", 0xA0FFA0);
            self.setStatus("Ready (Dillo Engine Active)");
            return;
        }

        if (std.mem.eql(u8, url, "about:kernel")) {
            const title = "Zirconium Kernel Information";
            @memcpy(self.title_buf[0..title.len], title);
            self.title_len = title.len;

            self.addLine("=== Zirconium Kernel Status ===", 0xFFD700);
            self.addLine("  OS:           Zirconium x86_64 Bare-Metal", 0xE8E8E8);
            self.addLine("  CPUs:         4 Cores SMP (ACPI MADT + APIC)", 0xE8E8E8);
            self.addLine("  Networking:   Intel e1000 Gigabit (IP: 10.0.2.15)", 0x88FF88);
            self.addLine("  GUI Engine:   1024x768 Linear Framebuffer (LFB)", 0x88CCFF);
            self.addLine("  Filesystems:  ramfs (/) + FAT16 (/mnt/disk)", 0xE8E8E8);
            self.addLine("", 0x000000);
            self.addLine("<- Back to Home: about:dillo", 0x38B6FF);
            self.addLink("about:dillo", "about:dillo", self.line_count - 1);
            self.setStatus("Kernel Info Loaded");
            return;
        }

        // Local file protocol
        if (std.mem.startsWith(u8, url, "file://")) {
            const fpath = url[7..];
            if (vfs.open(fpath, .{ .read = true })) |handle| {
                defer vfs.close(handle);
                var fbuf: [2048]u8 = undefined;
                const n = vfs.read(handle, &fbuf);
                self.addLine("=== Local File Content ===", 0x40E0D0);
                self.addLine(fpath, 0xFFD700);
                self.addLine("", 0x000000);

                if (std.mem.endsWith(u8, fpath, ".html") or std.mem.endsWith(u8, fpath, ".htm")) {
                    self.parseHtmlBody(fbuf[0..n]);
                } else {
                    var start: usize = 0;
                    for (fbuf[0..n], 0..) |c, idx| {
                        if (c == '\n' or idx == n - 1) {
                            const end = if (c == '\n') idx else idx + 1;
                            if (end > start) {
                                self.addLine(fbuf[start..end], 0xE0E0E0);
                            }
                            start = idx + 1;
                        }
                    }
                }
                self.setStatus("File Loaded OK");
                return;
            } else {
                self.addLine("Error: File not found:", 0xFF5555);
                self.addLine(fpath, 0xE0E0E0);
                self.setStatus("404 File Not Found");
                return;
            }
        }

        // Remote HTTP Fetch
        self.setStatus("Resolving host and connecting...");
        self.fetchAndRenderHttp(url, 0);
    }

    fn fetchAndRenderHttp(self: *DilloState, url: []const u8, depth: usize) void {
        if (depth > 3) {
            self.addLine("Error: Too many redirects (depth > 3)", 0xFF5555);
            self.setStatus("Redirect Loop Detected");
            return;
        }

        var host_start: usize = 0;
        if (std.mem.startsWith(u8, url, "http://")) {
            host_start = 7;
        } else if (std.mem.startsWith(u8, url, "https://")) {
            host_start = 8;
        }

        var host_end: usize = url.len;
        var path_start: usize = url.len;
        var port: u16 = 80;

        var i = host_start;
        while (i < url.len) : (i += 1) {
            if (url[i] == '/') {
                host_end = i;
                path_start = i;
                break;
            }
            if (url[i] == ':') {
                host_end = i;
                var p: u32 = 0;
                var j = i + 1;
                while (j < url.len and url[j] >= '0' and url[j] <= '9') : (j += 1) {
                    p = p * 10 + (url[j] - '0');
                }
                if (p > 0 and p <= 65535) port = @intCast(p);
                path_start = j;
                break;
            }
        }

        const host = url[host_start..host_end];
        const path = if (path_start < url.len) url[path_start..] else "/";

        if (host.len == 0) {
            self.addLine("Error: Invalid URL specified", 0xFF5555);
            self.setStatus("Invalid URL");
            return;
        }

        serial.serialWrite("[DILLO] Fetching: host=");
        serial.serialWrite(host);
        serial.serialWrite(" path=");
        serial.serialWrite(path);
        serial.serialWrite("\n");

        const received_len = http.fetchBuffer(host, path, port, &self.http_rx_raw) orelse {
            self.addLine("Connection Failed:", 0xFF5555);
            self.addLine("Could not reach host or DNS resolution timed out.", 0xCCCCCC);
            self.addLine(host, 0xFFFFFF);
            self.setStatus("HTTP Error: Connection Failed");
            return;
        };

        const raw_resp = self.http_rx_raw[0..received_len];

        // Find status line
        var first_line_end: usize = 0;
        while (first_line_end < raw_resp.len and raw_resp[first_line_end] != '\r' and raw_resp[first_line_end] != '\n') : (first_line_end += 1) {}
        const status_line = raw_resp[0..first_line_end];

        self.setStatus(status_line);

        // Find end of HTTP headers (\r\n\r\n)
        var body_start: usize = raw_resp.len;
        var hidx: usize = 0;
        while (hidx + 3 < raw_resp.len) : (hidx += 1) {
            if (raw_resp[hidx] == '\r' and raw_resp[hidx + 1] == '\n' and raw_resp[hidx + 2] == '\r' and raw_resp[hidx + 3] == '\n') {
                body_start = hidx + 4;
                break;
            }
        }

        const headers = raw_resp[0..body_start];

        // Check for Location header (Redirect 301/302/303/307/308)
        var location_url: ?[]const u8 = null;
        var lpos: usize = 0;
        while (lpos + 9 < headers.len) : (lpos += 1) {
            if ((headers[lpos] == 'L' or headers[lpos] == 'l') and
                std.ascii.eqlIgnoreCase(headers[lpos .. lpos + 9], "location:"))
            {
                var val_start = lpos + 9;
                while (val_start < headers.len and (headers[val_start] == ' ' or headers[val_start] == '\t')) : (val_start += 1) {}
                var val_end = val_start;
                while (val_end < headers.len and headers[val_end] != '\r' and headers[val_end] != '\n') : (val_end += 1) {}
                location_url = headers[val_start..val_end];
                break;
            }
        }

        if (location_url) |loc| {
            self.addLine(status_line, 0xFFD700);
            self.addLine("Location Redirect:", 0x40E0D0);
            self.addLine(loc, 0x38B6FF);
            self.addLink(loc, loc, self.line_count - 1);

            if (std.mem.startsWith(u8, loc, "http://")) {
                self.addLine("Following redirect...", 0x88FF88);
                self.fetchAndRenderHttp(loc, depth + 1);
                return;
            } else if (std.mem.startsWith(u8, loc, "/")) {
                var full_url_buf: [128]u8 = undefined;
                const pfx = "http://";
                @memcpy(full_url_buf[0..pfx.len], pfx);
                @memcpy(full_url_buf[pfx.len..][0..host.len], host);
                @memcpy(full_url_buf[pfx.len + host.len ..][0..loc.len], loc);
                const full_len = pfx.len + host.len + loc.len;
                self.fetchAndRenderHttp(full_url_buf[0..full_len], depth + 1);
                return;
            } else {
                self.addLine("Redirect destination is HTTPS:", 0xFFAA55);
                self.addLine(loc, 0x38B6FF);
            }
        }

        // Parse HTML body with CSS and JS isolation
        if (body_start < raw_resp.len) {
            const body = raw_resp[body_start..];
            self.parseHtmlBody(body);
        }
    }

    fn parseHtmlBody(self: *DilloState, body: []const u8) void {
        var in_tag = false;
        var in_script = false;
        var in_style = false;
        var in_title = false;
        var in_anchor = false;
        var in_pre = false;

        var current_href: [96]u8 = undefined;
        var current_href_len: usize = 0;

        var script_buf: [1024]u8 = undefined;
        var script_len: usize = 0;

        var tag_buf: [128]u8 = undefined;
        var tag_len: usize = 0;

        var line_buf: [DILLO_LINE_LEN]u8 = undefined;
        var line_len: usize = 0;
        var cur_color: u32 = 0xE0E0E0;

        var bidx: usize = 0;
        while (bidx < body.len and self.line_count < MAX_DILLO_LINES) : (bidx += 1) {
            const ch = body[bidx];

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
                while (name_start < tag_full.len and tag_full[name_start] == ' ') : (name_start += 1) {}
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
                                self.addLine(line_buf[0..line_len], cur_color);
                                line_len = 0;
                            }
                            self.addLine(self.js.doc_write_buf[0..self.js.doc_write_len], 0xA0FFA0);
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
                        self.addLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                } else if (std.ascii.eqlIgnoreCase(tag_name, "/pre")) {
                    in_pre = false;
                    if (line_len > 0) {
                        self.addLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                } else if (std.ascii.eqlIgnoreCase(tag_name, "title")) {
                    in_title = true;
                    self.title_len = 0;
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
                            const href_val = tag_full[val_start..val_end];
                            current_href_len = @min(href_val.len, 96);
                            @memcpy(current_href[0..current_href_len], href_val[0..current_href_len]);
                            break;
                        }
                    }
                } else if (std.ascii.eqlIgnoreCase(tag_name, "/a")) {
                    in_anchor = false;
                    cur_color = 0xE0E0E0;
                    if (current_href_len > 0 and self.line_count > 0) {
                        self.addLink(current_href[0..current_href_len], current_href[0..current_href_len], self.line_count - 1);
                    }
                } else if (std.ascii.eqlIgnoreCase(tag_name, "h1") or std.ascii.eqlIgnoreCase(tag_name, "h2") or std.ascii.eqlIgnoreCase(tag_name, "h3")) {
                    if (line_len > 0) {
                        self.addLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                    cur_color = 0xFFD700; // Gold for headings
                } else if (std.ascii.eqlIgnoreCase(tag_name, "/h1") or std.ascii.eqlIgnoreCase(tag_name, "/h2") or std.ascii.eqlIgnoreCase(tag_name, "/h3")) {
                    if (line_len > 0) {
                        self.addLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                    cur_color = 0xE0E0E0;
                } else if (std.ascii.eqlIgnoreCase(tag_name, "p") or std.ascii.eqlIgnoreCase(tag_name, "br") or std.ascii.eqlIgnoreCase(tag_name, "/p") or std.ascii.eqlIgnoreCase(tag_name, "div") or std.ascii.eqlIgnoreCase(tag_name, "/div") or std.ascii.eqlIgnoreCase(tag_name, "tr")) {
                    if (line_len > 0) {
                        self.addLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                } else if (std.ascii.eqlIgnoreCase(tag_name, "li")) {
                    if (line_len > 0) {
                        self.addLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                    // Insert bullet
                    line_buf[0] = ' ';
                    line_buf[1] = '*';
                    line_buf[2] = ' ';
                    line_len = 3;
                } else if (std.ascii.eqlIgnoreCase(tag_name, "hr")) {
                    if (line_len > 0) {
                        self.addLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                    self.addLine("──────────────────────────────────────────", 0x506080);
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
                        self.addLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                    self.addLine(val_str, 0x88CCFF);
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
                        const css = dillo_engine.CssStyle.parseInline(tag_full[ss..se]);
                        cur_color = css.fg_color;
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
                if (self.title_len < self.title_buf.len and ch >= 0x20 and ch < 0x7F) {
                    self.title_buf[self.title_len] = ch;
                    self.title_len += 1;
                }
                continue;
            }

            // HTML Entity decoding: &name;
            if (ch == '&') {
                var ent_end = bidx + 1;
                while (ent_end < body.len and ent_end < bidx + 10 and body[ent_end] != ';' and body[ent_end] != ' ') : (ent_end += 1) {}
                if (ent_end < body.len and body[ent_end] == ';') {
                    const entity = body[bidx + 1 .. ent_end];
                    const decoded = dillo_engine.decodeEntity(entity);
                    if (decoded.len > 0) {
                        for (decoded) |dc| {
                            if (line_len < DILLO_LINE_LEN - 1) {
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
                        self.addLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                } else if (ch >= 0x20 and ch < 0x7F) {
                    if (line_len < DILLO_LINE_LEN - 1) {
                        line_buf[line_len] = ch;
                        line_len += 1;
                    }
                }
                continue;
            }

            // Standard HTML Whitespace collapsing (\n, \r, \t, ' ' -> single space)
            if (ch == '\n' or ch == '\r' or ch == '\t' or ch == ' ') {
                if (line_len > 0 and line_buf[line_len - 1] != ' ' and line_len < DILLO_LINE_LEN - 1) {
                    line_buf[line_len] = ' ';
                    line_len += 1;
                }
            } else if (ch >= 0x20 and ch < 0x7F) {
                // Word wrapping: wrap to next line when exceeding DILLO_LINE_LEN
                if (line_len >= DILLO_LINE_LEN - 1) {
                    // Try to wrap at last space
                    var wrap_pos = line_len;
                    while (wrap_pos > 0 and line_buf[wrap_pos - 1] != ' ') : (wrap_pos -= 1) {}
                    if (wrap_pos > 10) {
                        self.addLine(line_buf[0 .. wrap_pos - 1], cur_color);
                        const rest_len = line_len - wrap_pos;
                        var r: usize = 0;
                        while (r < rest_len) : (r += 1) {
                            line_buf[r] = line_buf[wrap_pos + r];
                        }
                        line_len = rest_len;
                    } else {
                        self.addLine(line_buf[0..line_len], cur_color);
                        line_len = 0;
                    }
                }
                line_buf[line_len] = ch;
                line_len += 1;
            }
        }

        if (line_len > 0) {
            self.addLine(line_buf[0..line_len], cur_color);
        }
    }
};

pub var global_dillo: DilloState = undefined;
var initialized: bool = false;

pub fn getDillo() *DilloState {
    if (!initialized) {
        global_dillo.init();
        initialized = true;
    }
    return &global_dillo;
}

pub fn run(args: []const u8) void {
    vga.setColor(.light_cyan, .black);
    vga.write("\n=== Dillo Web Browser ===\n\n");
    vga.setColor(.white, .black);

    const dillo = getDillo();
    if (args.len > 0) {
        dillo.loadUrl(args);
    } else {
        dillo.loadUrl("about:dillo");
    }

    var i: usize = 0;
    while (i < dillo.line_count) : (i += 1) {
        vga.write("  ");
        vga.write(dillo.lines[i][0..dillo.line_lens[i]]);
        vga.write("\n");
    }
    vga.write("\n");
}

const std = @import("std");
const root = @import("root");
const vga = root.vga;
const http = @import("../../net/http.zig");
const net = @import("../../net/mod.zig");
const vfs = @import("../../fs/vfs.zig");
const serial = @import("../../system/serial.zig");
const url_mod = @import("url.zig");
const layout = @import("layout.zig");
const html_mod = @import("html.zig");

pub const HISTORY_MAX: usize = 16;

pub const DilloBrowser = struct {
    current_url: url_mod.Url = .{},
    raw_url_buf: [128]u8 = undefined,
    raw_url_len: usize = 0,

    title_buf: [48]u8 = undefined,
    title_len: usize = 0,

    status_buf: [64]u8 = undefined,
    status_len: usize = 0,

    doc: layout.Document = .{},

    history: [HISTORY_MAX][128]u8 = undefined,
    history_lens: [HISTORY_MAX]usize = [_]usize{0} ** HISTORY_MAX,
    history_count: usize = 0,
    history_pos: usize = 0,

    http_rx_raw: [16384]u8 = undefined,

    pub fn init(self: *DilloBrowser) void {
        self.raw_url_len = 0;
        self.title_len = 0;
        self.status_len = 0;
        self.history_count = 0;
        self.history_pos = 0;
        self.doc.reset();

        self.loadUrl("about:dillo");
    }

    pub fn setUrl(self: *DilloBrowser, raw: []const u8) void {
        const ulen = @min(raw.len, 128);
        @memcpy(self.raw_url_buf[0..ulen], raw[0..ulen]);
        self.raw_url_len = ulen;
        self.current_url = url_mod.Url.parse(raw);
    }

    pub fn setStatus(self: *DilloBrowser, s: []const u8) void {
        const slen = @min(s.len, 64);
        @memcpy(self.status_buf[0..slen], s[0..slen]);
        self.status_len = slen;
    }

    pub fn setTitle(self: *DilloBrowser, t: []const u8) void {
        const tlen = @min(t.len, 48);
        @memcpy(self.title_buf[0..tlen], t[0..tlen]);
        self.title_len = tlen;
    }

    pub fn loadUrl(self: *DilloBrowser, raw_url: []const u8) void {
        self.setUrl(raw_url);
        self.doc.reset();

        // Push to history
        if (self.history_count < HISTORY_MAX) {
            const hidx = self.history_count;
            const hlen = @min(raw_url.len, 128);
            @memcpy(self.history[hidx][0..hlen], raw_url[0..hlen]);
            self.history_lens[hidx] = hlen;
            self.history_pos = hidx;
            self.history_count += 1;
        }

        if (std.mem.eql(u8, raw_url, "about:dillo") or std.mem.eql(u8, raw_url, "about:home") or raw_url.len == 0) {
            self.setTitle("Dillo Web Browser v3.1");
            self.doc.appendLine("=== Dillo Web Browser for Zirconium ===", 0x40E0D0);
            self.doc.appendLine("Complete Dillo browser engine (HTML5 parser, CSS, DOM).", 0xCCCCCC);
            self.doc.appendLine("", 0x000000);
            self.doc.appendLine("[ Quick Navigation Bookmarks ]", 0xFFD700);
            self.doc.appendLine("  * Link 1: about:kernel (Kernel Status & Specs)", 0x38B6FF);
            self.doc.registerLink("about:kernel", "about:kernel", self.doc.line_count - 1);
            self.doc.appendLine("  * Link 2: http://acme.com/ (ACME Laboratories)", 0x38B6FF);
            self.doc.registerLink("http://acme.com/", "http://acme.com/", self.doc.line_count - 1);
            self.doc.appendLine("  * Link 3: http://cern.ch/ (First Web Site at CERN)", 0x38B6FF);
            self.doc.registerLink("http://cern.ch/", "http://cern.ch/", self.doc.line_count - 1);
            self.doc.appendLine("  * Link 4: file:///mnt/disk/hello.txt (FAT16 Storage)", 0x38B6FF);
            self.doc.registerLink("file:///mnt/disk/hello.txt", "file:///mnt/disk/hello.txt", self.doc.line_count - 1);
            self.doc.appendLine("", 0x000000);
            self.doc.appendLine("[ Architecture & Compliance ]", 0xFFD700);
            self.doc.appendLine("  - Dillo Widget Layout Engine (Word-wrapping, Box model)", 0xA0FFA0);
            self.doc.appendLine("  - HTML Tokenizer with standard entity resolving (&bull;, &copy;)", 0xA0FFA0);
            self.doc.appendLine("  - CSS Cascade & Color Parser (#RGB, #RRGGBB, named colors)", 0xA0FFA0);
            self.doc.appendLine("  - Script Isolation & JavaScript DOM Evaluation Engine", 0xA0FFA0);
            self.doc.appendLine("  - HTTP/1.0 & 301/302 Redirect Automation", 0xA0FFA0);
            self.setStatus("Ready (Dillo Engine Active)");
            return;
        }

        if (std.mem.eql(u8, raw_url, "about:kernel")) {
            self.setTitle("Zirconium Kernel Information");
            self.doc.appendLine("=== Zirconium Kernel Status ===", 0xFFD700);
            self.doc.appendLine("  OS:           Zirconium x86_64 Bare-Metal", 0xE8E8E8);
            self.doc.appendLine("  CPUs:         4 Cores SMP (ACPI MADT + APIC)", 0xE8E8E8);
            self.doc.appendLine("  Networking:   Intel e1000 Gigabit (IP: 10.0.2.15)", 0x88FF88);
            self.doc.appendLine("  GUI Engine:   1024x768 Linear Framebuffer (LFB)", 0x88CCFF);
            self.doc.appendLine("  Filesystems:  ramfs (/) + FAT16 (/mnt/disk)", 0xE8E8E8);
            self.doc.appendLine("", 0x000000);
            self.doc.appendLine("<- Back to Home: about:dillo", 0x38B6FF);
            self.doc.registerLink("about:dillo", "about:dillo", self.doc.line_count - 1);
            self.setStatus("Kernel Info Loaded");
            return;
        }

        // Local file protocol
        if (std.mem.startsWith(u8, raw_url, "file://")) {
            const fpath = raw_url[7..];
            if (vfs.open(fpath, .{ .read = true })) |handle| {
                defer vfs.close(handle);
                var fbuf: [4096]u8 = undefined;
                const n = vfs.read(handle, &fbuf);
                self.setTitle(fpath);
                self.doc.appendLine("=== Local File Content ===", 0x40E0D0);
                self.doc.appendLine(fpath, 0xFFD700);
                self.doc.appendLine("", 0x000000);

                if (std.mem.endsWith(u8, fpath, ".html") or std.mem.endsWith(u8, fpath, ".htm")) {
                    var parser = html_mod.HtmlParser.init(&self.doc, &self.current_url);
                    parser.parse(fbuf[0..n]);
                    if (parser.page_title_len > 0) {
                        self.setTitle(parser.page_title[0..parser.page_title_len]);
                    }
                } else {
                    var start: usize = 0;
                    for (fbuf[0..n], 0..) |c, idx| {
                        if (c == '\n' or idx == n - 1) {
                            const end = if (c == '\n') idx else idx + 1;
                            if (end > start) {
                                self.doc.appendLine(fbuf[start..end], 0xE0E0E0);
                            }
                            start = idx + 1;
                        }
                    }
                }
                self.setStatus("File Loaded OK");
                return;
            } else {
                self.doc.appendLine("Error: File not found:", 0xFF5555);
                self.doc.appendLine(fpath, 0xE0E0E0);
                self.setStatus("404 File Not Found");
                return;
            }
        }

        // Remote HTTP Fetch
        self.setStatus("Resolving host and connecting...");
        self.fetchAndRender(raw_url, 0);
    }

    fn fetchAndRender(self: *DilloBrowser, target_url: []const u8, depth: usize) void {
        if (depth > 3) {
            self.doc.appendLine("Error: Too many redirects (depth > 3)", 0xFF5555);
            self.setStatus("Redirect Loop");
            return;
        }

        const parsed = url_mod.Url.parse(target_url);
        const host = parsed.host[0..parsed.host_len];
        const path = parsed.path[0..parsed.path_len];

        if (host.len == 0) {
            self.doc.appendLine("Error: Invalid URL", 0xFF5555);
            self.setStatus("Invalid URL");
            return;
        }

        serial.serialWrite("[DILLO] Fetching: host=");
        serial.serialWrite(host);
        serial.serialWrite(" path=");
        serial.serialWrite(path);
        serial.serialWrite("\n");

        const received_len = http.fetchBuffer(host, path, parsed.port, &self.http_rx_raw) orelse {
            self.doc.appendLine("Connection Failed:", 0xFF5555);
            self.doc.appendLine("Could not reach host or DNS resolution timed out.", 0xCCCCCC);
            self.doc.appendLine(host, 0xFFFFFF);
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
            self.doc.appendLine(status_line, 0xFFD700);
            self.doc.appendLine("Location Redirect:", 0x40E0D0);

            var resolved_buf: [128]u8 = undefined;
            const full_loc = url_mod.Url.resolveRelative(&parsed, loc, &resolved_buf);

            self.doc.appendLine(full_loc, 0x38B6FF);
            self.doc.registerLink(full_loc, full_loc, self.doc.line_count - 1);

            if (std.mem.startsWith(u8, full_loc, "http://")) {
                self.doc.appendLine("Following redirect...", 0x88FF88);
                self.fetchAndRender(full_loc, depth + 1);
                return;
            } else {
                self.doc.appendLine("Redirect destination is HTTPS:", 0xFFAA55);
                self.doc.appendLine(full_loc, 0x38B6FF);
            }
        }

        // Parse HTML body
        if (body_start < raw_resp.len) {
            const body = raw_resp[body_start..];
            var parser = html_mod.HtmlParser.init(&self.doc, &parsed);
            parser.parse(body);
            if (parser.page_title_len > 0) {
                self.setTitle(parser.page_title[0..parser.page_title_len]);
            } else {
                self.setTitle(host);
            }
        }
    }
};

pub var global_browser: DilloBrowser = undefined;
var browser_initialized: bool = false;

pub fn getBrowser() *DilloBrowser {
    if (!browser_initialized) {
        global_browser.init();
        browser_initialized = true;
    }
    return &global_browser;
}

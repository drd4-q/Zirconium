const std = @import("std");

pub const Url = struct {
    protocol: [16]u8 = undefined,
    protocol_len: usize = 0,
    host: [64]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 80,
    path: [128]u8 = undefined,
    path_len: usize = 0,

    pub fn parse(raw: []const u8) Url {
        var u = Url{};
        if (raw.len == 0) return u;

        var cur = raw;

        // Protocol
        if (std.mem.indexOf(u8, cur, "://")) |proto_idx| {
            const p = cur[0..proto_idx];
            u.protocol_len = @min(p.len, 16);
            @memcpy(u.protocol[0..u.protocol_len], p[0..u.protocol_len]);
            cur = cur[proto_idx + 3 ..];
        } else if (std.mem.startsWith(u8, cur, "about:")) {
            const p = "about";
            u.protocol_len = p.len;
            @memcpy(u.protocol[0..p.len], p);
            const path_slice = cur[6..];
            u.path_len = @min(path_slice.len, 128);
            @memcpy(u.path[0..u.path_len], path_slice[0..u.path_len]);
            return u;
        } else {
            const p = "http";
            u.protocol_len = p.len;
            @memcpy(u.protocol[0..p.len], p);
        }

        // Host and Port
        var host_end = cur.len;
        if (std.mem.indexOfScalar(u8, cur, '/')) |slash_idx| {
            host_end = slash_idx;
        }

        const host_port = cur[0..host_end];
        if (std.mem.indexOfScalar(u8, host_port, ':')) |colon_idx| {
            const h = host_port[0..colon_idx];
            u.host_len = @min(h.len, 64);
            @memcpy(u.host[0..u.host_len], h[0..u.host_len]);

            const port_str = host_port[colon_idx + 1 ..];
            var parsed_port: u32 = 0;
            for (port_str) |ch| {
                if (ch >= '0' and ch <= '9') {
                    parsed_port = parsed_port * 10 + (ch - '0');
                }
            }
            if (parsed_port > 0 and parsed_port <= 65535) {
                u.port = @intCast(parsed_port);
            }
        } else {
            u.host_len = @min(host_port.len, 64);
            @memcpy(u.host[0..u.host_len], host_port[0..u.host_len]);
            if (std.mem.eql(u8, u.protocol[0..u.protocol_len], "https")) {
                u.port = 443;
            } else {
                u.port = 80;
            }
        }

        // Path
        if (host_end < cur.len) {
            const p = cur[host_end..];
            u.path_len = @min(p.len, 128);
            @memcpy(u.path[0..u.path_len], p[0..u.path_len]);
        } else {
            u.path[0] = '/';
            u.path_len = 1;
        }

        return u;
    }

    pub fn resolveRelative(base: *const Url, rel: []const u8, out_buf: []u8) []const u8 {
        if (std.mem.indexOf(u8, rel, "://") != null or std.mem.startsWith(u8, rel, "about:")) {
            const cplen = @min(rel.len, out_buf.len);
            @memcpy(out_buf[0..cplen], rel[0..cplen]);
            return out_buf[0..cplen];
        }

        var pos: usize = 0;
        const proto = base.protocol[0..base.protocol_len];
        @memcpy(out_buf[pos..][0..proto.len], proto);
        pos += proto.len;
        @memcpy(out_buf[pos..][0..3], "://");
        pos += 3;

        const host = base.host[0..base.host_len];
        @memcpy(out_buf[pos..][0..host.len], host);
        pos += host.len;

        if (base.port != 80 and base.port != 443) {
            out_buf[pos] = ':';
            pos += 1;
            var num = base.port;
            var num_buf: [8]u8 = undefined;
            var ni: usize = 0;
            while (num > 0) : (num /= 10) {
                num_buf[ni] = @intCast((num % 10) + '0');
                ni += 1;
            }
            while (ni > 0) : (ni -= 1) {
                out_buf[pos] = num_buf[ni - 1];
                pos += 1;
            }
        }

        if (rel.len > 0 and rel[0] == '/') {
            const rlen = @min(rel.len, out_buf.len - pos);
            @memcpy(out_buf[pos..][0..rlen], rel[0..rlen]);
            pos += rlen;
        } else {
            out_buf[pos] = '/';
            pos += 1;
            const rlen = @min(rel.len, out_buf.len - pos);
            @memcpy(out_buf[pos..][0..rlen], rel[0..rlen]);
            pos += rlen;
        }

        return out_buf[0..pos];
    }
};

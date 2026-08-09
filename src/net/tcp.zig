const std = @import("std");
const root = @import("root");
const vga = root.vga;
const port_io = root.serial;
const net = @import("mod.zig");
const ip_mod = @import("ip.zig");
const e1000 = @import("../drivers/e1000.zig");
const timer = @import("../drivers/timer.zig");

pub const TcpState = enum {
    closed,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    last_ack,
    time_wait,
};

const MAX_CONNECTIONS: usize = 4;
const RETX_TIMEOUT: u64 = 500; // 500ms in ticks (100Hz)
const RETX_MAX: u32 = 10;

pub const Connection = struct {
    id: i32 = -1,
    state: TcpState = .closed,
    local_port: u16 = 0,
    remote_port: u16 = 0,
    remote_ip: [4]u8 = .{ 0, 0, 0, 0 },
    seq_num: u32 = 0,
    ack_num: u32 = 0,
    rx_buf: [65536]u8 = undefined,
    rx_len: usize = 0,
    rx_ready: bool = false,
    retx_buf: [1500]u8 = undefined,
    retx_len: usize = 0,
    retx_flags: u8 = 0,
    retx_dst_ip: [4]u8 = .{ 0, 0, 0, 0 },
    retx_dst_port: u16 = 0,
    retx_last: u64 = 0,
    retx_count: u32 = 0,
    retx_active: bool = false,
};

var connections: [MAX_CONNECTIONS]Connection = [_]Connection{.{}} ** MAX_CONNECTIONS;
var next_port: u16 = 12345;
var next_id: i32 = 0;

pub fn allocConnection() ?*Connection {
    for (&connections, 0..) |*c, i| {
        if (c.state == .closed and c.id == -1) {
            c.* = .{};
            c.id = @intCast(i);
            c.local_port = next_port;
            next_port +%= 1;
            if (next_port < 10000) next_port = 12345;
            return c;
        }
    }
    return null;
}

pub fn findConnectionByRemote(src_ip: [4]u8, src_port: u16, dst_port: u16) ?*Connection {
    for (&connections) |*c| {
        if (c.state != .closed and
            c.remote_ip[0] == src_ip[0] and c.remote_ip[1] == src_ip[1] and
            c.remote_ip[2] == src_ip[2] and c.remote_ip[3] == src_ip[3] and
            c.remote_port == src_port and c.local_port == dst_port)
        {
            return c;
        }
    }
    return null;
}

pub fn findListeningConnection(src_port: u16) ?*Connection {
    for (&connections) |*c| {
        if (c.state == .closed and c.local_port == src_port) {
            return c;
        }
    }
    return null;
}

pub fn handlePacket(frame: []const u8, ihl: usize) void {
    if (frame.len < 14 + ihl + 20) return;
    const tcp_data = frame[14 + ihl ..];
    const tcp_hdr_len = @as(usize, (@as(u8, tcp_data[12]) >> 4)) * 4;

    const src_port = (@as(u16, tcp_data[0]) << 8) | tcp_data[1];
    const dst_port = (@as(u16, tcp_data[2]) << 8) | tcp_data[3];
    const seq = (@as(u32, tcp_data[4]) << 24) | (@as(u32, tcp_data[5]) << 16) |
        (@as(u32, tcp_data[6]) << 8) | tcp_data[7];
    const flags = tcp_data[13];

    const src_ip = [4]u8{ frame[26], frame[27], frame[28], frame[29] };

    const conn = findConnectionByRemote(src_ip, src_port, dst_port) orelse {
        return;
    };

    if (flags & 0x02 != 0 and flags & 0x10 == 0) { // SYN
        if (conn.state == .closed) {
            conn.state = .syn_received;
            conn.remote_port = src_port;
            conn.remote_ip = src_ip;
            conn.ack_num = seq + 1;

            vga.setColor(.light_green, .black);
            vga.write("[TCP] SYN received, sending SYN-ACK\n");
            vga.setColor(.white, .black);

            sendPacket(conn, 0x12, null);
            conn.seq_num += 1;
        }
    } else if (flags & 0x02 != 0 and flags & 0x10 != 0) { // SYN+ACK
        if (conn.state == .syn_sent) {
            conn.ack_num = seq + 1;
            conn.seq_num += 1;
            conn.state = .established;
            conn.retx_active = false;

            vga.setColor(.light_green, .black);
            vga.write("[TCP] Connection established!\n");
            vga.setColor(.white, .black);

            sendPacket(conn, 0x10, null); // ACK
        }
    } else if (flags & 0x10 != 0 and flags & 0x02 == 0) { // ACK
        switch (conn.state) {
            .syn_received => {
                conn.state = .established;
                conn.retx_active = false;
                vga.setColor(.light_green, .black);
                vga.write("[TCP] Connection established!\n");
                vga.setColor(.white, .black);
            },
            .established => {
                // Check if FIN flag is set below
            },
            .fin_wait_1 => {
                conn.state = .fin_wait_2;
                conn.retx_active = false;
                vga.write("[TCP] FIN_WAIT_2\n");
            },
            .last_ack => {
                conn.state = .closed;
                conn.retx_active = false;
                vga.write("[TCP] Connection closed (LAST_ACK)\n");
            },
            else => {},
        }
    }

    // FIN
    if (flags & 0x01 != 0) {
        switch (conn.state) {
            .established => {
                conn.ack_num = seq + 1;
                conn.state = .close_wait;
                vga.write("[TCP] FIN received, sending ACK\n");
                sendPacket(conn, 0x10, null); // ACK
            },
            .fin_wait_2 => {
                conn.ack_num = seq + 1;
                sendPacket(conn, 0x10, null); // ACK
                conn.state = .time_wait;
                conn.retx_last = timer.ticks;
                conn.retx_count = 0;
                vga.write("[TCP] TIME_WAIT\n");
            },
            else => {},
        }
    }

    // RST
    if (flags & 0x04 != 0) {
        conn.state = .closed;
        conn.retx_active = false;
        vga.write("[TCP] RST received\n");
    }

    // Data
    if (tcp_hdr_len < tcp_data.len and tcp_hdr_len + 14 + ihl < frame.len) {
        const data = frame[14 + ihl + tcp_hdr_len ..];
        if (data.len > 0 and conn.state == .established) {
            conn.ack_num += @intCast(data.len);
            const copy_len = @min(data.len, conn.rx_buf.len - conn.rx_len);
            @memcpy(conn.rx_buf[conn.rx_len..][0..copy_len], data[0..copy_len]);
            conn.rx_len += copy_len;
            conn.rx_ready = true;
            sendPacket(conn, 0x10, null); // ACK
        }
    }
}

fn buildTcpHeader(conn: *Connection, flags_val: u8, payload_len: u16, buf: []u8) void {
    const tcp_off = 0;
    buf[tcp_off + 0] = @intCast(conn.local_port >> 8);
    buf[tcp_off + 1] = @intCast(conn.local_port & 0xFF);
    buf[tcp_off + 2] = @intCast(conn.remote_port >> 8);
    buf[tcp_off + 3] = @intCast(conn.remote_port & 0xFF);
    buf[tcp_off + 4] = @intCast(conn.seq_num >> 24);
    buf[tcp_off + 5] = @intCast((conn.seq_num >> 16) & 0xFF);
    buf[tcp_off + 6] = @intCast((conn.seq_num >> 8) & 0xFF);
    buf[tcp_off + 7] = @intCast(conn.seq_num & 0xFF);
    buf[tcp_off + 8] = @intCast(conn.ack_num >> 24);
    buf[tcp_off + 9] = @intCast((conn.ack_num >> 16) & 0xFF);
    buf[tcp_off + 10] = @intCast((conn.ack_num >> 8) & 0xFF);
    buf[tcp_off + 11] = @intCast(conn.ack_num & 0xFF);
    buf[tcp_off + 12] = 0x50; // Data offset (5 * 4 = 20)
    buf[tcp_off + 13] = flags_val;
    buf[tcp_off + 14] = 0x00;
    buf[tcp_off + 15] = 0x3C; // Window size 60

    // Pseudo header + TCP checksum
    const cs = ip_mod.checksumPseudo(net.our_ip, conn.remote_ip, 6, buf[tcp_off..][0 .. 20 + payload_len]);
    buf[tcp_off + 16] = @intCast(cs >> 8);
    buf[tcp_off + 17] = @intCast(cs & 0xFF);
}

fn sendPacket(conn: *Connection, flags_val: u8, payload: ?[]const u8) void {
    const dst_mac = net.resolveMac(conn.remote_ip) orelse net.gateway_mac;

    var tx_buf: [42 + 1500]u8 align(16) = undefined;
    @memset(&tx_buf, 0);

    const data_len: u16 = if (payload) |p| @intCast(p.len) else 0;
    const tcp_hdr_len: u16 = 20;
    const ip_total = 20 + tcp_hdr_len + data_len;

    // Ethernet
    @memcpy(tx_buf[0..6], &dst_mac);
    @memcpy(tx_buf[6..12], &net.our_mac);
    tx_buf[12] = 0x08;
    tx_buf[13] = 0x00;

    // IP
    ip_mod.buildHeader(net.our_ip, conn.remote_ip, 6, ip_total, tx_buf[14..34]);

    // TCP header
    buildTcpHeader(conn, flags_val, data_len, tx_buf[34..54]);

    // Payload
    if (payload) |p| {
        @memcpy(tx_buf[54..][0..p.len], p);
    }

    e1000.transmit(tx_buf[0 .. 54 + data_len]);

    // Save for retransmission (only data-carrying packets)
    if (data_len > 0 and (flags_val & 0x02 == 0)) {
        @memcpy(conn.retx_buf[0..][0 .. 54 + data_len], tx_buf[0 .. 54 + data_len]);
        conn.retx_len = 54 + data_len;
        conn.retx_flags = flags_val;
        conn.retx_dst_ip = conn.remote_ip;
        conn.retx_dst_port = conn.remote_port;
        conn.retx_last = timer.ticks;
        conn.retx_count = 0;
        conn.retx_active = true;
    } else {
        conn.retx_active = false;
    }
}

pub fn retxTick() void {
    for (&connections) |*c| {
        if (c.retx_active and c.retx_len > 0 and c.state == .established) {
            const elapsed = timer.ticks -% c.retx_last;
            if (elapsed >= RETX_TIMEOUT) {
                if (c.retx_count < RETX_MAX) {
                    const dst_mac = net.resolveMac(c.retx_dst_ip) orelse net.gateway_mac;
                    // Patch MAC in saved buffer
                    @memcpy(c.retx_buf[0..6], &dst_mac);
                    e1000.transmit(c.retx_buf[0..c.retx_len]);
                    c.retx_last = timer.ticks;
                    c.retx_count += 1;

                    port_io.serialWrite("[TCP] Retransmit #");
                    port_io.serialWriteDec(c.retx_count);
                    port_io.serialWrite("\n");
                } else {
                    vga.setColor(.light_red, .black);
                    vga.write("[TCP] Retransmission limit reached, closing connection\n");
                    vga.setColor(.white, .black);
                    c.state = .closed;
                    c.retx_active = false;
                }
            }
        }
    }
}

pub fn connect(dst_ip: [4]u8, dst_port_val: u16) *Connection {
    const conn = allocConnection() orelse {
        vga.setColor(.light_red, .black);
        vga.write("[TCP] No free connections\n");
        vga.setColor(.white, .black);
        unreachable;
    };

    conn.remote_ip = dst_ip;
    conn.remote_port = dst_port_val;
    conn.seq_num = 0x1000;

    vga.write("[TCP] Connecting to ");
    net.printIp(dst_ip);
    vga.write(":");
    vga.writeDec(dst_port_val);
    vga.write("...\n");

    sendPacket(conn, 0x02, null); // SYN
    conn.state = .syn_sent;

    return conn;
}

pub fn send(conn: *Connection, data: []const u8) void {
    if (conn.state != .established) return;
    sendPacket(conn, 0x18, data); // PSH+ACK
    conn.seq_num += @intCast(data.len);
}

pub fn close(conn: *Connection) void {
    if (conn.state == .established) {
        sendPacket(conn, 0x11, null); // FIN+ACK
        conn.state = .fin_wait_1;
        conn.retx_last = timer.ticks;
        conn.retx_count = 0;
        vga.write("[TCP] Sending FIN\n");
    } else if (conn.state == .close_wait) {
        sendPacket(conn, 0x11, null); // FIN+ACK
        conn.state = .last_ack;
        vga.write("[TCP] Sending FIN (close_wait)\n");
    }
}

pub fn disconnect(conn: *Connection) void {
    conn.state = .closed;
    conn.rx_len = 0;
    conn.rx_ready = false;
    conn.retx_active = false;
    conn.id = -1;
}

pub fn resetState(conn: *Connection) void {
    conn.rx_len = 0;
    conn.rx_ready = false;
}

// Legacy API — default connection (id 0) for backward compat with http.zig
var default_conn_idx: usize = 0;

fn getDefaultConn() *Connection {
    return &connections[default_conn_idx];
}

pub const state: *TcpState = &connections[0].state;
pub const seq_num: *u32 = &connections[0].seq_num;
pub const ack_num: *u32 = &connections[0].ack_num;
pub const remote_port: *u16 = &connections[0].remote_port;
pub const local_port: *u16 = &connections[0].local_port;
pub const remote_ip: *[4]u8 = &connections[0].remote_ip;
pub const rx_ready: *bool = &connections[0].rx_ready;
pub const rx_data: []u8 = &connections[0].rx_buf;
pub const rx_len: *usize = &connections[0].rx_len;

pub fn legacyConnect(dst_ip: [4]u8, dst_port_val: u16) bool {
    const conn = connect(dst_ip, dst_port_val);
    default_conn_idx = @intCast(conn.id);

    var timeout: u32 = 0;
    while (timeout < 200 and conn.state != .established) : (timeout += 1) {
        net.poll();
        var j: u32 = 0;
        while (j < 100000) : (j += 1) {
            asm volatile ("nop");
        }
    }

    return conn.state == .established;
}

pub fn legacySend(data: []const u8) void {
    send(getDefaultConn(), data);
}

pub fn legacyClose() void {
    close(getDefaultConn());
}

pub fn legacyResetState() void {
    resetState(getDefaultConn());
}

pub fn connections_list() []Connection {
    return &connections;
}

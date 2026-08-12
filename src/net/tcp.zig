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
/// Largest TCP payload we put in one segment. 1440 keeps the Ethernet frame
/// (14 + 20 + 20 + 1440 = 1494) inside the 1500-byte MTU and inside `retx_buf`.
pub const MSS: usize = 1440;

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
    syn_sent_at: u64 = 0,
    syn_retries: u32 = 0,
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
    if (tcp_hdr_len < 20 or 14 + ihl + tcp_hdr_len > frame.len) return;

    const src_port = (@as(u16, tcp_data[0]) << 8) | tcp_data[1];
    const dst_port = (@as(u16, tcp_data[2]) << 8) | tcp_data[3];
    const seq = (@as(u32, tcp_data[4]) << 24) | (@as(u32, tcp_data[5]) << 16) |
        (@as(u32, tcp_data[6]) << 8) | tcp_data[7];
    const flags = tcp_data[13];

    const src_ip = [4]u8{ frame[26], frame[27], frame[28], frame[29] };

    const conn = findConnectionByRemote(src_ip, src_port, dst_port) orelse {
        return;
    };

    const data_len: usize = if (tcp_hdr_len < tcp_data.len) tcp_data.len - tcp_hdr_len else 0;

    // Data — accept before the FIN/RST state transitions so a data+FIN
    // segment (typical HTTP/1.x close) is received, not dropped.
    if (data_len > 0 and (conn.state == .established or conn.state == .close_wait)) {
        if (seq == conn.ack_num) {
            // In-order segment: append and advance the ack.
            conn.ack_num = seq +% @as(u32, @intCast(data_len));
            const copy_len = @min(data_len, conn.rx_buf.len - conn.rx_len);
            @memcpy(conn.rx_buf[conn.rx_len..][0..copy_len], tcp_data[tcp_hdr_len..][0..copy_len]);
            conn.rx_len += copy_len;
            conn.rx_ready = true;
            sendPacket(conn, 0x10, null); // ACK
        } else {
            // Retransmission or out-of-order. The old code appended blindly and
            // set ack_num from the incoming seq, which duplicated bytes in
            // rx_buf and could rewind the ack. Just re-ACK what we have.
            sendPacket(conn, 0x10, null);
        }
    }

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
            conn.retx_len = 0;

            vga.setColor(.light_green, .black);
            vga.write("[TCP] Connection established!\n");
            vga.setColor(.white, .black);

            port_io.serialWrite("[TCP] Connection established\n");

            sendPacket(conn, 0x10, null); // ACK
        }
    } else if (flags & 0x10 != 0 and flags & 0x02 == 0) { // ACK
        switch (conn.state) {
            .syn_received => {
                conn.state = .established;
                conn.retx_active = false;
                conn.retx_len = 0;
                vga.setColor(.light_green, .black);
                vga.write("[TCP] Connection established!\n");
                vga.setColor(.white, .black);
                port_io.serialWrite("[TCP] Connection established\n");
            },
            .established, .close_wait => {
                // Peer acknowledges our data — stop retransmitting.
                conn.retx_active = false;
                conn.retx_len = 0;
            },
            .fin_wait_1 => {
                conn.state = .fin_wait_2;
                conn.retx_active = false;
                conn.retx_len = 0;
                vga.write("[TCP] FIN_WAIT_2\n");
            },
            .last_ack => {
                conn.state = .closed;
                conn.retx_active = false;
                conn.retx_len = 0;
                vga.write("[TCP] Connection closed (LAST_ACK)\n");
            },
            else => {},
        }
    }

    // FIN
    if (flags & 0x01 != 0) {
        switch (conn.state) {
            .established, .close_wait => {
                conn.ack_num = seq +% @as(u32, @intCast(data_len)) +% 1;
                conn.state = .close_wait;
                vga.write("[TCP] FIN received, sending ACK\n");
                sendPacket(conn, 0x10, null); // ACK
            },
            .fin_wait_2 => {
                conn.ack_num = seq +% @as(u32, @intCast(data_len)) +% 1;
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
        conn.retx_len = 0;
        vga.write("[TCP] RST received\n");
        port_io.serialWrite("[TCP] RST received\n");
    }
}

fn buildTcpHeader(conn: *Connection, flags_val: u8, payload_len: u16, segment: []u8) void {
    segment[0] = @intCast(conn.local_port >> 8);
    segment[1] = @intCast(conn.local_port & 0xFF);
    segment[2] = @intCast(conn.remote_port >> 8);
    segment[3] = @intCast(conn.remote_port & 0xFF);
    segment[4] = @intCast(conn.seq_num >> 24);
    segment[5] = @intCast((conn.seq_num >> 16) & 0xFF);
    segment[6] = @intCast((conn.seq_num >> 8) & 0xFF);
    segment[7] = @intCast(conn.seq_num & 0xFF);
    segment[8] = @intCast(conn.ack_num >> 24);
    segment[9] = @intCast((conn.ack_num >> 16) & 0xFF);
    segment[10] = @intCast((conn.ack_num >> 8) & 0xFF);
    segment[11] = @intCast(conn.ack_num & 0xFF);
    segment[12] = 0x50; // Data offset (5 * 4 = 20)
    segment[13] = flags_val;

    // Advertise available receive space (dynamic sliding window)
    const free_space = conn.rx_buf.len - @min(conn.rx_len, conn.rx_buf.len);
    const winsize: u32 = @min(65535, @as(u32, @intCast(free_space)));
    segment[14] = @intCast((winsize >> 8) & 0xFF);
    segment[15] = @intCast(winsize & 0xFF);

    // Checksum must cover header + payload, so the payload has to already be in
    // `segment`. The previous version was handed only the 20 header bytes and
    // computed the checksum before the payload was copied: it read past the end
    // of its slice (a bounds panic in Debug) and summed zeros in ReleaseFast, so
    // every data segment we sent carried a wrong checksum and the peer dropped
    // it — HTTP requests were never answered.
    segment[16] = 0;
    segment[17] = 0;
    const cs = ip_mod.checksumPseudo(net.our_ip, conn.remote_ip, 6, segment[0 .. 20 + payload_len]);
    segment[16] = @intCast(cs >> 8);
    segment[17] = @intCast(cs & 0xFF);
}

var tx_buf: [14 + 20 + 20 + MSS]u8 align(16) = undefined;

fn sendPacket(conn: *Connection, flags_val: u8, payload: ?[]const u8) void {
    const dst_mac = net.nextHopMac(conn.remote_ip) orelse {
        port_io.serialWrite("[TCP] Dropping segment: next hop MAC unknown\n");
        return;
    };

    const data_len: u16 = if (payload) |p| @intCast(@min(p.len, MSS)) else 0;
    const tcp_hdr_len: u16 = 20;
    const ip_total = 20 + tcp_hdr_len + data_len;
    const frame_len: usize = 34 + tcp_hdr_len + data_len;

    @memset(tx_buf[0..frame_len], 0);

    // Ethernet
    @memcpy(tx_buf[0..6], &dst_mac);
    @memcpy(tx_buf[6..12], &net.our_mac);
    tx_buf[12] = 0x08;
    tx_buf[13] = 0x00;

    // IP
    ip_mod.buildHeader(net.our_ip, conn.remote_ip, 6, ip_total, tx_buf[14..34]);

    // Payload first, then the header (whose checksum covers the payload).
    if (payload) |p| {
        @memcpy(tx_buf[54..][0..data_len], p[0..data_len]);
    }
    buildTcpHeader(conn, flags_val, data_len, tx_buf[34..frame_len]);

    e1000.transmit(tx_buf[0..frame_len]);

    // Save for retransmission (only data-carrying packets)
    if (data_len > 0 and (flags_val & 0x02 == 0)) {
        @memcpy(conn.retx_buf[0..frame_len], tx_buf[0..frame_len]);
        conn.retx_len = frame_len;
        conn.retx_flags = flags_val;
        conn.retx_dst_ip = conn.remote_ip;
        conn.retx_dst_port = conn.remote_port;
        conn.retx_last = timer.ticks;
        conn.retx_count = 0;
        conn.retx_active = true;
    } else if (data_len > 0) {
        conn.retx_active = false;
    }
}

pub fn retxTick() void {
    for (&connections) |*c| {
        if (c.retx_active and c.retx_len > 0 and c.state == .established) {
            const elapsed = timer.ticks -% c.retx_last;
            if (elapsed >= RETX_TIMEOUT) {
                if (c.retx_count < RETX_MAX) {
                    // Patch the MAC in the saved buffer in case ARP changed.
                    if (net.nextHopMac(c.retx_dst_ip)) |dst_mac| {
                        @memcpy(c.retx_buf[0..6], &dst_mac);
                    }
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

pub fn openConn(conn: *Connection, dst_ip: [4]u8, dst_port_val: u16) void {
    conn.remote_ip = dst_ip;
    conn.remote_port = dst_port_val;
    conn.seq_num = initialSeq();
    conn.ack_num = 0;
    conn.rx_len = 0;
    conn.rx_ready = false;
    conn.retx_active = false;
    conn.retx_len = 0;
    conn.retx_count = 0;

    vga.write("[TCP] Connecting to ");
    net.printIp(dst_ip);
    vga.write(":");
    vga.writeDec(dst_port_val);
    vga.write("...\n");

    port_io.serialWrite("[TCP] Connecting to ");
    net.printIpSerial(dst_ip);
    port_io.serialWrite(":");
    port_io.serialWriteDec(dst_port_val);
    port_io.serialWrite("...\n");

    // Resolve the next hop (the host itself on-link, otherwise the gateway) so
    // the SYN goes to a real unicast MAC instead of broadcast, which QEMU's
    // slirp drops.
    _ = net.ensureArp(net.nextHop(dst_ip));

    conn.state = .syn_sent;
    conn.syn_sent_at = timer.ticks;
    conn.syn_retries = 0;
    sendPacket(conn, 0x02, null); // SYN
}

/// Vary the ISN per connection: a fixed 0x1000 made a reconnect to the same
/// host:port look like a duplicate of the previous connection to the peer.
fn initialSeq() u32 {
    isn_counter +%= 0x9E3779B9;
    return isn_counter ^ @as(u32, @truncate(timer.ticks *% 2654435761));
}

var isn_counter: u32 = 0x1000;

/// Allocate a connection and start the handshake. Returns null when all
/// connection slots are in use — the old version hit `unreachable`, which is a
/// kernel panic in Debug and UB in ReleaseFast.
pub fn connect(dst_ip: [4]u8, dst_port_val: u16) ?*Connection {
    const conn = allocConnection() orelse {
        vga.setColor(.light_red, .black);
        vga.write("[TCP] No free connections\n");
        vga.setColor(.white, .black);
        port_io.serialWrite("[TCP] No free connections\n");
        return null;
    };

    openConn(conn, dst_ip, dst_port_val);

    return conn;
}

/// Block until the handshake completes (or a timeout). Returns true when
/// established, false on timeout or RST/connection failure.
pub fn waitEstablished(conn: *Connection, timeout_ticks: u64) bool {
    const deadline = timer.ticks +% timeout_ticks;
    while (timer.ticks < deadline) {
        if (conn.state == .established) return true;
        if (conn.state == .closed) return false;
        net.poll();

        // Retransmit the SYN: a lost SYN (very common while the gateway ARP is
        // still settling) used to make the whole connect time out silently.
        if (conn.state == .syn_sent and
            timer.ticks -% conn.syn_sent_at >= 100 and // 1s
            conn.syn_retries < 3)
        {
            conn.syn_retries += 1;
            conn.syn_sent_at = timer.ticks;
            port_io.serialWrite("[TCP] Retransmitting SYN\n");
            sendPacket(conn, 0x02, null);
        }
    }
    return conn.state == .established;
}

pub fn send(conn: *Connection, data: []const u8) void {
    if (conn.state != .established) return;

    // Segment anything larger than one MSS. The old version handed the whole
    // slice to sendPacket, which built a single oversized frame (silently
    // truncated by the NIC at 2048 bytes and overflowing retx_buf at 1500).
    var off: usize = 0;
    while (off < data.len) {
        const chunk_len = @min(MSS, data.len - off);
        const chunk = data[off .. off + chunk_len];
        sendPacket(conn, 0x18, chunk); // PSH+ACK
        conn.seq_num +%= @intCast(chunk_len);
        off += chunk_len;

        // Give the peer a chance to ACK between segments so the single
        // retransmission slot is not immediately overwritten.
        if (off < data.len) net.poll();
    }
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

pub fn connections_list() []Connection {
    return &connections;
}

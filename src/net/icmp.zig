const root = @import("root");
const vga = root.vga;
const port = root.serial;
const net = @import("mod.zig");
const ip_mod = @import("ip.zig");
const e1000 = @import("../drivers/e1000.zig");
const timer = @import("../drivers/timer.zig");

pub var last_rtt: u32 = 0;
pub var last_rtt_ms: u32 = 0;

var reply_buf: [1514]u8 align(16) = undefined;
var ping_buf: [98]u8 align(16) = undefined;
var ping_send_tick: u64 = 0;
var ping_id: u16 = 0;

pub fn handlePacket(frame: []const u8, ihl: usize) void {
    if (frame.len < 14 + ihl + 8) return;
    const icmp_data = frame[14 + ihl ..];
    const icmp_type = icmp_data[0];

    if (icmp_type == 0x08) { // Echo Request
        sendReply(frame, ihl);
    } else if (icmp_type == 0x00) { // Echo Reply
        // Identifier lives at ICMP offset 4..6 (6..8 is the sequence number).
        // Reading the sequence number here meant our own replies never matched
        // and `ping` always printed "timeout".
        const reply_id = (@as(u16, icmp_data[4]) << 8) | icmp_data[5];
        if (reply_id == ping_id) {
            const elapsed = timer.ticks -% ping_send_tick;
            last_rtt_ms = @intCast(@min(elapsed * 10, 0xFFFFFFFF)); // ticks * 10ms
            last_rtt = 1;
        }
        port.serialWrite("[ICMP] Reply received\n");
    }
}

fn sendReply(request_frame: []const u8, ihl: usize) void {
    const src_ip = [4]u8{ request_frame[26], request_frame[27], request_frame[28], request_frame[29] };

    const icmp_req = request_frame[14 + ihl ..];
    // Mirror the request payload: replying with a fixed 64-byte ICMP message to
    // an arbitrary-sized ping made the IP total_len wrong and the checksum
    // cover uninitialized bytes.
    const icmp_len = @min(icmp_req.len, reply_buf.len - 34);
    if (icmp_len < 8) return;

    const dst_mac = net.nextHopMac(src_ip) orelse return;

    const frame_len = 34 + icmp_len;
    @memset(reply_buf[0..frame_len], 0);

    @memcpy(reply_buf[0..6], &dst_mac);
    @memcpy(reply_buf[6..12], &net.our_mac);
    reply_buf[12] = 0x08;
    reply_buf[13] = 0x00;

    ip_mod.buildHeader(net.our_ip, src_ip, 1, @intCast(20 + icmp_len), reply_buf[14..34]);

    reply_buf[34] = 0x00; // Echo Reply Type
    reply_buf[35] = 0x00; // Code
    reply_buf[36] = 0x00; // Checksum High
    reply_buf[37] = 0x00; // Checksum Low

    // Copy the request's id/seq/payload verbatim (everything after type/code/csum)
    @memcpy(reply_buf[38..][0 .. icmp_len - 4], icmp_req[4..icmp_len]);

    const cs = ip_mod.checksum(reply_buf[34..frame_len]);
    reply_buf[36] = @intCast(cs >> 8);
    reply_buf[37] = @intCast(cs & 0xFF);

    e1000.transmit(reply_buf[0..frame_len]);
}

pub fn ping(target: [4]u8, count: u32) void {
    // ICMP echo: 8-byte header + 56 bytes of payload = 64, the usual ping size.
    const icmp_len: usize = 64;
    const frame_len: usize = 34 + icmp_len;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        last_rtt = 0;
        last_rtt_ms = 0;
        ping_id +%= 1;

        const target_mac = net.nextHopMac(target) orelse {
            vga.setColor(.light_red, .black);
            vga.write("  ARP failed for ");
            net.printIp(target);
            vga.write("\n");
            vga.setColor(.white, .black);
            return;
        };

        @memset(ping_buf[0..frame_len], 0);

        @memcpy(ping_buf[0..6], &target_mac);
        @memcpy(ping_buf[6..12], &net.our_mac);
        ping_buf[12] = 0x08;
        ping_buf[13] = 0x00;

        ip_mod.buildHeader(net.our_ip, target, 1, @intCast(20 + icmp_len), ping_buf[14..34]);

        ping_buf[34] = 0x08; // Type: Echo Request
        ping_buf[35] = 0x00; // Code
        ping_buf[36] = 0x00;
        ping_buf[37] = 0x00; // Checksum
        ping_buf[38] = @intCast(ping_id >> 8);
        ping_buf[39] = @intCast(ping_id & 0xFF); // ID
        ping_buf[40] = @intCast((i >> 8) & 0xFF);
        ping_buf[41] = @intCast(i & 0xFF); // Sequence

        // Payload: a recognizable pattern rather than zeros
        var p: usize = 42;
        while (p < frame_len) : (p += 1) {
            ping_buf[p] = @intCast('a' + (p - 42) % 26);
        }

        const cs = ip_mod.checksum(ping_buf[34..frame_len]);
        ping_buf[36] = @intCast(cs >> 8);
        ping_buf[37] = @intCast(cs & 0xFF);

        ping_send_tick = timer.ticks;
        e1000.transmit(ping_buf[0..frame_len]);

        vga.write("  Pinging ");
        net.printIp(target);
        vga.write(" ... ");

        // Tick-based 1s deadline instead of a nop-count spin, which ran at a
        // wildly different rate between Debug and ReleaseFast.
        const deadline = timer.ticks +% 100;
        while (timer.ticks < deadline and last_rtt == 0) {
            net.poll();
        }

        if (last_rtt != 0) {
            vga.setColor(.light_green, .black);
            vga.write("reply received time=");
            vga.writeDec(last_rtt_ms);
            vga.write("ms\n");
        } else {
            vga.setColor(.light_red, .black);
            vga.write("timeout\n");
        }
        vga.setColor(.white, .black);
    }
}

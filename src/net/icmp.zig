const root = @import("root");
const vga = root.vga;
const port = root.serial;
const net = @import("mod.zig");
const ip_mod = @import("ip.zig");
const e1000 = @import("../drivers/e1000.zig");

pub var last_rtt: u32 = 0;

var reply_buf: [98]u8 align(16) = undefined;
var ping_buf: [98]u8 align(16) = undefined;

pub fn handlePacket(frame: []const u8, ihl: usize) void {
    if (frame.len < 14 + ihl + 8) return;
    const icmp_data = frame[14 + ihl ..];
    const icmp_type = icmp_data[0];

    if (icmp_type == 0x08) { // Echo Request
        sendReply(frame, ihl);
    } else if (icmp_type == 0x00) { // Echo Reply
        last_rtt = 1;
        port.serialWrite("[ICMP] Reply received\n");
    }
}

fn sendReply(request_frame: []const u8, ihl: usize) void {
    const src_ip = [4]u8{ request_frame[26], request_frame[27], request_frame[28], request_frame[29] };

    @memset(&reply_buf, 0);

    reply_buf[0] = net.gateway_mac[0]; reply_buf[1] = net.gateway_mac[1];
    reply_buf[2] = net.gateway_mac[2]; reply_buf[3] = net.gateway_mac[3];
    reply_buf[4] = net.gateway_mac[4]; reply_buf[5] = net.gateway_mac[5];
    reply_buf[6] = net.our_mac[0]; reply_buf[7] = net.our_mac[1];
    reply_buf[8] = net.our_mac[2]; reply_buf[9] = net.our_mac[3];
    reply_buf[10] = net.our_mac[4]; reply_buf[11] = net.our_mac[5];
    reply_buf[12] = 0x08; reply_buf[13] = 0x00;

    ip_mod.buildHeader(net.our_ip, src_ip, 1, 64, reply_buf[14..34]);

    reply_buf[34] = 0x00; // Echo Reply Type
    reply_buf[35] = 0x00; // Code
    reply_buf[36] = 0x00; // Checksum High
    reply_buf[37] = 0x00; // Checksum Low

    const req_icmp_len = request_frame.len - (14 + ihl);
    const copy_len = @min(req_icmp_len - 4, 60);
    @memcpy(reply_buf[38..][0..copy_len], request_frame[14 + ihl + 4 ..][0..copy_len]);

    const cs = ip_mod.checksum(reply_buf[34..98]);
    reply_buf[36] = @intCast(cs >> 8);
    reply_buf[37] = @intCast(cs & 0xFF);

    e1000.transmit(reply_buf[0..98]);
}

pub fn ping(target: [4]u8, count: u32) void {
    _ = net.ensureArp(target);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        last_rtt = 0;

        @memset(&ping_buf, 0);

        ping_buf[0] = net.gateway_mac[0]; ping_buf[1] = net.gateway_mac[1];
        ping_buf[2] = net.gateway_mac[2]; ping_buf[3] = net.gateway_mac[3];
        ping_buf[4] = net.gateway_mac[4]; ping_buf[5] = net.gateway_mac[5];
        ping_buf[6] = net.our_mac[0]; ping_buf[7] = net.our_mac[1];
        ping_buf[8] = net.our_mac[2]; ping_buf[9] = net.our_mac[3];
        ping_buf[10] = net.our_mac[4]; ping_buf[11] = net.our_mac[5];
        ping_buf[12] = 0x08; ping_buf[13] = 0x00;

        ip_mod.buildHeader(net.our_ip, target, 1, 64, ping_buf[14..34]);

        ping_buf[34] = 0x08; // Type: Echo Request
        ping_buf[35] = 0x00; // Code
        ping_buf[36] = 0x00; ping_buf[37] = 0x00; // Checksum
        ping_buf[38] = 0x00; ping_buf[39] = 0x01; // ID
        ping_buf[40] = @intCast(i >> 8);
        ping_buf[41] = @intCast(i & 0xFF); // Sequence

        const cs = ip_mod.checksum(ping_buf[34..98]);
        ping_buf[36] = @intCast(cs >> 8);
        ping_buf[37] = @intCast(cs & 0xFF);

        e1000.transmit(ping_buf[0..98]);

        vga.write("  Pinging ");
        net.printIp(target);
        vga.write(" ... ");

        var timeout: u32 = 0;
        while (timeout < 100 and last_rtt == 0) : (timeout += 1) {
            net.poll();
            var j: u32 = 0;
            while (j < 50000) : (j += 1) {
                asm volatile ("nop");
            }
        }

        if (last_rtt != 0) {
            vga.setColor(.light_green, .black);
            vga.write("reply received\n");
        } else {
            vga.setColor(.light_red, .black);
            vga.write("timeout\n");
        }
        vga.setColor(.white, .black);
    }
}

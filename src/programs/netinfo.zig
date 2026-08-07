const root = @import("root");
const vga = root.vga;
const port_io = root.serial;
const pci = @import("../drivers/pci.zig");
const e1000 = @import("../drivers/e1000.zig");
const net = @import("../net/mod.zig");
const tcp = @import("../net/tcp.zig");
const arp_cache = @import("../net/arp_cache.zig");
const dhcp_mod = @import("../net/dhcp.zig");

pub fn run() void {
    vga.setColor(.cyan, .black);
    vga.write("\n=== Network Info ===\n\n");

    vga.setColor(.white, .black);
    vga.write("  MAC:      ");
    e1000.printMacVga();
    vga.write("\n");

    vga.write("  Our IP:   ");
    net.printIp(net.our_ip);
    if (dhcp_mod.lease_valid) {
        vga.setColor(.light_green, .black);
        vga.write(" (DHCP)");
    }
    vga.setColor(.white, .black);
    vga.write("\n");

    vga.write("  Gateway:  ");
    net.printIp(net.gateway_ip);
    vga.write("\n");

    vga.write("  GW MAC:   ");
    if (net.mac_known) {
        const h = "0123456789ABCDEF";
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            if (i > 0) vga.putChar(':');
            vga.putChar(h[net.gateway_mac[i] >> 4]);
            vga.putChar(h[net.gateway_mac[i] & 0xF]);
        }
    } else {
        vga.setColor(.light_red, .black);
        vga.write("(not resolved)");
    }
    vga.setColor(.white, .black);
    vga.write("\n\n");

    // Show TCP connections
    vga.setColor(.yellow, .black);
    vga.write("  TCP Connections:\n");
    vga.setColor(.white, .black);

    var any_active = false;
    for (tcp.connections_list()) |*c| {
        if (c.state != .closed) {
            any_active = true;
            vga.write("    [");
            vga.writeDec(@intCast(c.id));
            vga.write("] ");
            net.printIp(c.remote_ip);
            vga.putChar(':');
            vga.writeDec(c.remote_port);
            vga.write(" -> ");
            vga.writeDec(c.local_port);
            vga.write("  ");
            switch (c.state) {
                .closed => vga.write("CLOSED"),
                .syn_sent => vga.write("SYN_SENT"),
                .syn_received => vga.write("SYN_RECEIVED"),
                .established => vga.write("ESTABLISHED"),
                .fin_wait_1 => vga.write("FIN_WAIT_1"),
                .fin_wait_2 => vga.write("FIN_WAIT_2"),
                .close_wait => vga.write("CLOSE_WAIT"),
                .last_ack => vga.write("LAST_ACK"),
                .time_wait => vga.write("TIME_WAIT"),
            }
            if (c.retx_active) {
                vga.setColor(.yellow, .black);
                vga.write(" [retx]");
                vga.setColor(.white, .black);
            }
            vga.write("\n");
        }
    }

    if (!any_active) {
        vga.write("    (none)\n");
    }
    vga.write("\n");

    // Show ARP cache
    arp_cache.printCache();
}

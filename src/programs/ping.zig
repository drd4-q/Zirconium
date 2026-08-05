const root = @import("root");
const vga = root.vga;
const kb = @import("../drivers/keyboard.zig");
const net = @import("../net/mod.zig");
const icmp = @import("../net/icmp.zig");

pub fn run(args: []const u8) void {
    if (args.len == 0) {
        // Ping gateway by default
        vga.write("  Pinging gateway ");
        net.printIp(net.gateway_ip);
        vga.write(" ...\n\n");
        icmp.ping(net.gateway_ip, 4);
        return;
    }

    // Parse IP from args
    var ip: [4]u8 = .{ 0, 0, 0, 0 };
    var part: usize = 0;
    var val: u32 = 0;
    for (args) |ch| {
        if (ch == '.') {
            ip[part] = @intCast(val);
            part += 1;
            val = 0;
        } else if (ch >= '0' and ch <= '9') {
            val = val * 10 + (ch - '0');
        }
    }
    if (part < 4) ip[part] = @intCast(val);

    vga.write("  Pinging ");
    net.printIp(ip);
    vga.write(" ...\n\n");
    icmp.ping(ip, 4);
}

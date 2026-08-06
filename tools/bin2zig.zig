const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();

    const allocator = init.arena.allocator();

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    // Skip executable name
    _ = it.next();

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-i")) {
            if (it.next()) |val| {
                input_path = try allocator.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, arg, "-o")) {
            if (it.next()) |val| {
                output_path = try allocator.dupe(u8, val);
            }
        }
    }

    if (input_path == null or output_path == null) {
        std.debug.print("Usage: bin2zig -i <input_file> -o <output_file>\n", .{});
        std.process.exit(1);
    }

    const debug_io = std.Options.debug_io;
    const dir = std.Io.Dir.cwd();

    // Read input file
    const infile = try dir.openFile(debug_io, input_path.?, .{});
    defer infile.close(debug_io);

    const size = try infile.length(debug_io);
    const content = try allocator.alloc(u8, size);
    defer allocator.free(content);
    _ = try infile.readPositionalAll(debug_io, content, 0);

    // Create output file
    const outfile = try dir.createFile(debug_io, output_path.?, .{});
    defer outfile.close(debug_io);

    var out_pos: u64 = 0;
    _ = try outfile.writePositionalAll(debug_io, "pub const data = [_]u8{\n", out_pos);
    out_pos += "pub const data = [_]u8{\n".len;

    var chunk_buf: [4096]u8 = undefined;
    var chunk_len: usize = 0;

    for (content, 0..) |b, idx| {
        const hex_str = try std.fmt.bufPrint(chunk_buf[chunk_len..], "0x{x:0>2}, ", .{b});
        chunk_len += hex_str.len;

        if ((idx + 1) % 12 == 0) {
            chunk_buf[chunk_len] = '\n';
            chunk_len += 1;
        }

        if (chunk_len > chunk_buf.len - 32) {
            _ = try outfile.writePositionalAll(debug_io, chunk_buf[0..chunk_len], out_pos);
            out_pos += chunk_len;
            chunk_len = 0;
        }
    }

    if (chunk_len > 0) {
        _ = try outfile.writePositionalAll(debug_io, chunk_buf[0..chunk_len], out_pos);
        out_pos += chunk_len;
    }

    _ = try outfile.writePositionalAll(debug_io, "\n};\n", out_pos);
}

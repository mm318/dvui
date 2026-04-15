const std = @import("std");
const svg2tvg = @import("svg2tvg");

pub fn main(init: std.process.Init) !void {
    return impl(init);
}

fn impl(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();

    _ = args.next();
    const input_path = args.next() orelse {
        std.debug.print("Usage: svg2tvg <svg file> -o <output file>\n", .{});
        return error.NoInputArg;
    };
    // this should be '-o' but we just ignore it
    _ = args.next() orelse return error.NoOutputFlag;
    const output_path = args.next() orelse {
        std.debug.print("Usage: svg2tvg <svg file> -o <output file>\n", .{});
        return error.NoOutputArg;
    };

    errdefer {
        std.debug.print("error: input_path='{s}' output_path='{s}'\n", .{ input_path, output_path });
    }

    const svg_bytes = try cwd.readFileAlloc(io, input_path, gpa, .limited(1 << 16));
    defer gpa.free(svg_bytes);
    const tvg_bytes = try svg2tvg.tvg_from_svg(gpa, svg_bytes, .{});
    defer gpa.free(tvg_bytes);
    try cwd.writeFile(io, .{
        .sub_path = output_path,
        .data = tvg_bytes,
    });
}

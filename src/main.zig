const std = @import("std");
const posix = std.posix;
const zpython = @import("zpython");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const file_arg: ?[]const u8 = if (args.len > 1) args[1] else null;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);

    var interp = try zpython.interpreter.Interpreter.init(gpa, &output);
    defer interp.deinit();

    if (file_arg) |path| {
        const source = try readFileAllocPosix(gpa, path);
        defer gpa.free(source);

        interp.evalSource(source) catch |err| {
            std.debug.print("Runtime error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        // One-shot file: AST no longer needed
        interp.freeAst();
        interp.freeRuntime();

        if (output.items.len > 0) {
            _ = std.c.write(posix.STDOUT_FILENO, output.items.ptr, output.items.len);
        }
    } else {
        std.debug.print("zpython 0.1.0 (Zig 0.16) — minimal Python interpreter\n", .{});
        std.debug.print("Type 'exit()' or Ctrl-D to quit.\n\n", .{});

        var buf: [4096]u8 = undefined;

        while (true) {
            std.debug.print(">>> ", .{});

            const n = std.c.read(posix.STDIN_FILENO, &buf, buf.len);
            if (n <= 0) {
                std.debug.print("\n", .{});
                break;
            }

            var end: usize = 0;
            while (end < @as(usize, @intCast(n)) and buf[end] != '\n') : (end += 1) {}
            const line = buf[0..end];

            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (std.mem.eql(u8, trimmed, "exit()") or std.mem.eql(u8, trimmed, "quit()")) break;

            var source_buf: std.ArrayList(u8) = .empty;
            defer source_buf.deinit(gpa);
            try source_buf.appendSlice(gpa, trimmed);
            try source_buf.append(gpa, '\n');

            if (std.mem.endsWith(u8, trimmed, ":")) {
                while (true) {
                    std.debug.print("... ", .{});
                    const n2 = std.c.read(posix.STDIN_FILENO, &buf, buf.len);
                    if (n2 <= 0) break;
                    var end2: usize = 0;
                    while (end2 < @as(usize, @intCast(n2)) and buf[end2] != '\n') : (end2 += 1) {}
                    const cont = buf[0..end2];
                    const cont_trimmed = std.mem.trimEnd(u8, cont, "\r\n");
                    if (cont_trimmed.len == 0) break;
                    try source_buf.appendSlice(gpa, cont_trimmed);
                    try source_buf.append(gpa, '\n');
                }
            }

            output.clearRetainingCapacity();
            interp.evalSource(source_buf.items) catch |err| {
                std.debug.print("Error: {s}\n", .{@errorName(err)});
                continue;
            };

            if (output.items.len > 0) {
                _ = std.c.write(posix.STDOUT_FILENO, output.items.ptr, output.items.len);
            }
        }
    }
}

fn readFileAllocPosix(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = try posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        try list.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return try list.toOwnedSlice(allocator);
}

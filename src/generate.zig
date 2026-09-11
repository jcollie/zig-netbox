// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie
// SPDX-License-Identifier: MIT

const std = @import("std");

const openapi2zig = @import("openapi2zig");

const log = std.log.scoped(.generate);

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const alloc = init.gpa;

    var stdin_buf: [1024]u8 = undefined;
    var stdin_file: std.Io.File = .stdin();
    var stdin_reader = stdin_file.reader(io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    var content: std.Io.Writer.Allocating = .init(alloc);
    defer content.deinit();

    _ = try stdin.streamRemaining(&content.writer);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_file: std.Io.File = .stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const args = openapi2zig.CliArgs{
        .input_path = "api.json",
        .output_path = "api.zig",
        .parameters_as_struct = true,
        // NetBox declares a choice list on most status and type fields, and on
        // the filters for them. Without this they would all be []const u8.
        .generate_enums = true,
    };

    var unified_doc = try openapi2zig.parseToUnified(alloc, content.written());
    defer unified_doc.deinit(alloc);

    const generated = try openapi2zig.generateCode(alloc, io, unified_doc, args);
    defer alloc.free(generated);

    try stdout.writeAll(generated);
    try stdout.flush();

    return 0;
}

const std = @import("std");
const mecha = @import("mecha");

const name = blk: {
    var md5: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash("", &md5, .{});
    const hex = std.fmt.bytesToHex(md5, .lower);
    break :blk hex;
};

const atom_type = enum(u3) { number, string, ident, array, sexp };

/// S-Expression structure
/// sexp := (head:ident param:atom*)
const sexp = struct {
    head: []const u8,
    param: []const atom,
    pub fn format(s: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("(");
        try writer.writeAll(s.head);
        for (s.param) |p| {
            try writer.writeAll(" ");
            try writer.print("{f}", .{p});
        }
        try writer.writeAll(")");
    }
};

fn mapIdent(s: []const u8) atom {
    return .{ .ident = s };
}

fn mapNumber(n: i64) atom {
    return .{ .number = n };
}

fn mapSexp(n: sexp) atom {
    return .{ .sexp = n };
}

fn mapArray(n: []const atom) atom {
    return .{ .array = n };
}

const atom = union(atom_type) {
    number: i64,
    string: []const u8,
    ident: []const u8,
    array: []const atom,
    sexp: sexp,
    pub fn format(s: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (s) {
            .number => |n| try writer.print("{d}", .{n}),
            .string => |str| try writer.print("\"{s}\"", .{str}),
            .ident => |id| try writer.print("{s}", .{id}),
            .array => |vs| {
                try writer.print("'(", .{});
                for (vs) |v| {
                    try writer.print(" {f}", .{v});
                }
                try writer.print(" )", .{});
            },
            .sexp => |sexp_val| try writer.print("{f}", .{sexp_val}),
        }
    }
};

const c = mecha.combine(.{ mecha.ascii.alphabetic, mecha.many(mecha.oneOf(.{ mecha.ascii.alphanumeric, mecha.ascii.char('_') }), .{ .collect = false }) });
const ident_s = mecha.asStr(c);
const special_s = mecha.asStr(mecha.combine(.{ c, mecha.ascii.char('!') }));
const fun_ident = mecha.oneOf(.{ special_s, ident_s });

const wd = mecha.ascii.whitespace.many(.{ .collect = false }).discard();

const sexp_parser = mecha.recursiveRef(struct {
    fn f(comptime _sexp_parser: mecha.Parser(sexp)) mecha.Parser(sexp) {
        const atom_parser = mecha.recursiveRef(struct {
            fn f(comptime _atom_parser: mecha.Parser(atom)) mecha.Parser(atom) {
                const array_parser = mecha.combine(.{ mecha.ascii.char('\'').discard(), mecha.ascii.char('(').discard(), wd, mecha.many(_atom_parser, .{ .separator = wd }), wd, mecha.ascii.char(')').discard() }).map(mapArray);
                const atom_parser_inner = mecha.oneOf(.{ mecha.int(i64, .{}).map(mapNumber), ident_s.map(mapIdent), array_parser });

                return mecha.oneOf(.{ atom_parser_inner, _sexp_parser.map(mapSexp) });
            }
        }.f);

        const sexp_parser_inner = mecha.combine(.{
            mecha.ascii.char('(').discard(),
            wd,
            fun_ident,
            wd,
            mecha.many(atom_parser, .{ .separator = wd }),
            wd,
            mecha.ascii.char(')').discard(),
        }).map(mecha.toStruct(sexp));

        return sexp_parser_inner;
    }
}.f);

const program_parser = mecha.many(sexp_parser, .{ .separator = wd });
const file_parser = mecha.combine(.{ wd, program_parser, wd, mecha.eos.discard() });

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };

    try s.beginObject();

    try s.objectField("targets");
    try s.beginArray();

    try s.beginObject();
    try s.objectField("name");
    try s.write("Stage");

    try s.objectField("variables");
    try s.beginObject();
    try s.endObject();

    try s.objectField("isStage");
    try s.write(true);

    try s.objectField("blocks");
    try s.beginObject();
    try s.endObject();

    try s.objectField("costumes");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("assetId");
    try s.write(name);
    try s.objectField("dataFormat");
    try s.write("png");
    try s.objectField("name");
    try s.write(name);
    try s.endObject();

    try s.endArray();

    try s.objectField("sounds");
    try s.beginArray();
    try s.endArray();

    try s.endObject();

    try s.endArray();

    // try s.objectField("monitors");
    // try s.beginArray();
    // try s.endArray();

    // try s.objectField("extensions");
    // try s.beginArray();
    // try s.endArray();

    try s.objectField("meta");
    try s.beginObject();

    try s.objectField("semver");
    try s.write("3.0.0");

    // try s.objectField("vm");
    // try s.write("12.0.2-hotfix");

    // try s.objectField("agent");
    // try s.write("scratchcc");

    try s.endObject();
    try s.endObject();

    std.log.debug("resulting json: {s}", .{out.writer.buffered()});

    var current_off: u32 = 0;

    var outZip = std.Io.Writer.Allocating.init(allocator);
    defer outZip.deinit();

    const Entry = struct { crc: u32, offset: u32 };
    const File = struct { name: []const u8, file: []const u8 };

    const files = [_]File{
        .{ .name = "project.json", .file = out.writer.buffered() },
        .{ .name = &name, .file = "" },
    };

    var entries: [files.len]Entry = undefined;

    for (files, 0..) |file, i| {
        try outZip.writer.writeAll(&std.zip.local_file_header_sig);
        try outZip.writer.writeInt(u16, 20, .little);
        try outZip.writer.writeInt(u16, 0, .little);
        try outZip.writer.writeInt(u16, 0, .little);
        try outZip.writer.writeInt(u16, 0, .little);
        try outZip.writer.writeInt(u16, 0, .little);

        const crc32 = std.hash.Crc32.hash(file.file);

        entries[i] = .{ .crc = crc32, .offset = current_off };

        try outZip.writer.writeInt(u32, crc32, .little);

        try outZip.writer.writeInt(u32, @intCast(file.file.len), .little);
        try outZip.writer.writeInt(u32, @intCast(file.file.len), .little);
        try outZip.writer.writeInt(u16, @intCast(file.name.len), .little);
        try outZip.writer.writeInt(u16, 0, .little);

        try outZip.writer.writeAll(file.name);
        try outZip.writer.writeAll(file.file);

        current_off += 30 + @as(u32, @intCast(file.name.len)) + @as(u32, @intCast(file.file.len));
    }

    const cd_offset = current_off;
    var cd_size: u32 = 0;

    for (files, 0..) |file, i| {
        try outZip.writer.writeAll(&std.zip.central_file_header_sig);
        try outZip.writer.writeInt(u16, 20, .little);
        try outZip.writer.writeInt(u16, 20, .little);
        try outZip.writer.writeInt(u16, 0, .little);
        try outZip.writer.writeInt(u16, 0, .little);
        try outZip.writer.writeInt(u16, 0, .little);
        try outZip.writer.writeInt(u16, 0, .little);

        try outZip.writer.writeInt(u32, entries[i].crc, .little);
        try outZip.writer.writeInt(u32, @intCast(file.file.len), .little);
        try outZip.writer.writeInt(u32, @intCast(file.file.len), .little);
        try outZip.writer.writeInt(u16, @intCast(file.name.len), .little);

        try outZip.writer.writeInt(u16, 0, .little);
        try outZip.writer.writeInt(u16, 0, .little);
        try outZip.writer.writeInt(u16, 0, .little);
        try outZip.writer.writeInt(u16, 0, .little);

        try outZip.writer.writeInt(u32, 0, .little);
        try outZip.writer.writeInt(u32, entries[i].offset, .little);

        try outZip.writer.writeAll(file.name);
        cd_size += 46 + @as(u32, @intCast(file.name.len));
    }

    // end record
    try outZip.writer.writeAll(&std.zip.end_record_sig);
    try outZip.writer.writeInt(u16, 0, .little);
    try outZip.writer.writeInt(u16, 0, .little);

    try outZip.writer.writeInt(u16, 2, .little); // count
    try outZip.writer.writeInt(u16, 2, .little); // count

    try outZip.writer.writeInt(u32, cd_size, .little);
    try outZip.writer.writeInt(u32, cd_offset, .little);
    try outZip.writer.writeInt(u16, 0, .little);

    std.log.debug("resulting zip: {x}", .{outZip.writer.buffered()});

    var argv = init.minimal.args.iterate();
    _ = argv.next();

    const filename = argv.next() orelse unreachable;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), init.io, filename, .{ .mode = .read_only });
    defer file.close(init.io);

    std.log.debug("file length: {}", .{try file.length(init.io)});

    var buf: [16]u8 = undefined;
    var reader = file.reader(init.io, &buf);
    const r = try reader.interface.allocRemaining(allocator, std.Io.Limit.unlimited);
    defer allocator.free(r);

    const res = try file_parser.parse(arena.allocator(), r);
    switch (res.value) {
        .ok => |vs| for (vs) |v| std.log.debug("found stmt {f}", .{v}),
        .err => std.log.err("error occured", .{}),
    }
}

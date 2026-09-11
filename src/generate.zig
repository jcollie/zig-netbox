// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie
// SPDX-License-Identifier: MIT

const std = @import("std");

const openapi2zig = @import("openapi2zig");

const log = std.log.scoped(.generate);

/// The `*_id` query filters that NetBox declares as arrays of strings even
/// though they take integer primary keys.
///
/// Each of these filters a foreign key to a model that *nests*, so that
/// asking for a role also matches its descendants. Nearly all of them are
/// models with a `parent` and a `_depth` -- `DeviceRole`, `Location`,
/// `Platform`, `Region`, `SiteGroup`, `TenantGroup`, `ContactGroup`,
/// `WirelessLANGroup` -- which NetBox filters with a
/// `TreeNodeMultipleChoiceFilter` rather than the plain
/// `ModelMultipleChoiceFilter` it uses everywhere else. drf-spectacular
/// cannot introspect that filter down to the model's primary key field, so it
/// falls back to its default of `string`. That is why the very same parameter
/// name is an array of integers on an endpoint whose `role_id` means a rack
/// role and an array of strings on one whose `role_id` means a device role,
/// and why `group_id` is a string on `/api/dcim/sites/` and an integer on
/// `/api/dcim/racks/`. `module_bay_id` is the one that is not an MPTT tree:
/// a `ModuleBay` nests through its `module` instead, but its filter walks the
/// hierarchy the same way and is typed the same way by accident.
///
/// The values the server actually accepts are integer primary keys either
/// way, so these are retyped before the code is generated. What that gives up
/// is the one string these filters really do take: a nullable foreign key --
/// `platform_id`, say -- matches rows where the key is unset when it is given
/// the literal `null`, and NetBox declares no `__empty` variant of these to
/// ask the same question another way. A caller needing that has to build the
/// query itself.
///
/// These families are listed by name rather than every string-typed `*_id`
/// being swept up, because some of those really are strings: `facility_id`,
/// `part_id`, `xconnect_id`, `registry_domain_id`, `soa_zone_id`,
/// `service_id` on `/api/circuits/provider-networks/` and `contact_id` on
/// `/api/plugins/netbox-dns/contacts/` all name text fields that merely end
/// in `_id`.
const tree_fk_filters = [_][]const u8{
    "ancestor_id",         "ancestor_id__n",
    "default_platform_id", "default_platform_id__n",
    "group_id",            "group_id__n",
    "location_id",         "location_id__n",
    "module_bay_id",       "module_bay_id__n",
    "platform_id",         "platform_id__n",
    "region_id",           "region_id__n",
    "role_id",             "role_id__n",
    "site_group_id",       "site_group_id__n",
    "tenant_group_id",     "tenant_group_id__n",
};

/// Rewrites the item type of every `tree_fk_filters` parameter in
/// `parameters` from string to integer, counting each one under the index of
/// the name it matched.
fn retypeParameters(counts: *[tree_fk_filters.len]usize, parameters: ?[]openapi2zig.Parameter) void {
    const params = parameters orelse return;
    for (params) |*param| {
        if (param.location != .query) continue;
        const index = for (tree_fk_filters, 0..) |candidate, index| {
            if (std.mem.eql(u8, param.name, candidate)) break index;
        } else continue;
        const schema = &(param.schema orelse continue);
        const schema_type = schema.type orelse continue;
        if (schema_type != .array) continue;
        const items = schema.items orelse continue;
        if (items.type != .string) continue;
        items.type = .integer;
        counts[index] += 1;
    }
}

/// Applies `tree_fk_filters` to every operation in `doc`, and answers the name
/// of the first entry that matched nothing at all -- which means NetBox has
/// either fixed or renamed that filter, and the entry should be removed rather
/// than left to make a promise it no longer keeps. This is the same safety as
/// `--replace-fail` in a Nix `substituteInPlace`: the day upstream changes,
/// the generator stops rather than quietly generating something else.
fn retypeTreeForeignKeyFilters(doc: *openapi2zig.UnifiedDocument) ?[]const u8 {
    var counts: [tree_fk_filters.len]usize = @splat(0);

    var paths = doc.paths.iterator();
    while (paths.next()) |entry| {
        const path_item = entry.value_ptr;
        inline for (.{ "get", "put", "post", "delete", "options", "head", "patch" }) |method| {
            if (@field(path_item.*, method)) |*operation| {
                retypeParameters(&counts, operation.parameters);
            }
        }
        retypeParameters(&counts, path_item.parameters);
    }

    for (counts, tree_fk_filters) |count, name| {
        if (count == 0) return name;
    }
    return null;
}

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

    if (retypeTreeForeignKeyFilters(&unified_doc)) |unmatched| {
        log.err("no string typed `{s}` query parameter left in the schema; " ++
            "drop it from `tree_fk_filters`", .{unmatched});
        return 1;
    }

    const generated = try openapi2zig.generateCode(alloc, io, unified_doc, args);
    defer alloc.free(generated);

    try stdout.writeAll(generated);
    try stdout.flush();

    return 0;
}

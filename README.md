<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie
SPDX-License-Identifier: MIT
-->

# zig-netbox

Zig bindings for the [NetBox](https://netboxlabs.com/docs/netbox/) REST API,
generated from the OpenAPI specification that NetBox publishes.

Nothing in this repository is written by hand. `api/api.json` is NetBox's own
schema, and the Zig is produced from it at build time, so the bindings track
whatever version of the schema is checked in rather than drifting from it.

**API documentation: <https://jeff.jcollie.page/zig-netbox/>** — generated from
the doc comments and from the generated source itself, and published from
`main` by CI.

## What is generated

The checked-in schema is **NetBox REST API 4.6.9 (4.6)**: 339 paths and 1146
component schemas, which come out as roughly 2000 public types and 3600
functions.

For each operation the generator emits three functions. Taking
`dcim_devices_list` as the example:

| Function | Returns | Use it when |
| --- | --- | --- |
| `dcim_devices_list` | `Owned(PaginatedDeviceWithConfigContextList)` | You want the parsed body and are happy for a non-2xx status to be `error.ResponseError`. |
| `dcim_devices_listResult` | `ApiResult(PaginatedDeviceWithConfigContextList)` | You need to tell an API error from a parse error, and to read the error body. |
| `dcim_devices_listRaw` | `RawResponse` | You want the status and bytes and will do your own parsing. |

Query and path parameters arrive as a single options struct —
`dcim_devices_listOptions` — rather than as a long positional argument list.

`Owned(T)` holds the response body, the `std.json.Parsed(T)` that borrows from
it, and the allocator; call `deinit()` on it and the pair goes away together.
`ApiResult(T)` is a tagged union of `ok`, `api_error` and `parse_error`, and
also has a `deinit()` that frees whichever arm is live.

## Using it

Add the dependency:

```console
zig fetch --save git+https://git.jcollie.dev/jeff/zig-netbox.git
```

and wire the module up in `build.zig`:

```zig
const netbox_dep = b.dependency("netbox", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("netbox", netbox_dep.module("netbox"));
```

### Authentication

The key passed to `Client.init` becomes the `Authorization` header **verbatim**,
so the scheme prefix is part of it. NetBox's schema documents the two it accepts:
`Token <token>` for a v1 token and `Bearer <key>.<token>` for a v2 one. A bare
token with no prefix is not one of them.

```zig
const netbox = @import("netbox");

// The prefix is part of the key, not something the client adds.
var client: netbox.Client = .init(gpa, io, "Token 0123456789abcdef");
defer client.deinit();

client.withBaseUrl("https://netbox.example.com");

var devices = try netbox.dcim_devices_list(&client, .{
    .limit = 50,
    .site_id = &.{ 1, 2 },
});
defer devices.deinit();

for (devices.value().results) |device| {
    std.debug.print("{s}\n", .{device.name orelse "(unnamed)"});
}
```

An empty key suppresses the header entirely, which is how you reach an endpoint
that takes no authentication.

`Client.init` takes an allocator, an `std.Io` and the key; the base URL is set
separately and defaults to the empty string, so a client that is never given
one will make requests against a relative path and fail in a confusing way.

The `Client` struct also carries `organization` and `project` fields that emit
`OpenAI-Organization` and `OpenAI-Project` headers. NetBox has no use for
either — they are the generator's own furniture, and leaving them null is
correct.

### Filters that take several values

Most NetBox filters accept more than one value, and the generated field is a
slice — `site_id: ?[]const i64`, `name: ?[]const []const u8`. Each element is
sent as a repeat of the key, which is what NetBox reads as "any of these":

```zig
.{ .site_id = &.{ 1, 2 } }   //  ?site_id=1&site_id=2
```

Filters that genuinely take one value stay scalar: `limit` is `?i64`, `brief`
is `?bool`.

### Fields with a fixed set of values

A choice list becomes a Zig enum — 153 of them, covering 214 fields and
filters — so a wrong value is a compile error rather than a 400:

```zig
var devices = try netbox.dcim_devices_list(&client, .{ .face = .front });
```

The tag **is** the wire value, escaped where it is not a bare identifier, so
nothing is lost in translation and nothing has to be looked up:

```zig
pub const FaceEnum = enum { front, @"null", rear };
```

`@"null"` is not the absence of a value — it is NetBox's literal string
`"null"`, which its filters accept to mean "has none". An absent value is the
`?` on the field.

On the response side NetBox wraps a choice in a `{value, label}` object, so the
enum is a field deeper down:

```zig
pub const PrefixStatus = struct {
    value: ?StatusEnum = null,
    label: ?LabelEnum20 = null,
};

if (prefix.status) |status| {
    if (status.value == .active) { ... }
}
```

Two kinds of choice list stay `[]const u8`, because neither can use its values
as tag names: one containing the empty string, since `@""` is not a legal Zig
identifier, and one whose values are not strings. NetBox allows blank on many
of the writable and `{value, label}` variants, so a field can be an enum in one
place and a string in another — `dcim_devices_list`'s `face` filter is a
`?FaceEnum` while `DeviceWithConfigContextFace.value` is a `?[]const u8`.

Some array filters carry an `x-spec-enum-id` but no values at all, and there is
nothing to build a type from in that case; those stay `?[]const []const u8`.

## How the generation works

`build.zig` builds `src/generate.zig` into a small executable, feeds
`api/api.json` to it on standard input, and captures its standard output as
`api.zig`. That captured file — never written into the source tree — is the
root source of the `netbox` module, and is also installed to `zig-out/api.zig`
so it can be read when something needs explaining.

The generator itself is a thin driver around
[openapi2zig](https://github.com/christianhelle/openapi2zig); `src/generate.zig`
parses the schema into openapi2zig's unified document and asks it for code,
with `parameters_as_struct` on, which is what produces the options structs
described above.

The dependency points at [a fork](https://github.com/jcollie/openapi2zig)
rather than at upstream, for three changes this schema needs. Upstream maps
every `type: array` query parameter to `[]const u8`, which covers 77% of
NetBox's parameters and leaves no way to send more than one value; it flattens
the one-member `allOf` that OpenAPI 3.0 requires for a nullable `$ref`, which
copies the target's fields under a name built from the enclosing type and the
property — thirteen of those collided with real schemas and the result did not
compile; and it ignores `enum` entirely.

Enum generation is off by default there and turned on by `src/generate.zig`.
The grouping uses `x-spec-enum-id`, the marker drf-spectacular writes to say
which schemas share a choice set — worth knowing about because the values alone
do not settle it. The same set appears with a `null` variant added or not
depending on whether it is a nullable field or a filter, so 44 of NetBox's 100
ids turn up with two or three different value lists; the generator takes their
union.

Upgrading to a new NetBox release is therefore a matter of replacing
`api/api.json` with the schema from that release. A running NetBox will hand
you its own:

```console
curl -o api/api.json https://netbox.example.com/api/schema/?format=json
```

Regenerating takes a while and a fair amount of memory — the schema is 14 MB,
and the Zig that comes out of it is about 6 MB.

## Building

```console
nix develop            # Zig 0.16, reuse, git-pages-cli
zig build              # generates api.zig and installs it
zig build test         # runs the module's tests
zig build docs         # writes the API documentation to zig-out/docs
```

The documentation has to be **served over HTTP, not opened as a file**: the
viewer is a WebAssembly program that fetches `sources.tar` and `main.wasm` at
runtime, and a browser refuses both from a `file://` page. Point any static
server at `zig-out/docs`, or read the published copy linked above.

The dev shell sets `SSL_CERT_FILE` explicitly, because the CI runners have no
system CA bundle and Zig's TLS cannot fetch dependencies without one.

## Where this lives

The canonical repository is on Forgejo, with a mirror on GitHub:

```console
git clone https://git.jcollie.dev/jeff/zig-netbox.git
git clone https://github.com/jcollie/zig-netbox.git
```

It is also on [Radicle](https://radicle.xyz/), where its Repository ID is

    rad:z3mWmgeb7htjXzgjbr5F9PyoXx9p

and that ID is the only way to find it, since Radicle has no central index to
search:

```console
rad clone rad:z3mWmgeb7htjXzgjbr5F9PyoXx9p
```

## Licensing

This project follows the [REUSE](https://reuse.software/) standard, and
`nix develop -c reuse lint` is part of CI.

The code here is MIT. `api/api.json` is NetBox's schema and is Apache-2.0,
copyright NetBox Labs; the Zig generated from it inherits that. Full texts are
in `LICENSES/`.

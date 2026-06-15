// Session manifest: durable on-disk record of a live zmx session so that
// `zmx restore` can re-spawn it after a reboot.
//
// Lifecycle:
//   - written by the daemon child after spawnPty() succeeds
//   - removed only when the user explicitly kills the session
//     (handleKill sets Daemon.user_killed = true; the deferred cleanup
//      reads that flag). SIGTERM / system-shutdown leaves the manifest
//     in place so a later `zmx restore` can recover the session.
//
// Layout: {socket_dir}/manifest/{session_name}.json
//
// We intentionally keep task-mode sessions (`zmx run -d ...`) out of the
// manifest: they exit when their command exits and have no shell to restore.

const std = @import("std");
const posix = std.posix;

pub const Manifest = struct {
    version: u32 = 1,
    name: []const u8,
    cwd: []const u8,
    /// argv to exec on restore. null => use the user's detected shell.
    command: ?[]const []const u8 = null,
    created_at_ns: u64,
};

fn manifestDirPath(alloc: std.mem.Allocator, socket_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/manifest", .{socket_dir});
}

fn manifestFileName(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}.json", .{name});
}

fn ensureManifestDir(socket_dir: []const u8, dir_path: []const u8, dir_mode: u32) !void {
    _ = socket_dir;
    posix.mkdirat(posix.AT.FDCWD, dir_path, @intCast(dir_mode)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Write the manifest atomically: write to "{name}.json.tmp" then rename.
pub fn writeManifest(
    alloc: std.mem.Allocator,
    socket_dir: []const u8,
    dir_mode: u32,
    manifest: Manifest,
) !void {
    const dir_path = try manifestDirPath(alloc, socket_dir);
    defer alloc.free(dir_path);
    try ensureManifestDir(socket_dir, dir_path, dir_mode);

    var dir = try std.fs.openDirAbsolute(dir_path, .{});
    defer dir.close();

    const final_name = try manifestFileName(alloc, manifest.name);
    defer alloc.free(final_name);
    const tmp_name = try std.fmt.allocPrint(alloc, "{s}.tmp", .{final_name});
    defer alloc.free(tmp_name);

    var file = try dir.createFile(tmp_name, .{ .truncate = true });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var w = file.writer(&buf);
    try std.json.Stringify.value(manifest, .{ .whitespace = .indent_2 }, &w.interface);
    try w.interface.flush();

    try dir.rename(tmp_name, final_name);
}

/// Remove a session's manifest. Missing file is not an error.
pub fn removeManifest(
    alloc: std.mem.Allocator,
    socket_dir: []const u8,
    name: []const u8,
) !void {
    const dir_path = try manifestDirPath(alloc, socket_dir);
    defer alloc.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    const final_name = try manifestFileName(alloc, name);
    defer alloc.free(final_name);

    dir.deleteFile(final_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

// ----------------------------------------------------------------------------
// Snapshot: VT terminal state dump that `zmx restore` replays into a fresh
// ghostty-vt to rehydrate scrollback + cursor for a recovered session.
//
// Layout: {socket_dir}/snapshots/{session_name}.vt  (raw VT escape bytes)
// ----------------------------------------------------------------------------

fn snapshotDirPath(alloc: std.mem.Allocator, socket_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/snapshots", .{socket_dir});
}

fn snapshotFileName(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}.vt", .{name});
}

/// Write VT-encoded terminal state atomically.
pub fn writeSnapshot(
    alloc: std.mem.Allocator,
    socket_dir: []const u8,
    dir_mode: u32,
    name: []const u8,
    vt_data: []const u8,
) !void {
    const dir_path = try snapshotDirPath(alloc, socket_dir);
    defer alloc.free(dir_path);
    posix.mkdirat(posix.AT.FDCWD, dir_path, @intCast(dir_mode)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dir = try std.fs.openDirAbsolute(dir_path, .{});
    defer dir.close();

    const final_name = try snapshotFileName(alloc, name);
    defer alloc.free(final_name);
    const tmp_name = try std.fmt.allocPrint(alloc, "{s}.tmp", .{final_name});
    defer alloc.free(tmp_name);

    var file = try dir.createFile(tmp_name, .{ .truncate = true });
    defer file.close();
    try file.writeAll(vt_data);

    try dir.rename(tmp_name, final_name);
}

pub fn removeSnapshot(
    alloc: std.mem.Allocator,
    socket_dir: []const u8,
    name: []const u8,
) !void {
    const dir_path = try snapshotDirPath(alloc, socket_dir);
    defer alloc.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    const final_name = try snapshotFileName(alloc, name);
    defer alloc.free(final_name);
    dir.deleteFile(final_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// Read a snapshot file into a freshly-allocated buffer. Caller frees.
/// Returns null if the file is missing.
pub fn readSnapshot(
    alloc: std.mem.Allocator,
    socket_dir: []const u8,
    name: []const u8,
) !?[]u8 {
    const dir_path = try snapshotDirPath(alloc, socket_dir);
    defer alloc.free(dir_path);
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close();

    const final_name = try snapshotFileName(alloc, name);
    defer alloc.free(final_name);

    const max_size: usize = 64 * 1024 * 1024; // 64 MiB cap — scrollback for very long sessions
    return dir.readFileAlloc(alloc, final_name, max_size) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// Owned manifest list. Caller must call deinit() to free the backing arena.
/// All slice fields inside `items` live in the arena.
pub const ManifestList = struct {
    items: []Manifest,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *ManifestList) void {
        const child_alloc = self.arena.child_allocator;
        self.arena.deinit();
        child_alloc.destroy(self.arena);
    }
};

/// Read every manifest file under {socket_dir}/manifest. Caller deinits.
/// Files that fail to parse are logged and skipped.
pub fn readAll(alloc: std.mem.Allocator, socket_dir: []const u8) !ManifestList {
    const arena_ptr = try alloc.create(std.heap.ArenaAllocator);
    errdefer alloc.destroy(arena_ptr);
    arena_ptr.* = std.heap.ArenaAllocator.init(alloc);
    errdefer arena_ptr.deinit();
    const arena = arena_ptr.allocator();

    const dir_path = try manifestDirPath(alloc, socket_dir);
    defer alloc.free(dir_path);

    var items: std.ArrayList(Manifest) = .empty;

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{
            .items = try arena.alloc(Manifest, 0),
            .arena = arena_ptr,
        },
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const max_size: usize = 64 * 1024;
        const contents = dir.readFileAlloc(arena, entry.name, max_size) catch |err| {
            std.log.warn("manifest read failed file={s} err={s}", .{ entry.name, @errorName(err) });
            continue;
        };

        const manifest = std.json.parseFromSliceLeaky(Manifest, arena, contents, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.warn("manifest parse failed file={s} err={s}", .{ entry.name, @errorName(err) });
            continue;
        };
        try items.append(arena, manifest);
    }

    return .{ .items = items.items, .arena = arena_ptr };
}

// ============================================================================
// Tests
// ============================================================================

test "writeManifest then readAll roundtrips a basic session" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const socket_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(socket_dir);

    try writeManifest(alloc, socket_dir, 0o750, .{
        .name = "alpha",
        .cwd = "/tmp/work",
        .command = null,
        .created_at_ns = 12345,
    });

    var list = try readAll(alloc, socket_dir);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("alpha", list.items[0].name);
    try std.testing.expectEqualStrings("/tmp/work", list.items[0].cwd);
    try std.testing.expectEqual(@as(?[]const []const u8, null), list.items[0].command);
}

test "writeManifest persists a command argv" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const socket_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(socket_dir);

    const cmd = [_][]const u8{ "nvim", "/tmp/file" };
    try writeManifest(alloc, socket_dir, 0o750, .{
        .name = "edit",
        .cwd = "/tmp",
        .command = &cmd,
        .created_at_ns = 7,
    });

    var list = try readAll(alloc, socket_dir);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expect(list.items[0].command != null);
    try std.testing.expectEqual(@as(usize, 2), list.items[0].command.?.len);
    try std.testing.expectEqualStrings("nvim", list.items[0].command.?[0]);
}

test "writeSnapshot then readSnapshot roundtrips the VT payload" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const socket_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(socket_dir);

    const payload = "\x1b[H\x1b[2Jhello vt\x1b[0m";
    try writeSnapshot(alloc, socket_dir, 0o750, "alpha", payload);

    const read_back = try readSnapshot(alloc, socket_dir, "alpha");
    try std.testing.expect(read_back != null);
    defer alloc.free(read_back.?);
    try std.testing.expectEqualStrings(payload, read_back.?);
}

test "readSnapshot returns null for a missing session" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const socket_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(socket_dir);

    const result = try readSnapshot(alloc, socket_dir, "absent");
    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "removeManifest is a no-op when the file is missing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const socket_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(socket_dir);

    // Directory does not even exist yet
    try removeManifest(alloc, socket_dir, "ghost");

    // After creating one + removing it, the file is gone
    try writeManifest(alloc, socket_dir, 0o750, .{
        .name = "ghost",
        .cwd = "/",
        .command = null,
        .created_at_ns = 0,
    });
    try removeManifest(alloc, socket_dir, "ghost");

    var list = try readAll(alloc, socket_dir);
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

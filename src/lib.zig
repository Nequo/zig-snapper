// This is a copy of https://github.com/tigerbeetle/tigerbeetle/blob/588123f219f1f3e324f9293ae3975845e087d5f5/src/testing/snaptest.zig

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const SourceLocation = std.builtin.SourceLocation;

comptime {
    assert(builtin.is_test);
}

const update_all: bool = false;

const Cut = struct {
    prefix: []const u8,
    suffix: []const u8,
};

fn cut(haystack: []const u8, needle: []const u8) ?Cut {
    const index = std.mem.indexOf(u8, haystack, needle) orelse return null;

    return Cut{
        .prefix = haystack[0..index],
        .suffix = haystack[index + needle.len ..],
    };
}

pub const Snap = struct {
    location: SourceLocation,
    text: []const u8,
    update_this: bool = false,

    pub fn snap(location: SourceLocation, text: []const u8) Snap {
        return Snap{ .location = location, .text = text };
    }

    pub fn update(snapshot: *const Snap) Snap {
        return Snap{ .location = snapshot.location, .text = snapshot.text, .update_this = true };
    }

    fn should_update(snapshot: *const Snap) bool {
        return snapshot.update_this or update_all or std.process.hasEnvVarConstant("SNAP_UPDATE");
    }

    pub fn diff_fmt(snapshot: *const Snap, comptime fmt: []const u8, fmt_args: anytype) !void {
        const got = try std.fmt.allocPrint(std.testing.allocator, fmt, fmt_args);
        defer std.testing.allocator.free(got);
        try snapshot.diff(got);
    }

    pub fn diff_json(snapshot: *const Snap, value: anytype) !void {
        const got = std.ArrayList(u8).init(std.testing.allocator);
        defer got.deinit();
        try std.json.stringify(value, .{}, got.writer());
        try snapshot.diff(got.items);
    }

    pub fn diff(snapshot: *const Snap, got: []const u8) !void {
        if (equal_excluding_ignored(got, snapshot.text)) return;

        std.debug.print(
            \\Snapshot differs.
            \\Want:
            \\----
            \\{s}
            \\----
            \\Got:
            \\----
            \\{s}
            \\----
        , .{ snapshot.text, got });

        if (!snapshot.should_update()) {
            std.debug.print("Rerun with SNAP_UPDATE=1 to update the snapshot", .{});
            return error.SnapDiff;
        }
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const allocator = arena.allocator();
        const file_text = try std.fs.cwd().readFileAlloc(allocator, snapshot.location.file, 1024 * 1024);
        var file_text_updated = try std.ArrayList(u8).initCapacity(allocator, file_text.len);

        const line_zero_based = snapshot.location.line - 1;
        const range = snap_range(file_text, line_zero_based);

        const snapshot_prefix = file_text[0..range.start];
        const snapshot_text = file_text[range.start..range.end];
        const snapshot_suffix = file_text[range.end..];

        const indent = get_indent(snapshot_text);

        try file_text_updated.appendSlice(snapshot_prefix);
        {
            var lines = std.mem.split(u8, got, "\n");
            while (lines.next()) |line| {
                try file_text_updated.writer().print("{s}\\\\{s}\n", .{ indent, line });
            }
        }
        try file_text_updated.appendSlice(snapshot_suffix);
        try std.fs.cwd().writeFile(snapshot.location.file, file_text_updated.items);
        std.debug.print("Updated {s}\n", .{snapshot.location.file});
        return error.SnapUpdated;
    }
};

fn equal_excluding_ignored(got: []const u8, snapshot: []const u8) bool {
    var got_rest = got;
    var snapshot_rest = snapshot;

    // Don't allow ignoring suffixes and prefixes, as that makes it easy to miss trailing or leading
    // data.
    assert(!std.mem.startsWith(u8, snapshot, "<snap:ignore>"));
    assert(!std.mem.endsWith(u8, snapshot, "<snap:ignore>"));

    for (0..10) |_| {
        // Cut the part before the first ignore, it should be equal between two strings...
        const snapshot_cut = cut(snapshot_rest, "<snap:ignore>") orelse break;
        const got_cut = cut(got_rest, snapshot_cut.prefix) orelse return false;
        if (got_cut.prefix.len != 0) return false;
        got_rest = got_cut.suffix;
        snapshot_rest = snapshot_cut.suffix;

        // ...then find the next part that should match, and cut up to that.
        const next_match = if (cut(snapshot_rest, "<snap:ignore>")) |snapshot_cut_next|
            snapshot_cut_next.prefix
        else
            snapshot_rest;
        assert(next_match.len > 0);
        snapshot_rest = cut(snapshot_rest, next_match).?.suffix;

        const got_cut_next = cut(got_rest, next_match) orelse return false;
        const ignored = got_cut_next.prefix;
        // If <snap:ignore> matched an empty string, or several lines, report it as an error.
        if (ignored.len == 0) return false;
        if (std.mem.indexOf(u8, ignored, "\n") != null) return false;
        got_rest = got_cut_next.suffix;
    } else @panic("more than 10 ignores");

    return std.mem.eql(u8, got_rest, snapshot_rest);
}

test equal_excluding_ignored {
    const TestCase = struct { got: []const u8, snapshot: []const u8 };

    const cases_ok: []const TestCase = &.{
        .{ .got = "ABA", .snapshot = "ABA" },
        .{ .got = "ABBA", .snapshot = "A<snap:ignore>A" },
        .{ .got = "ABBACABA", .snapshot = "AB<snap:ignore>CA<snap:ignore>A" },
    };
    for (cases_ok) |case| {
        try std.testing.expect(equal_excluding_ignored(case.got, case.snapshot));
    }

    const cases_err: []const TestCase = &.{
        .{ .got = "ABA", .snapshot = "ACA" },
        .{ .got = "ABBA", .snapshot = "A<snap:ignore>C" },
        .{ .got = "ABBACABA", .snapshot = "AB<snap:ignore>DA<snap:ignore>BA" },
        .{ .got = "ABBACABA", .snapshot = "AB<snap:ignore>BA<snap:ignore>DA" },
        .{ .got = "ABA", .snapshot = "AB<snap:ignore>A" },
        .{ .got = "A\nB\nA", .snapshot = "A<snap:ignore>A" },
    };
    for (cases_err) |case| {
        try std.testing.expect(!equal_excluding_ignored(case.got, case.snapshot));
    }
}

const Range = struct { start: usize, end: usize };

fn snap_range(text: []const u8, src_line: u32) Range {
    var offset: usize = 0;
    var line_number: u32 = 0;
    var lines = std.mem.split(u8, text, "\n");
    const snap_start = while (lines.next()) |line| : (line_number += 1) {
        if (line_number == src_line) {
            assert(std.mem.indexOf(u8, line, "@src()") != null);
        }
        if (line_number == src_line + 1) {
            assert(is_multiline_string(line));
            break offset;
        }
        offset += line.len + 1;
    } else unreachable;

    lines = std.mem.split(u8, text[snap_start..], "\n");
    const snap_end = while (lines.next()) |line| {
        if (!is_multiline_string(line)) {
            break offset;
        }
        offset += line.len + 1;
    } else unreachable;

    return Range{ .start = snap_start, .end = snap_end };
}

fn is_multiline_string(line: []const u8) bool {
    for (line, 0..) |c, i| {
        switch (c) {
            ' ' => {},
            '\\' => return (i + 1 < line.len and line[i + 1] == '\\'),
            else => return false,
        }
    }
    return false;
}

fn get_indent(line: []const u8) []const u8 {
    for (line, 0..) |c, i| {
        if (c != ' ') return line[0..i];
    }
    return line;
}

test "snapper" {
    try check("", Snap.snap(@src(),
        \\
    ));
    try check("4", Snap.snap(@src(),
        \\4
    ));
    try check(
        \\Some
        \\Multiline
        \\Data structure
    , Snap.snap(@src(),
        \\Some
        \\Multiline
        \\Data structure
    ));
}

/// Pass in your test output as a string and compare to a given snapshot
/// Then run with SNAP_UPDATE=1 to update the snapshot
pub fn check(got: []const u8, want: Snap) !void {
    try want.diff(got);
}

//! Builds an initial file system and computes the super block.

const std = @import("std");
const assert = std.debug.assert;
const File = std.fs.File;

const shared = @import("shared");
const params = shared.params;
const fs = shared.fs;

const log = std.log.scoped(.mkfs);

// Disk layout:
// [ boot block | sb block | log | inode blocks | free bit map | data blocks ]

/// Number of meta blocks (boot, sb, nlog, inode, bitmap).
const NUM_META = 2 + NUM_LOG + NUM_INODE_BLOCKS + NUM_BITMAP;
/// Header followed by LOG_BLOCKS data blocks.
const NUM_LOG = params.LOG_BLOCKS + 1;
const NUM_INODE_BLOCKS = NUM_INODES / fs.IPB + 1;
const NUM_INODES = 200;
const NUM_BITMAP = params.FS_SIZE / fs.BPB + 1;
/// Number of data blocks.
const NUM_BLOCKS = params.FS_SIZE - NUM_META;

const SUPER_BLOCK: fs.SuperBlock = .{
    .magic = fs.FS_MAGIC,
    .size = params.FS_SIZE,
    .num_blocks = NUM_BLOCKS,
    .num_inodes = NUM_INODES,
    .num_log = NUM_LOG,
    .log_start = 2,
    .inode_start = 2 + NUM_LOG,
    .bmap_start = 2 + NUM_LOG + NUM_INODE_BLOCKS,
};
const SUPER_SIZE = @sizeOf(fs.SuperBlock);

/// Next inum that should be allocated.
var next_inum: u16 = fs.ROOT_INUM;
/// First free block that we can allocate.
var next_block: u32 = NUM_META;
/// The output fs image we are creating.
var file: File = undefined;

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();

    const out_file_name = args.next() orelse return error.MissingOutputFileName;
    const out_file = try std.fs.cwd().createFile(
        out_file_name,
        .{ .read = true, .truncate = true },
    );
    defer out_file.close();
    file = out_file;

    log.info("making fs image: `{s}`", .{out_file_name});
    log.info(
        "nmeta {d} (boot, super, log blocks {}, inode blocks {}, bitmap blocks {}) blocks {d} total {d}",
        .{ NUM_META, NUM_LOG, NUM_INODE_BLOCKS, NUM_BITMAP, NUM_BLOCKS, params.FS_SIZE },
    );

    // zero file system image
    const zeroes = std.mem.zeroes([fs.BLOCK_SIZE]u8);
    for (0..params.FS_SIZE) |sect| {
        try writeSect(sect, &zeroes);
    }

    // write super block
    try writeSect(
        1,
        &std.mem.toBytes(SUPER_BLOCK) ++
            [_]u8{0} ** (fs.BLOCK_SIZE - SUPER_SIZE),
    );

    // create root dir
    const root_inum = try allocInode(.dir);
    assert(root_inum == fs.ROOT_INUM);

    const dot: fs.DirEnt = .{
        .inum = root_inum,
        .name = ("." ++ [_]u8{0} ** 13).*,
    };
    try appendToInode(root_inum, std.mem.asBytes(&dot));
    const dotdot: fs.DirEnt = .{
        .inum = root_inum,
        .name = (".." ++ [_]u8{0} ** 12).*,
    };
    try appendToInode(root_inum, std.mem.asBytes(&dotdot));

    // write user files
    while (args.next()) |path| {
        var path_parts = std.mem.splitBackwardsScalar(u8, path, '/');
        const shortName = path_parts.next().?;
        assert(shortName.len <= fs.DIR_NAME_SIZE);

        const inum = try allocInode(.file);

        var dirent: fs.DirEnt = .{
            .inum = inum,
            .name = [_]u8{0} ** fs.DIR_NAME_SIZE,
        };
        @memcpy(dirent.name[0..shortName.len], shortName);
        try appendToInode(root_inum, std.mem.asBytes(&dirent));

        const f = try std.fs.cwd().openFile(
            path,
            .{ .mode = .read_only },
        );
        defer f.close();

        // TODO: could just pass around readers and writers instead of buffers
        var buf: [fs.BLOCK_SIZE]u8 = undefined;
        while (true) {
            const read = try f.read(&buf);
            if (read == 0) {
                break;
            }
            try appendToInode(inum, buf[0..read]);
        }
    }

    // TODO: why does this need to be done?
    // fix size of root inode dir
    var root_inode = try readInode(root_inum);
    root_inode.size = ((root_inode.size / fs.BLOCK_SIZE) + 1) * fs.BLOCK_SIZE;
    try writeInode(root_inum, root_inode);

    // update bitmap
    const used = next_block;
    log.info("first {d} blocks have been allocated", .{used});
    assert(used < fs.BPB);

    var bit_set = std.StaticBitSet(fs.BPB).initEmpty();
    bit_set.setRangeValue(.{ .start = 0, .end = used }, true);
    log.info("write bitmap block at sector {d}", .{SUPER_BLOCK.bmap_start});
    try writeSect(SUPER_BLOCK.bmap_start, std.mem.asBytes(&bit_set));
}

/// Reads the given sector of the disk image into buf.
fn readSect(sect: usize, buf: *[fs.BLOCK_SIZE]u8) !void {
    try file.seekTo(sect * fs.BLOCK_SIZE);
    _ = try file.readAll(buf);
}

// TODO: use new reader/writer interface?
/// Writes buf to the given sector of the disk image.
fn writeSect(sect: usize, buf: *const [fs.BLOCK_SIZE]u8) !void {
    try file.seekTo(sect * fs.BLOCK_SIZE);
    try file.writeAll(buf);
}

/// Allocates an inode of the given type and returns it's inumber.
fn allocInode(ty: fs.FileType) !u16 {
    const inum = next_inum;
    next_inum += 1;

    try writeInode(
        inum,
        std.mem.zeroInit(
            fs.DiskInode,
            .{
                .type = @intFromEnum(ty),
                .num_link = 1,
            },
        ),
    );
    return inum;
}

/// Read the inode with the given inumber from the disk image.
fn readInode(inum: u16) !fs.DiskInode {
    var buf: [fs.BLOCK_SIZE]u8 align(4) = undefined;

    const block_num = SUPER_BLOCK.inodeBlock(inum);
    try readSect(block_num, &buf);

    return std.mem.bytesAsSlice(fs.DiskInode, &buf)[inum % fs.IPB];
}

/// Write inode with the given inumber to the disk image.
fn writeInode(inum: u16, inode: fs.DiskInode) !void {
    const block_num = SUPER_BLOCK.inodeBlock(inum);
    var buf: [fs.BLOCK_SIZE]u8 align(4) = undefined;

    try readSect(block_num, &buf);
    std.mem.bytesAsSlice(fs.DiskInode, &buf)[inum % fs.IPB] = inode;
    try writeSect(block_num, &buf);
}

/// Appends the given bytes to the inode identified by the given inumber.
fn appendToInode(inum: u16, bytes: []const u8) !void {
    var inode = try readInode(inum);
    var p = bytes;
    var off = inode.size;
    log.debug("append inum {d} at off {x} size {d}", .{ inum, off, p.len });

    while (p.len > 0) {
        const block_num = off / fs.BLOCK_SIZE;
        assert(block_num < fs.MAX_FILE_BLOCKS);

        const data_block_num = value: {
            if (block_num < fs.NUM_DIRECT) {
                if (inode.addrs[block_num] == 0) {
                    inode.addrs[block_num] = next_block;
                    next_block += 1;
                }
                break :value inode.addrs[block_num];
            } else {
                if (inode.addrs[fs.NUM_DIRECT] == 0) {
                    inode.addrs[fs.NUM_DIRECT] = next_block;
                    next_block += 1;
                }

                const indirect_block_num = inode.addrs[fs.NUM_DIRECT];
                var indirect: [fs.NUM_INDIRECT]u32 = undefined;
                try readSect(indirect_block_num, std.mem.asBytes(&indirect));

                if (indirect[block_num - fs.NUM_DIRECT] == 0) {
                    indirect[block_num - fs.NUM_DIRECT] = next_block;
                    next_block += 1;
                    try writeSect(indirect_block_num, std.mem.asBytes(&indirect));
                }

                break :value indirect[block_num - fs.NUM_DIRECT];
            }
        };
        log.debug("data block num {x}", .{data_block_num});

        const num_written = @min(p.len, (block_num + 1) * fs.BLOCK_SIZE - off);
        var data_buf: [fs.BLOCK_SIZE]u8 = undefined;
        try readSect(data_block_num, &data_buf);
        @memcpy(data_buf[off - (block_num * fs.BLOCK_SIZE) ..][0..num_written], p);
        try writeSect(data_block_num, &data_buf);

        p = p[num_written..];
        off += num_written;
    }

    log.debug("new off {x}", .{off});
    inode.size = off;
    try writeInode(inum, inode);
}

pub const std_options: std.Options = .{
    .logFn = logFn,
};
pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const tty_conf: std.Io.tty.Config = .detect(.stdout());

    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();

    const color = switch (message_level) {
        .debug => .magenta,
        .info => .blue,
        .warn => .yellow,
        .err => .red,
    };
    tty_conf.setColor(stderr, color) catch {};
    stderr.print(level_txt ++ prefix2, .{}) catch return;
    tty_conf.setColor(stderr, .reset) catch {};
    stderr.print(format ++ "\n", args) catch return;

    stderr.flush() catch return;
}

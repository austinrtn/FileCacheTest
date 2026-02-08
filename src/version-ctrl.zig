const std = @import("std");

const REPO_URL = "https://raw.githubusercontent.com/austinrtn/FileCacheTest/main/";
const CACHE_PATH = "src/file_cache.json";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var args = std.process.args();
    _ = args.next();

    const ROOT_PATH = args.next() orelse return error.RootPathNotFound; 
    var root_dir = try std.fs.cwd().openDir(ROOT_PATH, .{});
    defer root_dir.close();

    var writer_buf: [1024 * 1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&writer_buf);
    const writer = &stdout.interface;

    //Clear Screen
    try writer.writeAll("\x1B[2J");
    try writer.writeAll("\x1B[H");
    try writer.flush();

    var file = try root_dir.openFile(CACHE_PATH, .{});
    defer file.close();
    const file_cache_size = (try file.stat()).size;

    var file_cache_buf: [1024 * 1024]u8 = undefined;
    var file_cache_reader = file.reader(&file_cache_buf);

    try file_cache_reader.seekTo(0);
    try file_cache_reader.interface.fill(file_cache_size);

    const cache_content = try file_cache_reader.interface.readAlloc(allocator, file_cache_size);
    defer allocator.free(cache_content);

    // var json_scanner = std.json.Scanner.initCompleteInput(allocator, cache_content);
    // defer json_scanner.deinit();
    //
    // const parsed = try std.json.parseFromTokenSource(std.json.Value, allocator, &json_scanner, .{});
    // defer parsed.deinit();

    //const json_values = parsed.value.object;
    // const json_obj = json_values.get("src/Fruits/Banana") orelse return error.NotFound;
    // const version_ = json_obj.object.get("version") orelse return error.NotFound;

    var client = std.http.Client{.allocator = allocator};
    defer client.deinit();

    const cache_temp = try root_dir.createFile("cache_temp.zig", .{});
    defer cache_temp.close();

    var redir_buf:[1024 * 1024]u8 = undefined;
    var response_buf:[1024 * 1024]u8 = undefined;
    var response_writer = cache_temp.writer(&response_buf);

    const url = REPO_URL ++ "src/file_cache.json";
    const uri = try std.Uri.parse(url); 

    const result = try client.fetch(.{
        .location = .{.uri = uri},
        .method = .GET,
        .redirect_buffer = &redir_buf,
        .response_writer = &response_writer.interface,
    }); 

    try writer.print("{s}\n", .{url});
    try writer.flush();

    if(result.status != .ok) return error.FailedToDownload;
}


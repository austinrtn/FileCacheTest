const std = @import("std");

// File meta data zig structures
const FileStructure= struct {
    pub const FS_Config = struct {
        name: []const u8,
        root_path: [:0]const u8,
        dir: []const u8,
        files: []const [] const u8,
    };

    const Self = @This();
    name: []const u8,
    dir: []const u8,
    files: []const [] const u8,

    fn init(config: FS_Config) Self{
        return Self{
            .name = config.name,
            .dir = config.dir,
            .files = config.files,
        };
    }
};

// What gets parsed to and from for JSON data
const JsonEntry = struct {
    dir: []const u8,
    file: []const u8,
    mtime: i128,
    version: usize,
};

//***************************
// FILE VERSION ID TRACKER
// **************************
// This script is a demo to keep track of 
// file versions by comparing by caching file metadata 
// and comparing cached file metadata to current file metadata, specifically 
// the data last modified.  
// If the date last modified of the cached file metadata does NOT match the 
// date last modified of the current file, then the version for that file is updated in the cache, 
// and the user is notifed.
//
// This demo will be extrapolated for Prescient to keep track of files that need to be updated so that
// only files that have been modified since the last version of Prescient get updated as opposed to 
// the entire engine 

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();

    //Allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    //STDOUT INTERFACE
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout.interface;

    //GET ROOT PATH / DIRECTORY
    const root_path = args.next() orelse return error.NoRootPath;
    var root_dir = try std.fs.cwd().openDir(root_path, .{});
    defer root_dir.close();

    //Clear Screen
    try writer.writeAll("\x1B[2J");
    try writer.writeAll("\x1B[H");
    try writer.flush();

    // Where the json entries will get stored until file is written
    var cached_results = std.ArrayList(JsonEntry){};
    defer cached_results.deinit(allocator);

    const json_cache_file = root_dir.openFile("src/cache.json", .{});
    if(json_cache_file) |cache_file| {
        // Where names of modified files live
        var modified_files = std.ArrayList([]const u8){};
        defer modified_files.deinit(allocator);

        // Reader interface to read cache.json
        var cache_reader_buf: [1024 * 1024]u8 = undefined;
        var cache_reader = cache_file.reader(&cache_reader_buf);
        const file_size = (try cache_file.stat()).size;

        // Fill file reader with contents of file
        try cache_reader.interface.fill(file_size);
        const cache_content = cache_reader_buf[0..file_size];

        // Scan file contents for json 
        var scanner = std.json.Scanner.initCompleteInput(allocator, cache_content);
        defer scanner.deinit();

        // Parse json into JsonEntry Struct 
        const parsed = try std.json.parseFromTokenSource([]JsonEntry, allocator, &scanner, .{});
        defer parsed.deinit();

        // Get the entries of json file 
        const entries = parsed.value;
        for(entries) |*entry| {

            // Get the contents of the actual file and compare the last modified file time with 
            // the recored last modified in cache 
            var buf: [1024 * 1024]u8 = undefined;
            const current_file_path = try std.fmt.bufPrint(&buf, "{s}{s}", .{entry.dir, entry.file});
            const file = root_dir.openFile(current_file_path, .{}) catch |err| {
                switch(err) {
                    // If the file exist in cache and not directory, give warning and continue 
                    error.FileNotFound => {
                        try writer.print("File {s} not found!  Continuing to next file...\n", .{current_file_path});
                        continue;
                    },
                    else => { return err; }
                }
            };
            defer file.close();
            const file_stat = try file.stat();

            // If file mtime does not match cache mtime, update the cache mtime, 
            // increate the version ID in cache, and add it to modfied files
            if(file_stat.mtime != entry.mtime) {
                entry.mtime = file_stat.mtime;
                entry.version += 1;
                try modified_files.append(allocator, entry.file);
            } 
            try cached_results.append(allocator, entry.*); 
        }

        // Open a writable version of the file since openFile method is READ-ONLY
        const writeable_file = try root_dir.createFile("src/cache.json", .{});
        defer writeable_file.close();

        // Create an interface for the writable file 
        var cache_file_buf: [1024 * 1024]u8 = undefined;
        var cache_file_writer = writeable_file.writer(&cache_file_buf);
        const cache_file_interface = &cache_file_writer.interface;

        // Format stored entries into JSON and write it to the file 
        const results = std.json.fmt(cached_results.items, .{.whitespace = .indent_2});
        try cache_file_interface.print("{f}", .{results});
        try cache_file_interface.flush();

        // Print out which files have been modified 
        if(modified_files.items.len > 0) {
            try writer.print("{} files modified: \n", .{modified_files.items.len});
            try writer.flush();
            for(modified_files.items) |mod_file| {
                try writer.print("{s}.zig\n", .{mod_file});
                try writer.flush();
            }
        }
        // If nothing was modified 
        else {
            try writer.writeAll("No new changes, cache up to date!");
            try writer.flush();
        }
    } 
    //If cache.json does not exist, we create the file and create brand new file structs 
    else |err| {
        switch(err) {
            error.FileNotFound => {

            // CREATE FILE STRUCTURE STRUCTS FROM BOTTOM OF SCRIPT
            const structures = try getStructures(allocator, root_path);
            defer allocator.free(structures);

            for(structures) |fs| {
                for(fs.files) |file_path| {
                    //Append file name to directory to get file path 
                    var buf: [1024]u8 = undefined;
                    const full_path = try std.fmt.bufPrint(&buf, "{s}{s}", .{fs.dir, file_path});

                    // Open file to get last modified time 
                    const opened_file = root_dir.openFile(full_path, .{}) catch |file_err| {
                        switch(file_err) {
                            error.FileNotFound => {
                                try writer.print("Warning: file not found: {s}\n", .{full_path});
                                try writer.flush();
                                continue;
                            },
                            else => { return err; }
                        }
                    };
                    defer opened_file.close();

                    const file_stat = try opened_file.stat();
                    const mtime = file_stat.mtime;

                    // Add new json entry to ArrayList
                    const entry = JsonEntry{.dir = fs.dir, .file = file_path, .mtime = mtime, .version = 0};
                    try cached_results.append(allocator, entry);
                }
            }

            //USER MSG
            try writer.writeAll("Writing new cache.json file..\n"); 
            try writer.flush();

            //WRITE TO FILE
            var json_file_buf: [4096]u8 = undefined;
            var json_file = try root_dir.createFile("src/cache.json", .{});
            defer json_file.close();

            // Create JSON file writer
            var json_out = json_file.writer(&json_file_buf);
            const json_writer = &json_out.interface;

            const results = std.json.fmt(cached_results.items, .{ .whitespace = .indent_4 });
            try json_writer.print("{f}", .{results});
            try json_writer.flush();

            try writer.writeAll("Finished!\n");
            try writer.flush();
        },
        else => {},
        }
    }

}

fn getStructures(allocator: std.mem.Allocator, root_path: [:0]const u8) ![]const FileStructure {
    const structures = try allocator.alloc(FileStructure, 3);

    const protiens = FileStructure.init(.{
        .name = "Protiens",
        .root_path = root_path,
        .dir = "src/Protiens/",
        .files = &[_][]const u8{
            "Beans",
            "Steak",
            "Peanutbutter",
        },
    });

    const grains= FileStructure.init(.{
        .name = "Grains",
        .root_path = root_path,
        .dir = "src/Grains/",
        .files = &[_][]const u8{
            "Bread",
            "Pasta",
            "Oats",
        },
    });

    const fruits = FileStructure.init(.{
        .name = "Fruits",
        .root_path = root_path,
        .dir = "src/Fruits/",
        .files = &[_][]const u8{
            "Apple",
            "Banana",
            "Carrot",
        },
    });

    structures[0] = protiens;
    structures[1] = grains;
    structures[2] = fruits;
    return structures;
}

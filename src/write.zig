const std = @import("std");

// What gets parsed to and from for JSON data
const EntryArgs = struct {
    dir: []const u8,
    file: []const u8,
    mtime: i128,
    version: usize,
};

const JsonInterface = struct {
    pub const Self = @This();

    cache_file: std.fs.File,
    cache_file_name: []const u8,
    root_dir: *std.fs.Dir,
    dirs: []const []const u8,

    reader_buf: [1024*1024]u8 = undefined,
    reader: std.fs.File.Reader = undefined, 
    json_scanner: ?std.json.Scanner = null, 

    writer_buf: [1024*1024]u8 = undefined, 
    writer: std.fs.File.Writer = undefined,

    entries: ?std.json.Value = null,
    new_entries: std.json.ObjectMap = undefined, 
    modified_files: std.ArrayList([]const u8) = undefined,
    
    allocator: std.mem.Allocator,
    
    fn init(allocator: std.mem.Allocator, file_name: []const u8, root_dir: *std.fs.Dir, dirs: []const []const u8) !Self {
        const file = try root_dir.openFile(file_name, .{});
        
        var self = Self{
            .cache_file= file,
            .cache_file_name= file_name,
            .root_dir = root_dir,
            .dirs = dirs,
            .allocator = allocator,
        };

        self.reader = file.reader(&self.reader_buf);
        self.writer = file.writer(&self.writer_buf);

        self.new_entries = std.ArrayList(JsonEntry){};
        self.modified_files = std.ArrayList([]const u8){};
        self.new_entries = std.json.ObjectMap.init(allocator);

        return self;
    }

    fn deinit(self: *Self) void {
        self.cache_file.close(); 
        self.modified_files.deinit(self.allocator);
        self.new_entries.deinit();
            
        if(self.json_scanner) |*scanner| {
            scanner.deinit();
        }
    }

    fn addEntry(self: *Self, entry: JsonEntry) !void {
  var id_buf: [32]u8 = undefined;
      const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{entry.id});

      // Create a JSON value from the entry data
      var data_obj = std.json.ObjectMap.init(self.allocator);
      try data_obj.put("dir", .{.string = entry.data.dir});
      try data_obj.put("file", .{.string = entry.data.file});
      try data_obj.put("mtime", .{.integer = @intCast(entry.data.mtime)});
      try data_obj.put("version", .{.integer = @intCast(entry.data.version)});

      // Add to map with ID as key
      const key = try self.allocator.dupe(u8, id_str);
    }

    fn setEntries(self: *Self) !void {
        try self.cache_file.seekTo(0);
        const file_size = (try self.cache_file.stat()).size;
        try self.reader.interface.fill(file_size);

        const content = try self.reader.interface.readAlloc(self.allocator, file_size);

        std.debug.print("{s}\n", .{content});
        self.json_scanner = std.json.Scanner.initCompleteInput(self.allocator, content);
        const parsed = try std.json.parseFromTokenSource(std.json.Value, self.allocator, &self.json_scanner.?, .{});

        self.entries = parsed.value;
    }

    fn updateVersionControl(self: *Self ) !void {
        try self.setEntries();
        const entries = self.entries.?;
        std.debug.print("{any}\n", .{entries});
        // for(self.dirs) |dir_name| {
        //     var dir = try self.root_dir.openDir(dir_name, .{});
        //     defer dir.close();
        //
        //     const dir_iterator = dir.iterate();
        //     while(dir_iterator.next()) |src_file| {
        //         if(src_file.kind != .File) continue;
        //
        //         const src_file_mtime = (try src_file.stat()).mtime;
        //         _ = src_file_mtime;
        //     }
        // }
        //
        // for(self.src_file_names) |src_file_name| {
        //     var src_file = try self.root_dir.openFile(src_file_name, .{});
        //     defer src_file.close();
        //     const src_mtime = (try src_file.stat()).mtime;
        //     const hash_id = std.hash.Murmur2_64.hash(src_file_name);
        //
        //     for(self.entries) |*entry| {
        //         if(entry.id != hash_id) continue;
        //
        //         if(entry.mtime != src_mtime) {
        //             entry.mtime = src_mtime;
        //             entry.version += 1;
        //             try self.modified_files.append(self.allocator, src_file_name);
        //         }
        //
        //         try self.new_entries.append(self.allocator, entry.*);
        //     }
        // }
    }

    fn writeJsonToFile(self: *Self) !void {
        const writeable_file = try self.root_dir.createFile(self.cache_file_name, .{}); 
        defer writeable_file.close();
        
        var write_buf: [1024 * 1024]u8 = undefined;
        var writer = writeable_file.writer(&write_buf);
        const interface = &writer.interface;
        
        const json_entries = std.json.fmt(self.new_entries.items, .{.whitespace = .indent_2});
        std.debug.print("{f}\n", .{json_entries});
        try interface.print("{f}", .{json_entries});
        try interface.flush();
    }
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

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator = gpa.allocator();
    defer _ = gpa.deinit();

    //Allocator
    var arena_alloc = std.heap.ArenaAllocator.init(gpa_allocator);
    const allocator = arena_alloc.allocator();
    defer _ = arena_alloc.deinit();

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

    // const entry1 = try createEntry(allocator, &root_dir, .{.dir = "Fruits", .file = "Apple", .mtime = 0, .version = 0 });
    // const entry2 = try createEntry(allocator, &root_dir, .{.dir = "Fruits", .file = "Banana", .mtime = 0, .version = 0 });

    var json_interface = try JsonInterface.init(allocator, "src/cache.json", &root_dir, &[_][]const u8{"src/Fruits"});
    defer json_interface.deinit();

    try json_interface.updateVersionControl();

    // try json_interface.addEntry(entry1);
    // try json_interface.addEntry(entry2);
    // try json_interface.writeJsonToFile();

    // Where the json entries will get stored until file is written
    // var cached_results = std.ArrayList(JsonEntry){};
    // defer cached_results.deinit(allocator);

    // const json_cache_file = root_dir.openFile("src/cache.json", .{});
    // if(json_cache_file) |cache_file| {
    //     // Where names of modified files live
    //     var modified_files = std.ArrayList([]const u8){};
    //     defer modified_files.deinit(allocator);
    //
    //     // Reader interface to read cache.json
    //     var cache_reader_buf: [1024 * 1024]u8 = undefined;
    //     var cache_reader = cache_file.reader(&cache_reader_buf);
    //     const file_size = (try cache_file.stat()).size;
    //
    //     // Fill file reader with contents of file
    //     try cache_reader.interface.fill(file_size);
    //     const cache_content = cache_reader_buf[0..file_size];
    //
    //     // Scan file contents for json 
    //     var scanner = std.json.Scanner.initCompleteInput(allocator, cache_content);
    //     defer scanner.deinit();
    //
    //     // Parse json into JsonEntry Struct 
    //     const parsed = try std.json.parseFromTokenSource([]JsonEntry, allocator, &scanner, .{});
    //     defer parsed.deinit();
    //
    //     // Get the entries of json file 
    //     const entries = parsed.value;
    //     for(entries) |*entry| {
    //
    //         // Get the contents of the actual file and compare the last modified file time with 
    //         // the recored last modified in cache 
    //         var buf: [1024 * 1024]u8 = undefined;
    //         const current_file_path = try std.fmt.bufPrint(&buf, "{s}{s}", .{entry.dir, entry.file});
    //         const file = root_dir.openFile(current_file_path, .{}) catch |err| {
    //             switch(err) {
    //                 // If the file exist in cache and not directory, give warning and continue 
    //                 error.FileNotFound => {
    //                     try writer.print("File {s} not found!  Continuing to next file...\n", .{current_file_path});
    //                     continue;
    //                 },
    //                 else => { return err; }
    //             }
    //         };
    //         defer file.close();
    //         const file_stat = try file.stat();
    //
    //         // If file mtime does not match cache mtime, update the cache mtime, 
    //         // increate the version ID in cache, and add it to modfied files
    //         if(file_stat.mtime != entry.mtime) {
    //             entry.mtime = file_stat.mtime;
    //             entry.version += 1;
    //             try modified_files.append(allocator, entry.file);
    //         } 
    //         try cached_results.append(allocator, entry.*); 
    //     }
    //
    //     // Open a writable version of the file since openFile method is READ-ONLY
    //     const writeable_file = try root_dir.createFile("src/cache.json", .{});
    //     defer writeable_file.close();
    //
    //     // Create an interface for the writable file 
    //     var cache_file_buf: [1024 * 1024]u8 = undefined;
    //     var cache_file_writer = writeable_file.writer(&cache_file_buf);
    //     const cache_file_interface = &cache_file_writer.interface;
    //
    //     // Format stored entries into JSON and write it to the file 
    //     const results = std.json.fmt(cached_results.items, .{.whitespace = .indent_2});
    //     try cache_file_interface.print("{f}", .{results});
    //     try cache_file_interface.flush();
    //
    //     // Print out which files have been modified 
    //     if(modified_files.items.len > 0) {
    //         try writer.print("{} files modified: \n", .{modified_files.items.len});
    //         try writer.flush();
    //         for(modified_files.items) |mod_file| {
    //             try writer.print("{s}.zig\n", .{mod_file});
    //             try writer.flush();
    //         }
    //     }
    //     // If nothing was modified 
    //     else {
    //         try writer.writeAll("No new changes, cache up to date!");
    //         try writer.flush();
    //     }
    // } 
    // //If cache.json does not exist, we create the file and create brand new file structs 
    // else |err| {
    //     switch(err) {
    //         error.FileNotFound => {
    //
    //         // CREATE FILE STRUCTURE STRUCTS FROM BOTTOM OF SCRIPT
    //         const structures = try getStructures(allocator, root_path);
    //         defer allocator.free(structures);
    //
    //         for(structures) |fs| {
    //             for(fs.files) |file_path| {
    //                 //Append file name to directory to get file path 
    //                 var buf: [1024]u8 = undefined;
    //                 const full_path = try std.fmt.bufPrint(&buf, "{s}{s}", .{fs.dir, file_path});
    //
    //                 // Open file to get last modified time 
    //                 const opened_file = root_dir.openFile(full_path, .{}) catch |file_err| {
    //                     switch(file_err) {
    //                         error.FileNotFound => {
    //                             try writer.print("Warning: file not found: {s}\n", .{full_path});
    //                             try writer.flush();
    //                             continue;
    //                         },
    //                         else => { return err; }
    //                     }
    //                 };
    //                 defer opened_file.close();
    //
    //                 const file_stat = try opened_file.stat();
    //                 const mtime = file_stat.mtime;
    //
    //                 // Add new json entry to ArrayList
    //                 const hash_id = std.hash.murmur.Murmur2_64.hash(file_path);
    //                 const entry = JsonEntry{.dir = fs.dir, .file = file_path, .mtime = mtime, .version = 0, .id = hash_id};
    //                 try cached_results.append(allocator, entry);
    //             }
    //         }
    //
    //         //USER MSG
    //         try writer.writeAll("Writing new cache.json file..\n"); 
    //         try writer.flush();
    //
    //         //WRITE TO FILE
    //         var json_file_buf: [4096]u8 = undefined;
    //         var json_file = try root_dir.createFile("src/cache.json", .{});
    //         defer json_file.close();
    //
    //         // Create JSON file writer
    //         var json_out = json_file.writer(&json_file_buf);
    //         const json_writer = &json_out.interface;
    //
    //         const results = std.json.fmt(cached_results.items, .{ .whitespace = .indent_4 });
    //         try json_writer.print("{f}", .{results});
    //         try json_writer.flush();
    //
    //         try writer.writeAll("Finished!\n");
    //         try writer.flush();
    //     },
    //     else => {},
    //     }
    // }
    //
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


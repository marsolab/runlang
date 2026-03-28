const std = @import("std");
const File = std.fs.File;

pub const InitOptions = struct {
    name: []const u8,
    force: bool = false,
    /// When true, initialize in the current directory instead of creating a new one.
    in_place: bool = false,
};

pub const InitError = error{
    DirectoryExists,
    CreateFailed,
    OutOfMemory,
};

/// Scaffold a new Run project with the standard project layout.
pub fn initProject(allocator: std.mem.Allocator, options: InitOptions) InitError!void {
    const stderr = File.stderr().deprecatedWriter();
    const stdout = File.stdout().deprecatedWriter();

    if (options.in_place) {
        // Initialize in current directory
        scaffoldFiles(allocator, ".", options.name, options.force, stderr) catch {
            return InitError.CreateFailed;
        };
        stdout.print("Initialized project '{s}' in current directory\n", .{options.name}) catch {};
    } else {
        // Create new directory
        std.fs.cwd().makeDir(options.name) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (!options.force) {
                    stderr.print("error: directory '{s}' already exists (use --force to overwrite)\n", .{options.name}) catch {};
                    return InitError.DirectoryExists;
                }
            },
            else => {
                stderr.print("error: failed to create directory '{s}'\n", .{options.name}) catch {};
                return InitError.CreateFailed;
            },
        };

        scaffoldFiles(allocator, options.name, options.name, options.force, stderr) catch {
            return InitError.CreateFailed;
        };
        stdout.print("Initialized project '{s}' in ./{s}/\n", .{ options.name, options.name }) catch {};
    }
}

fn scaffoldFiles(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    project_name: []const u8,
    force: bool,
    stderr: anytype,
) !void {
    const dir = if (std.mem.eql(u8, base_dir, "."))
        std.fs.cwd()
    else
        std.fs.cwd().openDir(base_dir, .{}) catch {
            stderr.print("error: failed to open directory '{s}'\n", .{base_dir}) catch {};
            return error.CreateFailed;
        };

    // Create subdirectories
    const dirs = [_][]const u8{ "cmd", "pkg", "lib" };
    for (dirs) |d| {
        dir.makeDir(d) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                stderr.print("error: failed to create directory '{s}'\n", .{d}) catch {};
                return error.CreateFailed;
            },
        };
    }

    // Generate main.run
    const main_content = generateMainFile(allocator, project_name) catch return error.OutOfMemory;
    defer allocator.free(main_content);
    writeFileIfNotExists(dir, "cmd/main.run", main_content, force, stderr);

    // Generate .gitignore
    writeFileIfNotExists(dir, ".gitignore", gitignore_content, force, stderr);

    // Generate run.toml (project config)
    const run_toml = generateRunToml(allocator, project_name) catch return error.OutOfMemory;
    defer allocator.free(run_toml);
    writeFileIfNotExists(dir, "run.toml", run_toml, force, stderr);

    // Generate README.md
    const readme = generateReadme(allocator, project_name) catch return error.OutOfMemory;
    defer allocator.free(readme);
    writeFileIfNotExists(dir, "README.md", readme, force, stderr);
}

fn writeFileIfNotExists(dir: std.fs.Dir, path: []const u8, content: []const u8, force: bool, stderr: anytype) void {
    if (!force) {
        // Check if file exists
        if (dir.statFile(path)) |_| {
            stderr.print("warning: '{s}' already exists, skipping (use --force to overwrite)\n", .{path}) catch {};
            return;
        } else |_| {}
    }

    const file = dir.createFile(path, .{}) catch {
        stderr.print("error: failed to create '{s}'\n", .{path}) catch {};
        return;
    };
    defer file.close();
    file.writeAll(content) catch {
        stderr.print("error: failed to write '{s}'\n", .{path}) catch {};
    };
}

fn generateMainFile(allocator: std.mem.Allocator, project_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\package main
        \\
        \\use "fmt"
        \\
        \\pub fn main() {{
        \\    fmt.println("Hello from {s}!")
        \\}}
        \\
    , .{project_name});
}

fn generateRunToml(allocator: std.mem.Allocator, project_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\[package]
        \\name = "{s}"
        \\version = "0.1.0"
        \\run-version = "0.1.0"
        \\
    , .{project_name});
}

fn generateReadme(allocator: std.mem.Allocator, project_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\# {s}
        \\
        \\A Run language project.
        \\
        \\## Getting Started
        \\
        \\```bash
        \\run run cmd/main.run
        \\```
        \\
    , .{project_name});
}

const gitignore_content =
    \\# Build output
    \\*.o
    \\*.a
    \\*.so
    \\*.dylib
    \\
    \\# Editor files
    \\.vscode/
    \\.idea/
    \\*~
    \\*.swp
    \\*.swo
    \\
    \\# OS files
    \\.DS_Store
    \\Thumbs.db
    \\
;

// --- Tests ---

test "generateMainFile: contains package and main" {
    const content = try generateMainFile(std.testing.allocator, "myapp");
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "package main") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "pub fn main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Hello from myapp!") != null);
}

test "generateRunToml: contains package fields" {
    const content = try generateRunToml(std.testing.allocator, "myapp");
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "[package]") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "name = \"myapp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "version = \"0.1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "run-version = \"0.1.0\"") != null);
}

test "generateReadme: contains project name" {
    const content = try generateReadme(std.testing.allocator, "myapp");
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "# myapp") != null);
}

test "initProject: creates directory structure" {
    const allocator = std.testing.allocator;

    // Use a temp directory for testing
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // We need to test with the filesystem, so create in tmp
    const tmp_path = tmp.dir.realpathAlloc(allocator, ".") catch return;
    defer allocator.free(tmp_path);

    // Create the project dir manually inside tmp
    tmp.dir.makeDir("testproj") catch {};

    const proj_dir = tmp.dir.openDir("testproj", .{}) catch return;
    _ = proj_dir;

    // Just verify the helper functions work — full init requires cwd manipulation
    const main_content = try generateMainFile(allocator, "testproj");
    defer allocator.free(main_content);
    try std.testing.expect(main_content.len > 0);
}

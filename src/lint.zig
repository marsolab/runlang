const std = @import("std");
const Ast = @import("ast.zig").Ast;
const Token = @import("token.zig").Token;
const diagnostics = @import("diagnostics.zig");
const naming = @import("naming.zig");

/// A lint diagnostic produced by a lint rule.
pub const LintDiagnostic = struct {
    rule_name: []const u8,
    severity: diagnostics.Severity,
    byte_offset: u32,
    end_offset: u32,
    message: []const u8,
};

/// Context passed to each lint rule, providing access to the AST, tokens,
/// source text, and a way to report diagnostics.
pub const LintContext = struct {
    tree: *const Ast,
    tokens: []const Token,
    source: []const u8,
    file_path: []const u8,
    results: *std.ArrayList(LintDiagnostic),
    allocator: std.mem.Allocator,
    allocated_messages: *std.ArrayList([]const u8),

    pub fn report(
        self: *LintContext,
        rule_name: []const u8,
        severity: diagnostics.Severity,
        byte_offset: u32,
        end_offset: u32,
        message: []const u8,
    ) !void {
        try self.results.append(self.allocator, .{
            .rule_name = rule_name,
            .severity = severity,
            .byte_offset = byte_offset,
            .end_offset = end_offset,
            .message = message,
        });
    }

    pub fn reportFmt(
        self: *LintContext,
        rule_name: []const u8,
        severity: diagnostics.Severity,
        byte_offset: u32,
        end_offset: u32,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.allocated_messages.append(self.allocator, msg);
        try self.report(rule_name, severity, byte_offset, end_offset, msg);
    }
};

/// A single lint rule. Each rule has a name, description, default severity,
/// and a check function that inspects the AST and reports diagnostics.
pub const LintRule = struct {
    name: []const u8,
    description: []const u8,
    default_severity: diagnostics.Severity,
    checkFn: *const fn (*LintContext) anyerror!void,
};

/// Runs a set of lint rules over parsed source and collects diagnostics.
pub const LintRunner = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayList(LintRule),
    results: std.ArrayList(LintDiagnostic),
    allocated_messages: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) LintRunner {
        return .{
            .allocator = allocator,
            .rules = .empty,
            .results = .empty,
            .allocated_messages = .empty,
        };
    }

    pub fn deinit(self: *LintRunner) void {
        for (self.allocated_messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.allocated_messages.deinit(self.allocator);
        self.results.deinit(self.allocator);
        self.rules.deinit(self.allocator);
    }

    /// Register a lint rule with the runner.
    pub fn addRule(self: *LintRunner, rule: LintRule) !void {
        try self.rules.append(self.allocator, rule);
    }

    /// Register all built-in lint rules.
    pub fn addBuiltinRules(self: *LintRunner) !void {
        try self.addRule(naming_rule);
        try self.addRule(unused_import_rule);
        try self.addRule(empty_block_rule);
    }

    /// Run all registered rules against the given parsed file.
    pub fn run(
        self: *LintRunner,
        tree: *const Ast,
        tokens: []const Token,
        source: []const u8,
        file_path: []const u8,
    ) !void {
        var ctx = LintContext{
            .tree = tree,
            .tokens = tokens,
            .source = source,
            .file_path = file_path,
            .results = &self.results,
            .allocator = self.allocator,
            .allocated_messages = &self.allocated_messages,
        };

        for (self.rules.items) |rule| {
            try rule.checkFn(&ctx);
        }
    }

    /// Render all collected diagnostics to a writer.
    pub fn render(self: *const LintRunner, source: []const u8, file_path: []const u8, writer: anytype) !void {
        for (self.results.items) |d| {
            const loc = diagnostics.computeLineCol(source, d.byte_offset);
            const severity_str = switch (d.severity) {
                .@"error" => "error",
                .warning => "warning",
                .note => "note",
            };
            try writer.print("{s}:{d}:{d}: {s} [{s}]: {s}\n", .{
                file_path,
                loc.line,
                loc.col,
                severity_str,
                d.rule_name,
                d.message,
            });
        }
    }

    /// Returns true if any diagnostic is an error.
    pub fn hasErrors(self: *const LintRunner) bool {
        for (self.results.items) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Built-in lint rules
// ---------------------------------------------------------------------------

/// Naming conventions: types must be UpperCamel, variables lowerCamel,
/// files lower_snake. Wraps the existing naming.zig checks.
pub const naming_rule = LintRule{
    .name = "naming-convention",
    .description = "Enforce naming conventions: UpperCamel for types, lowerCamel for variables, lower_snake for files",
    .default_severity = .@"error",
    .checkFn = &checkNamingRule,
};

fn checkNamingRule(ctx: *LintContext) !void {
    var violations = try naming.checkNaming(ctx.allocator, ctx.file_path, ctx.tree, ctx.tokens);
    defer violations.deinit(ctx.allocator);

    for (violations.items) |v| {
        const rule_msg = switch (v.tag) {
            .type_must_be_upper_camel => "type names must use UpperCamelCase",
            .variable_must_be_lower_camel => "variable names must use lowerCamelCase",
            .file_must_be_lower_snake => "file names must use lower_snake_case",
        };
        try ctx.reportFmt(
            "naming-convention",
            .@"error",
            v.loc.start,
            v.loc.end,
            "{s}: '{s}'",
            .{ rule_msg, v.name },
        );
    }
}

/// Detects `use` declarations whose imported name is never referenced.
pub const unused_import_rule = LintRule{
    .name = "unused-import",
    .description = "Warn about unused import declarations",
    .default_severity = .warning,
    .checkFn = &checkUnusedImports,
};

fn checkUnusedImports(ctx: *LintContext) !void {
    const nodes = ctx.tree.nodes.items;
    const tokens = ctx.tokens;

    // Collect import identifiers (from use_decl nodes).
    var import_tokens: std.ArrayList(u32) = .empty;
    defer import_tokens.deinit(ctx.allocator);

    for (nodes) |node| {
        if (node.tag == .use_decl) {
            // The main_token of a use_decl points to the `use` keyword.
            // The imported name is the identifier that follows the path.
            // In a use like `use "fmt"`, the bound name is typically the
            // last path segment, stored as the lhs child ident node.
            const bound_idx: usize = @intCast(node.data.lhs);
            if (bound_idx != 0 and bound_idx < nodes.len) {
                const bound_node = nodes[bound_idx];
                if (bound_node.tag == .ident) {
                    try import_tokens.append(ctx.allocator, bound_node.main_token);
                }
            }
        }
    }

    // For each import identifier, check if the name appears in any ident
    // node other than the import itself.
    for (import_tokens.items) |imp_tok| {
        if (imp_tok >= tokens.len) continue;
        const imp_name = tokens[imp_tok].slice(ctx.source);
        var used = false;
        for (nodes) |node| {
            if (node.tag == .ident and node.main_token != imp_tok) {
                if (node.main_token < tokens.len) {
                    const name = tokens[node.main_token].slice(ctx.source);
                    if (std.mem.eql(u8, name, imp_name)) {
                        used = true;
                        break;
                    }
                }
            }
        }
        if (!used) {
            try ctx.reportFmt(
                "unused-import",
                .warning,
                tokens[imp_tok].loc.start,
                tokens[imp_tok].loc.end,
                "imported name '{s}' is never used",
                .{imp_name},
            );
        }
    }
}

/// Flags empty block bodies (e.g. `fun foo() { }`) which often indicate
/// unfinished code.
pub const empty_block_rule = LintRule{
    .name = "empty-block",
    .description = "Warn about empty function or control-flow blocks",
    .default_severity = .warning,
    .checkFn = &checkEmptyBlocks,
};

fn checkEmptyBlocks(ctx: *LintContext) !void {
    const nodes = ctx.tree.nodes.items;
    const tokens = ctx.tokens;

    for (nodes) |node| {
        switch (node.tag) {
            .block, .block_expr => {
                // A block with lhs == 0 and rhs == 0 has no statements.
                if (node.data.lhs == 0 and node.data.rhs == 0) {
                    const tok_idx: usize = @intCast(node.main_token);
                    if (tok_idx < tokens.len) {
                        try ctx.report(
                            "empty-block",
                            .warning,
                            tokens[tok_idx].loc.start,
                            tokens[tok_idx].loc.end,
                            "empty block body",
                        );
                    }
                }
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "LintRunner: init and deinit" {
    var runner = LintRunner.init(std.testing.allocator);
    defer runner.deinit();

    try runner.addBuiltinRules();
    try std.testing.expectEqual(@as(usize, 3), runner.rules.items.len);
}

test "LintRunner: builtin rule names" {
    var runner = LintRunner.init(std.testing.allocator);
    defer runner.deinit();

    try runner.addBuiltinRules();

    try std.testing.expectEqualStrings("naming-convention", runner.rules.items[0].name);
    try std.testing.expectEqualStrings("unused-import", runner.rules.items[1].name);
    try std.testing.expectEqualStrings("empty-block", runner.rules.items[2].name);
}

test "LintRunner: hasErrors with no results" {
    var runner = LintRunner.init(std.testing.allocator);
    defer runner.deinit();

    try std.testing.expect(!runner.hasErrors());
}

test "LintContext: report adds diagnostic" {
    var results: std.ArrayList(LintDiagnostic) = .empty;
    defer results.deinit(std.testing.allocator);

    var msgs: std.ArrayList([]const u8) = .empty;
    defer msgs.deinit(std.testing.allocator);

    var ctx = LintContext{
        .tree = undefined,
        .tokens = &.{},
        .source = "",
        .file_path = "test.run",
        .results = &results,
        .allocator = std.testing.allocator,
        .allocated_messages = &msgs,
    };

    try ctx.report("test-rule", .warning, 0, 5, "test message");
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("test-rule", results.items[0].rule_name);
    try std.testing.expectEqualStrings("test message", results.items[0].message);
}

test "LintRunner: custom rule" {
    var runner = LintRunner.init(std.testing.allocator);
    defer runner.deinit();

    const custom_rule = LintRule{
        .name = "custom-check",
        .description = "A custom lint rule for testing",
        .default_severity = .warning,
        .checkFn = &struct {
            fn check(ctx: *LintContext) !void {
                try ctx.report("custom-check", .warning, 0, 0, "custom warning");
            }
        }.check,
    };

    try runner.addRule(custom_rule);
    try std.testing.expectEqual(@as(usize, 1), runner.rules.items.len);
    try std.testing.expectEqualStrings("custom-check", runner.rules.items[0].name);
}

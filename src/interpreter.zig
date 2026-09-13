const std = @import("std");
const ast = @import("ast.zig");
const value = @import("value.zig");
const parser = @import("parser.zig");

const Value = value.Value;
const RuntimeError = value.RuntimeError;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Program = ast.Program;

pub const Environment = struct {
    values: std.StringHashMap(Value),
    enclosing: ?*Environment,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, enclosing: ?*Environment) Environment {
        return .{
            .values = std.StringHashMap(Value).init(allocator),
            .enclosing = enclosing,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Environment) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // Values (strings/lists) from runtime may still leak; AST is in arena
        }
        self.values.deinit();
    }

    pub fn define(self: *Environment, name: []const u8, val: Value) !void {
        // Reuse existing key if present (e.g. for-loop variable)
        if (self.values.getEntry(name)) |entry| {
            entry.value_ptr.* = val;
            return;
        }
        // Own the key so AST-arena reset cannot invalidate env entries
        const key = try self.allocator.dupe(u8, name);
        try self.values.put(key, val);
    }

    pub fn get(self: *Environment, name: []const u8) RuntimeError!Value {
        if (self.values.get(name)) |v| return v;
        if (self.enclosing) |enc| return enc.get(name);
        return error.NameError;
    }

    pub fn assign(self: *Environment, name: []const u8, val: Value) RuntimeError!void {
        if (self.values.contains(name)) {
            try self.values.put(name, val);
            return;
        }
        if (self.enclosing) |enc| {
            return enc.assign(name, val);
        }
        return error.NameError;
    }
};

pub const Interpreter = struct {
    global: Environment,
    current: *Environment,
    allocator: std.mem.Allocator,
    /// All AST nodes (and parser scratch) live here.
    /// Freed in deinit — function bodies stay valid for the interpreter lifetime.
    ast_arena: std.heap.ArenaAllocator,
    /// Runtime heap for strings, lists, range results, etc.
    /// Freed in deinit / freeRuntime; values stored in the environment must not
    /// be used after that.
    runtime_arena: std.heap.ArenaAllocator,
    output: *std.ArrayList(u8), // collected print output
    return_value: ?Value = null,

    pub fn init(allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !Interpreter {
        var global = Environment.init(allocator, null);
        // Builtins
        try global.define("print", .{ .builtin = builtinPrint });
        try global.define("len", .{ .builtin = builtinLen });
        try global.define("str", .{ .builtin = builtinStr });
        try global.define("int", .{ .builtin = builtinInt });
        try global.define("float", .{ .builtin = builtinFloat });
        try global.define("type", .{ .builtin = builtinType });
        try global.define("range", .{ .builtin = builtinRange });

        return .{
            .global = global,
            .current = undefined, // set in run()
            .allocator = allocator,
            .ast_arena = std.heap.ArenaAllocator.init(allocator),
            .runtime_arena = std.heap.ArenaAllocator.init(allocator),
            .output = output,
        };
    }

    fn rt(self: *Interpreter) std.mem.Allocator {
        return self.runtime_arena.allocator();
    }

    pub fn deinit(self: *Interpreter) void {
        // Runtime values first (env may still hold pointers into this arena)
        self.runtime_arena.deinit();
        self.ast_arena.deinit();
        self.global.deinit();
    }

    /// Free AST memory. Invalidates function bodies.
    pub fn freeAst(self: *Interpreter) void {
        _ = self.ast_arena.reset(.retain_capacity);
    }

    /// Free runtime strings/lists. Invalidates Values that point into the runtime arena.
    pub fn freeRuntime(self: *Interpreter) void {
        _ = self.runtime_arena.reset(.retain_capacity);
    }

    pub fn run(self: *Interpreter, program: Program) RuntimeError!void {
        self.current = &self.global;
        for (program.statements) |stmt| {
            _ = try self.execute(stmt);
        }
    }

    pub fn evalSource(self: *Interpreter, source: []const u8) RuntimeError!void {
        // Parse into the AST arena so nodes are released in deinit / freeAst
        const program = parser.parseSource(self.ast_arena.allocator(), source) catch |err| {
            std.debug.print("Parse error: {s}\n", .{@errorName(err)});
            return error.TypeError; // reuse
        };
        try self.run(program);
    }

    fn execute(self: *Interpreter, stmt: *Stmt) RuntimeError!Value {
        return switch (stmt.*) {
            .expr => |e| try self.evaluate(e),
            .assign => |a| {
                const val = try self.evaluate(a.value);
                // Define in current scope (or assign if exists)
                if (self.current.values.contains(a.name)) {
                    try self.current.assign(a.name, val);
                } else {
                    try self.current.define(a.name, val);
                }
                return .none;
            },
            .if_stmt => |i| try self.execIf(i),
            .while_stmt => |w| try self.execWhile(w),
            .for_stmt => |f| try self.execFor(f),
            .def => |d| {
                const func = Value{ .function = .{
                    .name = d.name,
                    .params = d.params,
                    .body = d.body,
                } };
                try self.current.define(d.name, func);
                return .none;
            },
            .return_stmt => |r| {
                self.return_value = if (r.value) |v| try self.evaluate(v) else Value{ .none = {} };
                return error.ReturnValue;
            },
            .print => |p| {
                for (p.args, 0..) |arg, idx| {
                    if (idx > 0) try self.output.appendSlice(self.allocator, " ");
                    const val = try self.evaluate(arg);
                    try self.writeValue(val);
                }
                try self.output.append(self.allocator, '\n');
                return .none;
            },
            .pass => .none,
            .break_stmt => error.BreakLoop,
            .continue_stmt => error.ContinueLoop,
            .block => |b| {
                for (b.statements) |s| {
                    _ = try self.execute(s);
                }
                return .none;
            },
        };
    }

    fn execIf(self: *Interpreter, i: Stmt.If) RuntimeError!Value {
        if ((try self.evaluate(i.condition)).isTruthy()) {
            return self.execBlock(i.then_body);
        }
        for (i.elifs) |elif| {
            if ((try self.evaluate(elif.condition)).isTruthy()) {
                return self.execBlock(elif.body);
            }
        }
        if (i.else_body) |else_body| {
            return self.execBlock(else_body);
        }
        return .none;
    }

    fn execWhile(self: *Interpreter, w: Stmt.While) RuntimeError!Value {
        while ((try self.evaluate(w.condition)).isTruthy()) {
            const result = self.execBlock(w.body) catch |err| switch (err) {
                error.BreakLoop => break,
                error.ContinueLoop => continue,
                else => |e| return e,
            };
            _ = result;
        }
        return .none;
    }

    fn execFor(self: *Interpreter, f: Stmt.For) RuntimeError!Value {
        const iterable = try self.evaluate(f.iterable);
        switch (iterable) {
            .list => |l| {
                for (l.items.items) |item| {
                    try self.current.define(f.target, item);
                    _ = self.execBlock(f.body) catch |err| switch (err) {
                        error.BreakLoop => break,
                        error.ContinueLoop => continue,
                        else => |e| return e,
                    };
                }
            },
            else => return error.TypeError,
        }
        return .none;
    }

    fn execBlock(self: *Interpreter, statements: []const *Stmt) RuntimeError!Value {
        for (statements) |stmt| {
            // Handle return specially
            if (stmt.* == .return_stmt) {
                const r = stmt.return_stmt;
                self.return_value = if (r.value) |v| try self.evaluate(v) else Value{ .none = {} };
                return error.ReturnValue;
            }
            _ = try self.execute(stmt);
        }
        return .none;
    }

    fn evaluate(self: *Interpreter, expr: *Expr) RuntimeError!Value {
        return switch (expr.*) {
            .integer => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .string => |s| .{ .string = s },
            .boolean => |b| .{ .boolean = b },
            .none => .none,
            .identifier => |name| self.current.get(name),
            .binary => |b| {
                // Short-circuit for and/or
                if (b.op == .And or b.op == .Or) {
                    const left = try self.evaluate(b.left);
                    if (b.op == .And and !left.isTruthy()) return left;
                    if (b.op == .Or and left.isTruthy()) return left;
                    return try self.evaluate(b.right);
                }
                const left = try self.evaluate(b.left);
                const right = try self.evaluate(b.right);
                return try value.binaryOp(b.op, left, right, self.rt());
            },
            .unary => |u| {
                const operand = try self.evaluate(u.operand);
                return try value.unaryOp(u.op, operand);
            },
            .call => |c| try self.call(c),
            .list => |l| {
                var items: std.ArrayList(Value) = .empty;
                for (l.elements) |el| {
                    try items.append(self.rt(), try self.evaluate(el));
                }
                return .{ .list = .{ .items = items, .allocator = self.rt() } };
            },
            .subscript => |s| {
                const obj = try self.evaluate(s.value);
                const idx = try self.evaluate(s.index);
                return try self.subscript(obj, idx);
            },
            .attribute => error.AttributeError, // not implemented yet
        };
    }

    fn call(self: *Interpreter, c: Expr.Call) RuntimeError!Value {
        const callee = try self.evaluate(c.callee);

        var args: std.ArrayList(Value) = .empty;
        defer args.deinit(self.allocator);
        for (c.args) |arg| {
            try args.append(self.allocator, try self.evaluate(arg));
        }

        switch (callee) {
            .builtin => |func| {
                return try func(args.items, self.rt());
            },
            .function => |func| {
                if (args.items.len != func.params.len) return error.ArgumentError;

                var local = Environment.init(self.allocator, self.current);
                defer local.deinit();

                for (func.params, args.items) |param, arg| {
                    try local.define(param, arg);
                }

                const previous = self.current;
                self.current = &local;
                defer self.current = previous;

                self.return_value = null;
                _ = self.execBlock(func.body) catch |err| {
                    if (err == error.ReturnValue) {
                        return self.return_value orelse .none;
                    }
                    return err;
                };
                return .none;
            },
            else => return error.TypeError,
        }
    }

    fn subscript(self: *Interpreter, obj: Value, idx: Value) RuntimeError!Value {
        _ = self;
        switch (obj) {
            .list => |l| {
                const i = switch (idx) {
                    .integer => |n| n,
                    else => return error.TypeError,
                };
                if (i < 0 or i >= @as(i64, @intCast(l.items.items.len))) return error.IndexError;
                return l.items.items[@intCast(i)];
            },
            .string => |s| {
                const i = switch (idx) {
                    .integer => |n| n,
                    else => return error.TypeError,
                };
                if (i < 0 or i >= @as(i64, @intCast(s.len))) return error.IndexError;
                // Return single-char string — needs allocation; simplified
                return error.TypeError; // TODO
            },
            else => return error.TypeError,
        }
    }

    fn writeValue(self: *Interpreter, val: Value) RuntimeError!void {
        var buf: [256]u8 = undefined;
        const formatted: []const u8 = switch (val) {
            .none => "None",
            .boolean => |b| if (b) "True" else "False",
            .integer => |i| std.fmt.bufPrint(&buf, "{d}", .{i}) catch return error.OutOfMemory,
            .float => |f| std.fmt.bufPrint(&buf, "{d}", .{f}) catch return error.OutOfMemory,
            .string => |s| s,
            .list => |l| blk: {
                // simple list printer into buf (truncated if needed)
                var pos: usize = 0;
                if (pos < buf.len) { buf[pos] = '['; pos += 1; }
                for (l.items.items, 0..) |item, idx| {
                    if (idx > 0 and pos + 2 < buf.len) {
                        buf[pos] = ','; pos += 1;
                        buf[pos] = ' '; pos += 1;
                    }
                    const part: []const u8 = switch (item) {
                        .integer => |i| std.fmt.bufPrint(buf[pos..], "{d}", .{i}) catch break :blk buf[0..pos],
                        .float => |f| std.fmt.bufPrint(buf[pos..], "{d}", .{f}) catch break :blk buf[0..pos],
                        .boolean => |b| if (b) "True" else "False",
                        .none => "None",
                        .string => |s| s,
                        else => "?",
                    };
                    if (item == .integer or item == .float) {
                        pos += part.len;
                    } else {
                        if (pos + part.len >= buf.len) break :blk buf[0..pos];
                        @memcpy(buf[pos..][0..part.len], part);
                        pos += part.len;
                    }
                }
                if (pos < buf.len) { buf[pos] = ']'; pos += 1; }
                break :blk buf[0..pos];
            },
            .function => |f| std.fmt.bufPrint(&buf, "<function {s}>", .{f.name}) catch return error.OutOfMemory,
            .builtin => "<builtin>",
        };
        try self.output.appendSlice(self.allocator, formatted);
    }
};

// ── Builtins ──

fn builtinPrint(args: []const Value, allocator: std.mem.Allocator) RuntimeError!Value {
    _ = allocator;
    // Print is handled specially in the interpreter for output collection.
    // This is a fallback.
    for (args, 0..) |arg, i| {
        if (i > 0) std.debug.print(" ", .{});
        std.debug.print("{any}", .{arg});
    }
    std.debug.print("\n", .{});
    return .none;
}

fn builtinLen(args: []const Value, allocator: std.mem.Allocator) RuntimeError!Value {
    _ = allocator;
    if (args.len != 1) return error.ArgumentError;
    return switch (args[0]) {
        .string => |s| .{ .integer = @intCast(s.len) },
        .list => |l| .{ .integer = @intCast(l.items.items.len) },
        else => error.TypeError,
    };
}

fn builtinStr(args: []const Value, allocator: std.mem.Allocator) RuntimeError!Value {
    if (args.len != 1) return error.ArgumentError;
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{any}", .{args[0]}) catch return error.OutOfMemory;
    const owned = try allocator.dupe(u8, s);
    return .{ .string = owned };
}

fn builtinInt(args: []const Value, allocator: std.mem.Allocator) RuntimeError!Value {
    _ = allocator;
    if (args.len != 1) return error.ArgumentError;
    return switch (args[0]) {
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .integer = @intFromFloat(f) },
        .string => |s| .{ .integer = std.fmt.parseInt(i64, s, 10) catch return error.TypeError },
        .boolean => |b| .{ .integer = if (b) 1 else 0 },
        else => error.TypeError,
    };
}

fn builtinFloat(args: []const Value, allocator: std.mem.Allocator) RuntimeError!Value {
    _ = allocator;
    if (args.len != 1) return error.ArgumentError;
    return switch (args[0]) {
        .integer => |i| .{ .float = @floatFromInt(i) },
        .float => |f| .{ .float = f },
        .string => |s| .{ .float = std.fmt.parseFloat(f64, s) catch return error.TypeError },
        else => error.TypeError,
    };
}

fn builtinType(args: []const Value, allocator: std.mem.Allocator) RuntimeError!Value {
    if (args.len != 1) return error.ArgumentError;
    const name = args[0].typeName();
    const owned = try allocator.dupe(u8, name);
    return .{ .string = owned };
}

fn builtinRange(args: []const Value, allocator: std.mem.Allocator) RuntimeError!Value {
    // Returns a list for simplicity (real range is lazy)
    if (args.len < 1 or args.len > 3) return error.ArgumentError;

    var start: i64 = 0;
    var stop: i64 = 0;
    var step: i64 = 1;

    if (args.len == 1) {
        stop = switch (args[0]) {
            .integer => |i| i,
            else => return error.TypeError,
        };
    } else {
        start = switch (args[0]) {
            .integer => |i| i,
            else => return error.TypeError,
        };
        stop = switch (args[1]) {
            .integer => |i| i,
            else => return error.TypeError,
        };
        if (args.len == 3) {
            step = switch (args[2]) {
                .integer => |i| i,
                else => return error.TypeError,
            };
            if (step == 0) return error.TypeError;
        }
    }

    var items: std.ArrayList(Value) = .empty;
    var i = start;
    if (step > 0) {
        while (i < stop) : (i += step) {
            try items.append(allocator, .{ .integer = i });
        }
    } else {
        while (i > stop) : (i += step) {
            try items.append(allocator, .{ .integer = i });
        }
    }
    return .{ .list = .{ .items = items, .allocator = allocator } };
}

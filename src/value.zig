const std = @import("std");
const ast = @import("ast.zig");

pub const RuntimeError = error{
    TypeError,
    NameError,
    ZeroDivision,
    IndexError,
    AttributeError,
    RecursionError,
    ReturnValue, // used for control flow
    BreakLoop,
    ContinueLoop,
    OutOfMemory,
    ArgumentError,
};

pub const Value = union(enum) {
    none: void,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    list: List,
    function: Function,
    builtin: BuiltinFn,

    pub const List = struct {
        items: std.ArrayList(Value),
        allocator: std.mem.Allocator,

        pub fn deinit(self: *List) void {
            for (self.items.items) |*item| {
                item.deinit();
            }
            self.items.deinit(self.allocator);
        }
    };

    pub const Function = struct {
        name: []const u8,
        params: []const []const u8,
        body: []const *ast.Stmt,
        // closure would go here later
    };

    pub const BuiltinFn = *const fn (args: []const Value, allocator: std.mem.Allocator) RuntimeError!Value;

    pub fn deinit(self: *Value) void {
        switch (self.*) {
            .string => |s| {
                // Only free if we own it — for simplicity we often borrow
                _ = s;
            },
            .list => |*l| l.deinit(),
            else => {},
        }
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .none => false,
            .boolean => |b| b,
            .integer => |i| i != 0,
            .float => |f| f != 0.0,
            .string => |s| s.len > 0,
            .list => |l| l.items.items.len > 0,
            .function, .builtin => true,
        };
    }

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .none => "NoneType",
            .boolean => "bool",
            .integer => "int",
            .float => "float",
            .string => "str",
            .list => "list",
            .function => "function",
            .builtin => "builtin_function_or_method",
        };
    }

    pub fn format(self: Value, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .none => try writer.writeAll("None"),
            .boolean => |b| try writer.writeAll(if (b) "True" else "False"),
            .integer => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .string => |s| try writer.print("{s}", .{s}),
            .list => |l| {
                try writer.writeAll("[");
                for (l.items.items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try item.format("", .{}, writer);
                }
                try writer.writeAll("]");
            },
            .function => |f| try writer.print("<function {s}>", .{f.name}),
            .builtin => try writer.writeAll("<builtin function>"),
        }
    }

    pub fn equals(self: Value, other: Value) bool {
        return switch (self) {
            .none => other == .none,
            .boolean => |b| other == .boolean and other.boolean == b,
            .integer => |i| switch (other) {
                .integer => |j| i == j,
                .float => |f| @as(f64, @floatFromInt(i)) == f,
                else => false,
            },
            .float => |f| switch (other) {
                .float => |g| f == g,
                .integer => |i| f == @as(f64, @floatFromInt(i)),
                else => false,
            },
            .string => |s| other == .string and std.mem.eql(u8, s, other.string),
            else => false, // lists/functions by identity for now
        };
    }
};



pub fn binaryOp(op: ast.BinaryOp, left: Value, right: Value, allocator: std.mem.Allocator) RuntimeError!Value {
    
    return switch (op) {
        .Add => try add(left, right, allocator),
        .Sub => try sub(left, right),
        .Mul => try mul(left, right),
        .Div => try div(left, right),
        .FloorDiv => try floorDiv(left, right),
        .Mod => try mod(left, right),
        .Pow => try pow(left, right),
        .Eq => .{ .boolean = left.equals(right) },
        .Ne => .{ .boolean = !left.equals(right) },
        .Lt => try compare(left, right, .lt),
        .Gt => try compare(left, right, .gt),
        .Le => try compare(left, right, .le),
        .Ge => try compare(left, right, .ge),
        .And => if (left.isTruthy()) right else left,
        .Or => if (left.isTruthy()) left else right,
    };
}

pub fn unaryOp(op: ast.UnaryOp, operand: Value) RuntimeError!Value {
    return switch (op) {
        .Neg => switch (operand) {
            .integer => |i| .{ .integer = -i },
            .float => |f| .{ .float = -f },
            else => error.TypeError,
        },
        .Pos => switch (operand) {
            .integer, .float => operand,
            else => error.TypeError,
        },
        .Not => .{ .boolean = !operand.isTruthy() },
    };
}

fn add(left: Value, right: Value, allocator: std.mem.Allocator) RuntimeError!Value {
    return switch (left) {
        .integer => |a| switch (right) {
            .integer => |b| .{ .integer = a +% b },
            .float => |b| .{ .float = @as(f64, @floatFromInt(a)) + b },
            else => error.TypeError,
        },
        .float => |a| switch (right) {
            .integer => |b| .{ .float = a + @as(f64, @floatFromInt(b)) },
            .float => |b| .{ .float = a + b },
            else => error.TypeError,
        },
        .string => |a| switch (right) {
            .string => |b| {
                const result = try allocator.alloc(u8, a.len + b.len);
                @memcpy(result[0..a.len], a);
                @memcpy(result[a.len..], b);
                return .{ .string = result };
            },
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

fn sub(left: Value, right: Value) RuntimeError!Value {
    return switch (left) {
        .integer => |a| switch (right) {
            .integer => |b| .{ .integer = a -% b },
            .float => |b| .{ .float = @as(f64, @floatFromInt(a)) - b },
            else => error.TypeError,
        },
        .float => |a| switch (right) {
            .integer => |b| .{ .float = a - @as(f64, @floatFromInt(b)) },
            .float => |b| .{ .float = a - b },
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

fn mul(left: Value, right: Value) RuntimeError!Value {
    return switch (left) {
        .integer => |a| switch (right) {
            .integer => |b| .{ .integer = a *% b },
            .float => |b| .{ .float = @as(f64, @floatFromInt(a)) * b },
            else => error.TypeError,
        },
        .float => |a| switch (right) {
            .integer => |b| .{ .float = a * @as(f64, @floatFromInt(b)) },
            .float => |b| .{ .float = a * b },
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

fn div(left: Value, right: Value) RuntimeError!Value {
    const a = toFloat(left) catch return error.TypeError;
    const b = toFloat(right) catch return error.TypeError;
    if (b == 0.0) return error.ZeroDivision;
    return .{ .float = a / b };
}

fn floorDiv(left: Value, right: Value) RuntimeError!Value {
    return switch (left) {
        .integer => |a| switch (right) {
            .integer => |b| {
                if (b == 0) return error.ZeroDivision;
                return .{ .integer = @divFloor(a, b) };
            },
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

fn mod(left: Value, right: Value) RuntimeError!Value {
    return switch (left) {
        .integer => |a| switch (right) {
            .integer => |b| {
                if (b == 0) return error.ZeroDivision;
                return .{ .integer = @rem(a, b) };
            },
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

fn pow(left: Value, right: Value) RuntimeError!Value {
    return switch (left) {
        .integer => |a| switch (right) {
            .integer => |b| {
                if (b < 0) return error.TypeError; // would need float
                var result: i64 = 1;
                var i: i64 = 0;
                while (i < b) : (i += 1) {
                    result *%= a;
                }
                return .{ .integer = result };
            },
            .float => |b| .{ .float = std.math.pow(f64, @as(f64, @floatFromInt(a)), b) },
            else => error.TypeError,
        },
        .float => |a| switch (right) {
            .integer => |b| .{ .float = std.math.pow(f64, a, @as(f64, @floatFromInt(b))) },
            .float => |b| .{ .float = std.math.pow(f64, a, b) },
            else => error.TypeError,
        },
        else => error.TypeError,
    };
}

const Cmp = enum { lt, gt, le, ge };

fn compare(left: Value, right: Value, cmp: Cmp) RuntimeError!Value {
    const ordering = switch (left) {
        .integer => |a| switch (right) {
            .integer => |b| std.math.order(a, b),
            .float => |b| std.math.order(@as(f64, @floatFromInt(a)), b),
            else => return error.TypeError,
        },
        .float => |a| switch (right) {
            .integer => |b| std.math.order(a, @as(f64, @floatFromInt(b))),
            .float => |b| std.math.order(a, b),
            else => return error.TypeError,
        },
        .string => |a| switch (right) {
            .string => |b| std.mem.order(u8, a, b),
            else => return error.TypeError,
        },
        else => return error.TypeError,
    };

    const result = switch (cmp) {
        .lt => ordering == .lt,
        .gt => ordering == .gt,
        .le => ordering != .gt,
        .ge => ordering != .lt,
    };
    return .{ .boolean = result };
}

fn toFloat(v: Value) RuntimeError!f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => error.TypeError,
    };
}

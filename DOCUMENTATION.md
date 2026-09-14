# zpython — Technical documentation

## 1. Architecture

Pipeline for every chunk of source (REPL line block or file):

```
source text
    → Lexer      (tokens, including Indent / Dedent / Newline)
    → Parser     (AST: Expr + Stmt)
    → Interpreter (evaluate / execute against an Environment)
    → output buffer → stdout
```

Modules:

| Module | Role |
|--------|------|
| `token.zig` | `TokenType`, `Token`, keyword lookup |
| `lexer.zig` | Scans source; tracks indentation stack |
| `ast.zig` | `Expr`, `Stmt`, `Program` unions |
| `parser.zig` | Builds AST; duplicates name strings into the allocator |
| `value.zig` | `Value` tagged union + binary/unary ops |
| `interpreter.zig` | Global/local env, statement execution, builtins |
| `main.zig` | Process entry (`std.process.Init`), REPL, file runner |

## 2. Lexer

- Emits `Indent` when indentation increases, one or more `Dedent` when it decreases.
- Blank lines and comment-only lines do not change the indent stack.
- At EOF, remaining indents are closed with `Dedent` tokens.
- Strings support simple escapes: `\\`, `\n`, `\t`, `\r`, `\"`, `\'`.

Indentation unit: spaces count as 1; tabs count as 4 spaces (simplified).

## 3. Parser

- Statements: assignment, expression stmt, `if`/`elif`/`else`, `while`, `for`, `def`, `return`, `print`, `pass`, `break`, `continue`.
- Expression precedence (low → high): `or` → `and` → `not` → comparisons → `+`/`-` → `*`/`/`/`//`/`%` → `**` (right-assoc) → unary → call/subscript/attr → primary.
- Blocks require `Indent` … `Dedent` after a line ending in `:`.
- Identifier and parameter **names** are copied with the parse allocator so the source buffer may be freed afterward.

## 4. Runtime values (`value.zig`)

```text
Value = none | boolean | integer | float | string | list | function | builtin
```

- Arithmetic mixes `int` and `float` where sensible.
- `+` on two strings concatenates (allocates a new buffer on the interpreter GPA).
- Truthiness follows Python-like rules (`None`/`False`/`0`/`""`/`[]` are false).

## 5. Interpreter

### Environments

- Nested `Environment` maps (`StringHashMap`); lookup walks `enclosing`.
- Keys are owned by the environment allocator (GPA). Re-`define` of the same name reuses the key (important for `for` loop variables).

### AST arena

- `Interpreter.ast_arena` (`std.heap.ArenaAllocator`) holds all AST nodes and parser scratch for the session.
- **REPL:** arena lives until `Interpreter.deinit()` so `def` bodies remain valid across lines.
- **File mode:** after a successful run, `freeAst()` resets the arena (function values are not used after process exit).
- Do not call `freeAst()` while user code may still invoke functions defined in that AST.

### Control flow

- `return` / `break` / `continue` use error-union control flow (`error.ReturnValue`, `error.BreakLoop`, `error.ContinueLoop`).
- Function calls push a local environment; parameters are bound by value.

### Builtins

| Name | Behavior |
|------|----------|
| `print` | Handled as a statement in the AST; also registered as a fallback builtin |
| `len` | `str` or `list` |
| `str` / `int` / `float` / `type` | Simple conversions |
| `range` | Builds a concrete `list` of integers (not a lazy range object) |

## 6. CLI / I/O

- Entry: `pub fn main(init: std.process.Init) !void` (Zig 0.16 process API).
- File contents read via `posix.openat` + `std.c.read`.
- Program `print` output is collected in an `ArrayList(u8)` and written to **stdout** (`STDOUT_FILENO`).
- Diagnostics (parse/runtime errors, DebugAllocator leak reports) go to stderr via `std.debug.print`.

## 7. Memory notes

| Data | Allocator | Lifetime |
|------|-----------|----------|
| AST nodes, interned parse strings | `ast_arena` | Until `freeAst` / `deinit` |
| Runtime strings, lists, `range` results | `runtime_arena` | Until `freeRuntime` / `deinit` |
| Environment keys | GPA | Until env `deinit` |

File mode calls `freeAst()` and `freeRuntime()` after a successful run. A clean Debug build should report **no** leaks for `examples/demo.py`.

REPL keeps both arenas until process exit so definitions and values remain valid across lines.

## 8. Extending zpython

Reasonable next steps:

1. **Dicts / tuples**  new `Value` tags + literal syntax.
2. **Exceptions**  `try`/`except` and a structured error type instead of a flat `RuntimeError`.
3. **Classes**  object values, attribute store, `self`.
4. **Value arena or RC**  free runtime strings/lists systematically.
5. **Better diagnostics**  attach `line`/`column` from tokens to parse and runtime errors.
6. **Compound assignment**  tokens `+=` / `-=` already exist; wire them in the parser.

## 9. Build system

- `build.zig` defines module `zpython` (`src/root.zig`) and executable `zpython` (`src/main.zig`).
- `link_libc = true` on the executable root module (POSIX/C I/O helpers).
- Tests: default template tests may still exist under `src/main.zig`; core language tests are currently manual via `examples/demo.py`.

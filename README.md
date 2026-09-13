# zpython

A minimal **Python** subset interpreter written in **Zig 0.16**.

It is a learning / experimentation project, not a replacement for CPython.

## Requirements

- [Zig 0.16](https://ziglang.org/) (the project sets `minimum_zig_version = "0.16.0"`)

## Build

```bash
zig build
```

Binary: `zig-out/bin/zpython`

```bash
# REPL
./zig-out/bin/zpython

# Run a script
./zig-out/bin/zpython examples/demo.py
```

## Quick examples

```python
print(1 + 2 * 3)           # 7
print("hello" + " world")  # hello world

x = 0
while x < 3:
    print(x)
    x = x + 1

for i in range(5):
    print(i)

def fact(n):
    if n <= 1:
        return 1
    return n * fact(n - 1)

print(fact(5))  # 120
```

See `examples/demo.py` for a longer walkthrough.

## Feature overview

| Area | Supported |
|------|-----------|
| Types | `int`, `float`, `str`, `bool`, `None`, `list`, functions |
| Operators | `+ - * / // % **`, comparisons, `and` / `or` / `not` |
| Statements | assignment, `print`, `if`/`elif`/`else`, `while`, `for`, `def`, `return`, `pass`, `break`, `continue` |
| Builtins | `print`, `len`, `str`, `int`, `float`, `type`, `range` |
| Indentation | Significant whitespace (Indent / Dedent tokens) |

Memory: AST and runtime values use arenas (`ast_arena`, `runtime_arena`); file runs free both after execution.

**Not implemented** (non-exhaustive): classes, exceptions, `import`, dicts/sets/tuples, slices, comprehensions, closures, kwargs, f-strings, generators.

## Project layout

```
zpython/
├── build.zig / build.zig.zon
├── README.md
├── DOCUMENTATION.md
├── examples/demo.py
└── src/
    ├── main.zig          CLI + REPL
    ├── root.zig          Package root
    ├── token.zig         Token kinds + keywords
    ├── lexer.zig         Indent-aware tokenizer
    ├── ast.zig           Expression & statement AST
    ├── parser.zig        Recursive-descent / precedence parser
    ├── value.zig         Runtime values + operators
    └── interpreter.zig   Environments, eval, builtins
```

## License

No explicit license file is included; treat the code as available for study and modification unless you add your own terms.

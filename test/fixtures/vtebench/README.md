# vtebench fixtures

Binary VT payloads captured from [alacritty/vtebench](https://github.com/alacritty/vtebench)
for headless engine throughput tests (`test/engine_benchmark_test.dart`).

| File | Source benchmark | Notes |
|------|------------------|-------|
| `medium_cells.bin` | `medium_cells/vim_session` | Escape-heavy vim reflow |
| `sync_medium_cells.bin` | `sync_medium_cells/vim_session` | Synchronous variant |
| `unicode.bin` | `unicode/symbols` | Wide / combining glyphs |
| `dense_cells.bin` | `dense_cells/benchmark` @ 80×24 | Generated in a pseudo-TTY |
| `light_cells.bin` | `light_cells/benchmark` @ 80×24 | Generated in a pseudo-TTY |

## Regenerate (Linux)

```bash
git clone --depth 1 https://github.com/alacritty/vtebench.git /tmp/vtebench
FIX=test/fixtures/vtebench

cp /tmp/vtebench/benchmarks/medium_cells/vim_session "$FIX/medium_cells.bin"
cp /tmp/vtebench/benchmarks/sync_medium_cells/vim_session "$FIX/sync_medium_cells.bin"
cp /tmp/vtebench/benchmarks/unicode/symbols "$FIX/unicode.bin"

script -qefc 'stty cols 80 rows 24 2>/dev/null; /tmp/vtebench/benchmarks/dense_cells/benchmark' /dev/null \
  | head -c 2097152 > "$FIX/dense_cells.bin"
script -qefc 'stty cols 80 rows 24 2>/dev/null; /tmp/vtebench/benchmarks/light_cells/benchmark' /dev/null \
  | head -c 1048576 > "$FIX/light_cells.bin"
```

After regenerating, run `flutter test --tags benchmark` and adjust ceilings in
`test/support/benchmark_thresholds.dart` if intentional perf changed.

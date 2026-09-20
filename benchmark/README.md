# Scoop-Shim Performance Benchmark

- Target: `C:\Windows\System32\whoami.exe` (built-in Windows executable)
- Tool: [hyperfine](https://github.com/sharkdp/hyperfine)
- Architecture: auto-detected (x64/x86/arm64)

Candidates are interleaved in randomized rounds and reported as pooled medians with the inter-quartile range. CPU time (user+system) is reported next to wall clock because wall clock is unreliable on a busy machine.

Before timing, each shim is run once untimed as a canary; a candidate that exits nonzero is dropped from the run (with a warning) so a broken build cannot be reported as the fastest.

## Usage

```powershell
.\benchmark.ps1
.\benchmark.ps1 -Rounds 20 -Runs 25 -Warmup 5
```

Defaults: `-Rounds 10`, `-Runs 15`, `-Warmup 5`, `-Arch auto` (x86/x64/arm64); `-UseShell` forces the system shell, which is also used when a path contains spaces.

Edit `shims/template.shim` to change the benchmark target.

## Results

x64, 10 rounds x 15 runs:

| Implementation | Wall [ms] | Wall IQR | CPU [ms] | CPU IQR | CPU overhead [ms] |
| -------------- | --------: | -------: | -------: | ------: | ----------------: |
| `direct`       |      40.2 |      6.8 |     31.2 |     6.3 |                 - |
| `C++`          |      77.0 |     10.9 |     64.6 |    12.5 |             +33.4 |
| `Zig`          |      75.5 |     10.4 |     65.6 |     6.3 |             +34.4 |
| `Rust`         |      74.8 |      9.8 |     67.7 |    13.5 |             +36.5 |
| `C#`           |     119.2 |     12.8 |    117.7 |     6.2 |             +86.5 |

The native shims are within each other's inter-quartile ranges and cannot be ranked by this benchmark. C# pays .NET Framework runtime startup on every launch.

## Files

- `benchmark.ps1` - benchmark runner
- `shims/template.shim` - .shim content template
- `results.md` / `results.json` - last run, regenerated on every run (not tracked)

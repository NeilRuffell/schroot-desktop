# Performance Baseline

Reference machine: **iMac18,1** with an Intel Core i5-7360U and Intel Iris Plus Graphics 640.

This document records the tested baseline for the Schroot Desktop architecture. The result of the audit was that **no low-level performance tuning was required**.

## CPU

Reference CPU:

```text
Intel Core i5-7360U
4 logical CPUs
base clock 2.30 GHz
reported max 3.60 GHz
```

Observed scaling configuration:

```text
driver:     intel_pstate
governor:   powersave
EPP:        balance_performance
minimum:    ~400 MHz
maximum:    ~3.6 GHz
```

This configuration was retained. With `intel_pstate`, the `powersave` governor does not mean the CPU is locked at low frequency.

Observed behavior:

```text
idle:       ~400 MHz
full load:  ~3.6 GHz on all four logical CPUs
```

A one-minute, four-thread CPU load test reported approximately 3.6 GHz throughout.

Observed package temperature during that test:

```text
start: 38 C
end:   50 C
```

No frequency collapse or thermal-throttling behavior was observed during the test.

Idle temperatures before the sustained test:

```text
CPU package: 33 C
Core 0:      31 C
Core 1:      32 C
NVMe:        25 C
```

## Graphics

Debian host:

```text
Intel Iris Plus Graphics 640
kernel driver: i915
Xorg driver: modesetting
direct rendering: Yes
Mesa 25.0.7-2+deb13u1
OpenGL 4.6 compatibility profile
```

Xenial:

```text
Intel Iris Plus Graphics 640
direct rendering: Yes
Mesa 18.0.5
OpenGL 3.0
```

Neither environment was using software rendering.

## Desktop compositor

The active Ubuntu MATE configuration was confirmed as:

```text
Marco:   marco --no-composite --replace
Compton: GLX backend
```

Therefore Marco and Compton were not double-compositing. Compton owns compositing while Marco runs as the window manager.

The existing **Marco (Compton GPU compositor)** configuration was retained.

## Idle CPU

A 15-second idle sample showed the system typically around:

```text
98–99.5% CPU idle
```

During settled samples:

```text
Xorg:     0.0%
Marco:    0.0%
Compton:  0.0%
Caja:     0.0%
```

No meaningful idle CPU overhead from the schroot desktop architecture was identified.

## Memory

Observed during the audit:

```text
RAM total:      7.6 GiB
RAM available:  5.5 GiB
swap used:      0 B
```

No memory or swap pressure was present.

## Accepted conclusion

No performance-specific changes were made.

The tested baseline supports keeping:

```text
intel_pstate + powersave + balance_performance
Xorg modesetting + i915
hardware-accelerated Mesa on both sides
Marco + Compton GPU compositor
existing swap configuration
```

Future performance work should be driven by a specific slow application or reproducible workload rather than generic Linux tuning.

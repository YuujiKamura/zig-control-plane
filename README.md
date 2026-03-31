# zig-control-plane

A Named Pipe control plane library for terminal emulators, written in Zig.

Enables AI agents and external tools to programmatically interact with terminal sessions — send input, read output, query state, manage tabs — over Windows Named Pipes.

## What It Does

- **Named Pipe server** with overlapped I/O, multi-client support, and SDDL security
- **Protocol**: line-based text over pipes — `PING`, `STATE`, `TAIL`, `INPUT`, `LIST_TABS`, `FOCUS`, `HISTORY`
- **1-shot and persistent** connection modes
- **Provider pattern**: the terminal emulator implements a trait (`CpProvider`) to expose its state; the library handles all IPC plumbing

## Used By

- [ghostty-win](https://github.com/YuujiKamura/ghostty) — WinUI3 native Windows GUI for the Ghostty terminal
- [agent-deck](https://github.com/YuujiKamura/agent-deck) — multi-session AI agent orchestrator that talks to terminals via this protocol

## Protocol Example

```
→ PING
← PONG|ghostty-1234|1234|0x12AB

→ STATE
← STATE|ghostty-1234|IDLE|1|0|cmd.exe|C:\Users\me|$ echo hello...

→ INPUT|agent|ZWNobyBoZWxsbwo=
← ACK|INPUT

→ TAIL|10
← TAIL|ghostty-1234|10|...(base64 viewport)...
```

## Build

Consumed as a Zig package dependency via `build.zig.zon`:

```zig
.zig_control_plane = .{ .path = "../zig-control-plane" },
```

## Architecture

```
┌─────────────┐     Named Pipe      ┌──────────────┐
│  agent-deck │ ◄──────────────────► │  PipeServer  │
│  (client)   │   PING/STATE/INPUT   │  (library)   │
└─────────────┘                      └──────┬───────┘
                                            │ CpProvider trait
                                     ┌──────▼───────┐
                                     │   Terminal    │
                                     │  (ghostty)   │
                                     └──────────────┘
```

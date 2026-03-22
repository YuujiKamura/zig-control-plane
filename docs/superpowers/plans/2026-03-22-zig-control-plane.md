# Zig Control Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Rust control-plane-server DLL with pure Zig implementation that integrates directly into ghostty-win, eliminating DLL build/deploy complexity and VTable ABI risks.

**Architecture:** Named pipe server in Zig, text protocol parser, TabIdManager with AutoHashMap, session file I/O. Lives in `zig-control-plane` repo as a Zig package, imported by ghostty-win. The ghostty-win side has a thin integration layer (`control_plane.zig`) that wires pipe commands to `app.performAction()` and direct Surface access.

**Tech Stack:** Zig 0.15, Windows Named Pipes (CreateNamedPipeW + overlapped I/O), std.AutoHashMap, std.mem.splitScalar, std.base64.standard

**Repos:**
- `zig-control-plane` — reusable CP library (pipe server, protocol, TabIdManager, session file)
- `ghostty-win` — integration layer (Action mapping, Surface access)

**Wire compatibility:** 100% compatible with existing agent-deck WTCP driver. No Go changes needed.

---

## File Structure

### zig-control-plane (library)

| File | Responsibility |
|------|---------------|
| `src/protocol.zig` | Request parsing, response formatting, TabTarget, base64, escape |
| `src/tab_id.zig` | TabIdManager — monotonic ID allocation, ID⇔Index bidirectional map |
| `src/pipe_server.zig` | Named pipe lifecycle — CreateNamedPipeW, overlapped I/O, client loop |
| `src/session.zig` | Session file write/remove, name sanitization, discovery path |
| `src/utils.zig` | slice_last_lines, infer_prompt |
| `src/main.zig` | Public API: ControlPlane struct, init/deinit/start/stop |
| `build.zig` | Package definition |
| `build.zig.zon` | Package metadata |

### ghostty-win (integration)

| File | Responsibility |
|------|---------------|
| `src/apprt/winui3/control_plane.zig` | NEW: Wires CP commands → performAction / Surface access |
| `src/apprt/winui3/App.zig` | MODIFY: Replace `control_plane_ffi` with native `control_plane` |

### Deleted after migration

| File | Why |
|------|-----|
| `src/apprt/winui3/control_plane_ffi.zig` | Replaced by control_plane.zig |
| `control-plane-server/` repo (Rust) | Entire DLL eliminated |

---

## Task 1: Protocol Parser

**Files:**
- Create: `zig-control-plane/src/protocol.zig`
- Test: inline `test` blocks

- [ ] **Step 1: Write failing test for PING parse**

```zig
const std = @import("std");
const protocol = @import("protocol.zig");

test "parse PING" {
    const req = try protocol.Request.parse("PING");
    try std.testing.expectEqual(.ping, req);
}
```

- [ ] **Step 2: Define Request enum and parse function**

Request variants: ping, state, tail, list_tabs, input, raw_input, new_tab, close_tab, switch_tab, focus, msg, agent_status, set_agent.

TabTarget: `const TabTarget = union(enum) { none, index: usize, id: []const u8 };`

Parse: split on `|`, match first field, parse TabTarget from optional trailing field (`id=xxx` or numeric).

- [ ] **Step 3: Write tests for all command variants**

Cover: STATE|id=t_001, TAIL|50|2, INPUT|agent|aGVsbG8=, CLOSE_TAB|id=t_001, backward compat (index only).

- [ ] **Step 4: Write response formatting**

`formatPong`, `formatState`, `formatTail`, `formatListTabs`, `formatAck`, `formatError`. All return `[]u8` from allocator. Field escaping: `|` → space, `\n` → space.

- [ ] **Step 5: Build and test**

Run: `zig build test`

- [ ] **Step 6: Commit**

```
feat: protocol parser — all CP commands + response formatting
```

---

## Task 2: TabIdManager

**Files:**
- Create: `zig-control-plane/src/tab_id.zig`
- Test: inline `test` blocks

- [ ] **Step 1: Write failing test for register + resolve**

```zig
test "register and resolve" {
    var mgr = TabIdManager.init(std.testing.allocator);
    defer mgr.deinit();
    const id = try mgr.registerNewTab(0);
    try std.testing.expectEqualStrings("t_000", id);
    try std.testing.expectEqual(@as(?usize, 0), mgr.resolve("t_000"));
}
```

- [ ] **Step 2: Implement TabIdManager**

Fields: `next_id: u64`, `id_to_index: std.StringHashMap(usize)`, `index_to_id: std.AutoHashMap(usize, []const u8)`.

Methods: `init`, `deinit`, `registerNewTab`, `resolve`, `getId`, `syncTabs`, `removeTab`, `removeTabAtIndex`, `shiftIndicesDown`.

- [ ] **Step 3: Write remaining tests**

Cover: remove_tab shifts indices, sync_tabs grow/shrink, get_id.

- [ ] **Step 4: Build and test**

Run: `zig build test`

- [ ] **Step 5: Commit**

```
feat: TabIdManager — monotonic ID allocation with bidirectional map
```

---

## Task 3: Session File Manager

**Files:**
- Create: `zig-control-plane/src/session.zig`
- Test: inline `test` blocks

- [ ] **Step 1: Implement SessionManager**

```zig
pub const SessionManager = struct {
    session_name: []const u8,
    safe_session_name: []const u8,
    pid: u32,
    pipe_path: []const u8,
    session_file_path: []const u8,
    allocator: Allocator,

    pub fn init(allocator, session_name, pipe_path, app_name) !SessionManager
    pub fn writeFile(self, hwnd: usize) !void
    pub fn removeFile(self) void
    pub fn deinit(self) void
};

pub fn sanitizeSessionName(name: []const u8) []const u8
```

- [ ] **Step 2: Write tests**

Test sanitization (special chars → `_`, trim, empty → "session"), file write/read round-trip using tmp dir.

- [ ] **Step 3: Build and test**

- [ ] **Step 4: Commit**

```
feat: session file manager — write/remove/sanitize
```

---

## Task 4: Named Pipe Server

**Files:**
- Create: `zig-control-plane/src/pipe_server.zig`
- No unit tests (requires integration test with actual pipe)

- [ ] **Step 1: Implement PipeServer**

```zig
pub const PipeServer = struct {
    pipe_path: [:0]const u16,  // UTF-16 for CreateNamedPipeW
    stop: std.atomic.Value(bool),
    thread: ?std.Thread,
    handler: *const fn(request: []const u8, ctx: *anyopaque) []const u8,
    ctx: *anyopaque,

    pub fn init(pipe_path, handler, ctx) PipeServer
    pub fn start(self) !void      // spawn thread
    pub fn stop(self) void        // set stop flag, join thread
};
```

Win32 calls: `CreateNamedPipeW`, `ConnectNamedPipe`, `ReadFile`, `WriteFile`, `FlushFileBuffers`, `DisconnectNamedPipe`, `CloseHandle`. All with overlapped I/O + `WaitForSingleObject(event, 1000ms)` for interruptible loop.

Security: SDDL `D:(A;;GA;;;OW)` via `ConvertStringSecurityDescriptorToSecurityDescriptorW`.

- [ ] **Step 2: Write integration smoke test**

Spawn server, connect with `CreateFileW`, send PING, verify PONG response, disconnect, stop server.

- [ ] **Step 3: Build and test**

- [ ] **Step 4: Commit**

```
feat: named pipe server — overlapped I/O with graceful shutdown
```

---

## Task 5: Public API (main.zig) + build.zig

**Files:**
- Create: `zig-control-plane/src/main.zig`
- Modify: `zig-control-plane/build.zig`
- Modify: `zig-control-plane/build.zig.zon`

- [ ] **Step 1: Define ControlPlane struct**

```zig
pub const ControlPlane = struct {
    pipe_server: PipeServer,
    tab_id_manager: TabIdManager,
    session_manager: SessionManager,
    provider: *const Provider,
    allocator: Allocator,
    session_name: []const u8,
    pid: u32,

    /// Provider interface — all callbacks receive ctx for App access.
    ///
    /// THREAD SAFETY:
    /// - Read callbacks (readBuffer, tabCount, etc.) are called from pipe thread.
    ///   ghostty-win implementation must ensure thread-safe reads (capture snapshots).
    /// - Mutation callbacks (sendInput, newTab, closeTab, switchTab, focus) are
    ///   called from pipe thread. Implementation MUST use PostMessage to enqueue
    ///   and return immediately — never touch UI state directly.
    ///
    /// MEMORY OWNERSHIP:
    /// - Callbacks that return []const u8 write into a caller-provided buffer
    ///   (buf: []u8) and return bytes written. No allocation needed.
    /// - This matches the existing VTable pattern (tab_title fills buf, returns len).
    pub const Provider = struct {
        ctx: *anyopaque,
        /// Read terminal buffer. tab_index=null → active tab.
        /// Writes into buf, returns bytes written.
        readBuffer: *const fn(ctx: *anyopaque, tab_index: ?usize, buf: []u8) usize,
        /// Send input text. tab_index=null → active tab.
        /// MUST enqueue + PostMessage, return immediately.
        sendInput: *const fn(ctx: *anyopaque, text: []const u8, raw: bool, tab_index: ?usize) void,
        tabCount: *const fn(ctx: *anyopaque) usize,
        activeTab: *const fn(ctx: *anyopaque) usize,
        /// Write tab title into buf, return bytes written. 0 = not found.
        tabTitle: *const fn(ctx: *anyopaque, index: usize, buf: []u8) usize,
        /// Write tab working dir into buf, return bytes written. 0 = not found.
        tabWorkingDir: *const fn(ctx: *anyopaque, index: usize, buf: []u8) usize,
        tabHasSelection: *const fn(ctx: *anyopaque, index: usize) bool,
        /// MUST PostMessage, return immediately.
        newTab: *const fn(ctx: *anyopaque) void,
        /// MUST PostMessage, return immediately.
        closeTab: *const fn(ctx: *anyopaque, index: usize) void,
        /// MUST PostMessage, return immediately.
        switchTab: *const fn(ctx: *anyopaque, index: usize) void,
        /// MUST PostMessage, return immediately.
        focus: *const fn(ctx: *anyopaque) void,
        hwnd: *const fn(ctx: *anyopaque) usize,
    };

    pub fn init(allocator, session_name, pipe_prefix, app_name, provider) !ControlPlane
    pub fn start(self) !void
    pub fn stop(self) void
    pub fn deinit(self) void
};
```

**Known race condition (inherited from Rust DLL):** `NEW_TAB` calls `provider.newTab()` (PostMessage) then immediately `provider.tabCount()`. The count may be stale because the UI thread hasn't processed the message yet. The returned tab ID is assigned to the next available index. This is acceptable — `LIST_TABS` will re-sync on next call.

**Buffer sizes:** Pipe buffer = 65536 bytes. Read buffer = 65536. TAIL response can exceed pipe buffer (multi-write). Read timeout = 10000ms. Connect timeout = 1000ms poll loop.

**Base64:** Use `std.base64.standard.Decoder` for INPUT/RAW_INPUT payload decoding.

**Escaping:** `escape_field` replaces `|` → space, `\n` → space, `\r` → space.

- [ ] **Step 2: Implement request dispatch**

Wire `PipeServer.handler` to: parse Request → match → call Provider functions → format response. Include TabIdManager sync on LIST_TABS, register on NEW_TAB, remove on CLOSE_TAB.

- [ ] **Step 3: Write build.zig**

Expose as Zig package with `addModule`. Windows-only (link kernel32, advapi32, user32).

- [ ] **Step 4: Build full library**

Run: `zig build`

- [ ] **Step 5: Commit**

```
feat: ControlPlane public API — init/start/stop + request dispatch
```

---

## Task 6: ghostty-win Integration

**Files:**
- Create: `ghostty-win/src/apprt/winui3/control_plane.zig`
- Modify: `ghostty-win/src/apprt/winui3/App.zig`
- Modify: `ghostty-win/build.zig` (add zig-control-plane dependency)

- [ ] **Step 1: Add zig-control-plane as dependency**

In ghostty-win `build.zig.zon`, add path dependency to `~/zig-control-plane`.
In `build.zig`, add module import.

- [ ] **Step 2: Create control_plane.zig integration layer**

Implement `Provider` callbacks that call App/Surface directly:
- `readBuffer` → `surface.core_surface.read_buffer()` (or equivalent)
- `sendInput` → `surface.textCallback()`
- `tabCount` → `app.surfaces.items.len`
- `activeTab` → `app.active_surface_idx`
- `newTab` → `app.performAction(.new_tab, ...)`
- `closeTab` → `app.performAction(.close_tab, ...)`
- `switchTab` → `app.performAction(.goto_tab, ...)`
- `focus` → `app.performAction(.present_terminal, ...)`

Also: `isEnabled()` check (env var), `create()`, `destroy()`.

- [ ] **Step 3: Replace control_plane_ffi.zig usage in App.zig**

Change `App.control_plane` type from `?*ControlPlaneFfi` to `?*ControlPlane`.
Update init, deinit, and all references.

Remove: `@import("control_plane_ffi.zig")` usage.

- [ ] **Step 4: Build ghostty-win**

Run: `./build-winui3.sh`

- [ ] **Step 5: E2E test with wtcp**

```bash
GHOSTTY_CONTROL_PLANE=1 ./zig-out-winui3/bin/ghostty.exe &
sleep 8
cd ~/agent-deck && go run ./cmd/wtcp/ list
cd ~/agent-deck && go run ./cmd/wtcp/ send --id t_001 "echo hello"
cd ~/agent-deck && go run ./cmd/wtcp/ tail --id t_001 10
```

- [ ] **Step 6: Commit**

```
feat: Zig-native control plane — eliminates Rust DLL dependency
```

---

## Task 7: Cleanup

**Files:**
- Delete: `src/apprt/winui3/control_plane_ffi.zig`
- Modify: `build-winui3.sh` (remove DLL copy step)
- Modify: App.zig (remove any remaining FFI references)

- [ ] **Step 1: Delete control_plane_ffi.zig**
- [ ] **Step 2: Remove DLL copy from build-winui3.sh**
- [ ] **Step 3: Full build + test**

Run: `./build-winui3.sh` (should not mention control_plane_server.dll)
Run: `zig build test` (Zig unit tests)
Run: wtcp E2E test

- [ ] **Step 4: Commit and push all repos**

```
refactor: remove Rust DLL dependency — Zig-native CP complete
```

---

## Risk Mitigation

1. **Overlapped I/O complexity**: Rust's server.rs is 425 LOC of Win32 pipe handling. Port carefully, test each step.
2. **Thread safety**: Provider callbacks are called from pipe thread. Use PostMessage for UI mutations (same as current WndProc pattern).
3. **Rollback**: Keep control_plane_ffi.zig until Task 7. If Zig CP fails, revert to DLL.
4. **agent-deck compat**: Wire format is identical. No Go changes needed. Verify with E2E.

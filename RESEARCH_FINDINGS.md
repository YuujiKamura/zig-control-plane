# Research Findings: `pipe_server.zig`

調査対象:

1. Windows Named Pipe の overlapped I/O で、サーバー側 `CancelIoEx` 時のクライアント側 `ReadFile` の挙動
2. Zig の `std.os.windows.kernel32.ReadFile` を overlapped handle に同期呼び出しした場合の扱い
3. `pushEvent` が subscriber に書き込む際の、クライアント側 overlapped `ReadFile` との競合条件

## 結論

### 1. `CancelIoEx` はクライアント側 `ReadFile` を直接 `995` にしない

`CancelIoEx(hFile, lpOverlapped)` が cancel するのは、その **handle 上で現在プロセスが発行した I/O** だけ。
サーバー側の pipe handle に対する `CancelIoEx` は、クライアント側プロセスの別 handle に対する pending `ReadFile` を直接 `ERROR_OPERATION_ABORTED (995)` にしない。

`995` が返るのは、その I/O 自身が cancel 完了したとき。
つまりクライアント側 `ReadFile` が `995` になるのは、クライアント自身の cancel か、同一プロセス内でその handle 上の I/O が cancel された場合。

サーバー側が pending read を cancel してから `DisconnectNamedPipe` / `CloseHandle` した場合、クライアント側で起きるべきなのは通常 `ERROR_BROKEN_PIPE (109)` や `ERROR_NO_DATA (232)` 系。

したがって、`pipe_server.zig` 側で `ERROR_OPERATION_ABORTED` を `BrokenPipe` と同一視するのは誤り。

### 2. Overlapped handle に対して `lpOverlapped = NULL` で `ReadFile/WriteFile` するのは Win32 契約違反

Microsoft の `ReadFile` / `WriteFile` の仕様では、`FILE_FLAG_OVERLAPPED` で開いた handle では `lpOverlapped` は必須で、valid かつ unique な `OVERLAPPED` を渡す必要がある。

これは Zig 固有の undefined behavior というより、Win32 API 契約違反。
Zig の `std.os.windows.kernel32.ReadFile` / `WriteFile` は単なる extern 宣言なので、防御してくれない。

つまり `pipe_server.zig` で overlapped pipe handle に対して同期 `WriteFile(..., null)` を使っているなら、それ自体を修正すべき。

### 3. `pushEvent` とクライアント側 overlapped `ReadFile` は本質的には競合しない

Named pipe は duplex。
サーバー側 `WriteFile` とクライアント側 `ReadFile` は、正常な read/write 対応であって競合ではない。

問題は別で、**同じ server-side pipe handle** に対して pending overlapped `ReadFile` がある設計なのに、書き込み側が別の I/O モードや曖昧な completion 管理をしていること。

Microsoft の named pipe overlapped I/O サンプルでも、single pipe instance で同時操作を雑に混ぜないようにしている。

今の設計で守るべき制約は:

- subscriber への実書き込みは owner client thread だけが行う
- 同一 handle 上の read/write は両方とも Win32 の overlapped 契約に従う
- `CancelIoEx` の completion を disconnect と誤認しない

## `pipe_server.zig` の具体的修正方針

### A. `getOverlappedBytes`

対象: `src/pipe_server.zig`

今の問題:

- `ERROR_OPERATION_ABORTED (995)` を `error.BrokenPipe` に丸めている

修正:

- `995` を `error.OperationAborted` として分離する
- `109` / `232` のみ `error.BrokenPipe`
- 必要なら `ERROR_IO_INCOMPLETE` も分離
- その他は `error.Unexpected`

理由:

- `995` は cancel 完了ステータスであって remote disconnect の証拠ではない

### B. `readRequestLine`

対象: `src/pipe_server.zig`

今の問題:

- timeout / wakeup 時に `CancelIoEx(pipe, &overlapped)` した後、`getOverlappedBytes` が `995` を返すと `BrokenPipe` として `null` になり、切断誤判定になる

修正:

- timeout / wakeup のための self-cancel と remote disconnect を分離する
- `CancelIoEx` 後の completion で `error.OperationAborted` が返ったら切断扱いしない
- cancel race で正常完了 bytes が返った場合だけ salvage を継続
- `WAIT_TIMEOUT` / wakeup は「read 中断して loop を回す」だけにする

要点:

- 自分で cancel した結果の `995` は正常な制御フロー
- それを disconnect にしてはいけない

### C. `writeAll`

対象: `src/pipe_server.zig`

今の問題:

- overlapped handle に対して同期 `WriteFile(..., &written, null)` を使っているなら Win32 契約違反
- `FlushFileBuffers` を push path に入れると不必要に block する

修正:

- `writeAll` を overlapped `WriteFile` に変更
- call ごとに event と `OVERLAPPED` を作る
- `ERROR_IO_PENDING` なら event wait + `GetOverlappedResult`
- `109` / `232` は `BrokenPipe`
- `995` は local cancel として別扱い
- `FlushFileBuffers` は push event path から外す

理由:

- overlapped handle は read/write 両方とも overlapped 契約で揃えるべき
- named pipe server end の `FlushFileBuffers` は client 読み切り待ちで block し得る

### D. `isPipeBroken`

対象: `src/pipe_server.zig`

今の問題:

- `995` を broken 判定に含めると local cancel を remote disconnect と誤認する

修正:

- broken 判定は `109` / `232` 中心にする
- `995` は broken 扱いしない
- 可能なら事前 probe よりも、実際の write failure で subscriber 除去する方が安全

### E. `pushEvent` / `deliverPendingForPipe`

対象: `src/pipe_server.zig`

現方針の評価:

- `pushEvent` は queue のみ
- 実際の write は owner client thread が行う

これは正しい。
別 thread が subscriber pipe に直接 `WriteFile` しない制約は維持すべき。

ただしコメントは修正した方がいい。
本当に避けたい競合は「クライアントの `ReadFile`」ではなく、「同一 server-side handle 上の read/write completion 管理の破綻」。

## 実装時の要点

- `server cancel -> client read gets 995` という前提では実装しない
- `995` は cancel 完了であり、broken pipe ではない
- overlapped handle に対する `ReadFile/WriteFile` は `OVERLAPPED` 必須
- subscriber への送信は owner thread のみが行う

## 参照

- Microsoft Learn: `CancelIoEx`
- Microsoft Learn: `ReadFile`
- Microsoft Learn: `WriteFile`
- Microsoft Learn: `Named Pipe Server Using Overlapped I/O`

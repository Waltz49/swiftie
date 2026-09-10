# CLIP Background Worker IPC

Extracted from `browser_window/managers/background_clip_controller.py` and `workers/background_clip_worker.py`.

## Socket paths (under profile `data/`)

| Socket | Direction | Purpose |
|--------|-----------|---------|
| `background_clip_control.sock` | Swift → Worker | Commands |
| `background_clip_status.sock` | Worker → Swift | Status updates |

## Lifecycle

1. Swift removes stale socket files (if needed).
2. Swift starts a **status** Unix socket server at `background_clip_status.sock`.
3. Swift spawns `workers/background_clip_worker.py` (multiprocessing spawn in Python UI).
4. Swift sends a **start** command on the **control** socket with `status_socket_path`.
5. Worker connects to the status socket and pushes JSON status objects.
6. Swift polls/accepts status connections (non-blocking).

## Control command (Swift → Worker)

Single JSON payload per connection (no newline delimiter):

```json
{
  "command": "start",
  "foreground_busy": false,
  "directories": ["/Users/me/Pictures"],
  "debug_mode": false,
  "last_update": 1710000000.0,
  "status_socket_path": "/Users/me/.prowser/data/background_clip_status.sock"
}
```

### Commands

| `command` | When |
|-----------|------|
| `start` | Launch processing (worker creates control socket if needed) |
| `resume` | Resume after pause; may include updated `directories` |
| `pause` | Pause indexing |
| `stop` | Stop worker |
| `flush_and_pause` | Flush caches then pause (generation memory pressure) |

`stop` is allowed even when background CLIP is disabled in settings.

## Status message (Worker → Swift)

Worker opens a short-lived connection to `status_socket_path` and sends one JSON object:

```json
{
  "status": "running",
  "last_update": 1710000000.0,
  "indexed_files": 120,
  "total_files": 400,
  "current_directory": "/Users/me/Pictures"
}
```

### `status` values

| Value | Meaning |
|-------|---------|
| `stopped` | Not running |
| `running` | Actively indexing |
| `paused` | Idle / paused |
| `error` | Fatal error (see logs under `logs/background_clip_worker.log`) |

## Swift `CLIPBridge`

- Mirrors `BackgroundClipController` lifecycle.
- Respects `background_clip_enabled` in `settings.json`.
- On directory load, calls `restartWithPriorityDirectory(_:)` when enabled.
- Uses `PythonLocator` to spawn the worker process.

## Related settings keys

- `background_clip_enabled`
- `background_clip_gather_thumbnails`
- `background_clip_extract_faces`

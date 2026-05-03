# EdgeOS Roadmap

## Clip Storage Management

Prevent edge disks from filling up with recorded clips.

**Approach:** configurable retention policy in `config.json`, enforced by an hourly background task on the edge.

```json
{
  "clip_retention_days": 30,
  "clip_max_gb": 20
}
```

**Cleanup logic (run every hour):**
1. Delete clips older than `clip_retention_days`
2. If total clip directory size still exceeds `clip_max_gb`, delete oldest clips first until under quota
3. For each deleted file, set `clip_path = NULL` in the SQLite DB so the UI degrades gracefully (thumbnail still shown, Play/Save buttons hidden)

**Optional:** shorter retention for liveview clips vs. YOLO-detected event clips (e.g. 3 days vs. 30 days), since liveview clips are lower value.

**Implementation notes:**
- Background tokio task in `camera_manager.rs` alongside the HTTP server
- Reads retention config from the same `config.json` as cameras
- Touches only the `clips/` directory and `events.clip_path` column

use anyhow::anyhow;
use log::info;
use rusqlite::{Connection, params};

pub struct EventStore {
    conn: Connection,
}

pub struct Event {
    pub id:             i64,
    pub camera_id:      String,
    #[allow(dead_code)]
    pub class_id:       usize,
    pub class_name:     String,
    pub started_at:     i64,
    pub ended_at:       Option<i64>,
    pub best_confidence: f32,
    pub frame_count:    u32,
    pub clip_path:      Option<String>,
}

impl EventStore {
    pub fn new(db_path: &str) -> anyhow::Result<Self> {
        let conn = Connection::open(db_path)?;
        conn.execute_batch("PRAGMA journal_mode=WAL;")?;
        conn.execute_batch("
            CREATE TABLE IF NOT EXISTS events (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                camera_id       TEXT    NOT NULL,
                class_id        INTEGER NOT NULL,
                class_name      TEXT    NOT NULL,
                started_at      INTEGER NOT NULL,
                ended_at        INTEGER,
                best_confidence REAL    NOT NULL,
                best_frame      BLOB    NOT NULL,
                frame_count     INTEGER NOT NULL DEFAULT 1,
                clip_path       TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_events_camera_ts
                ON events(camera_id, started_at DESC);
        ")?;
        info!("[event_store] opened {db_path}");
        Ok(Self { conn })
    }

    /// Insert a new active event, return its row id.
    pub fn start_event(
        &self,
        camera_id:  &str,
        class_id:   usize,
        class_name: &str,
        confidence: f32,
        frame_jpeg: &[u8],
        started_at: i64,
    ) -> anyhow::Result<i64> {
        self.conn.execute(
            "INSERT INTO events (camera_id, class_id, class_name, started_at, best_confidence, best_frame)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![camera_id, class_id as i64, class_name, started_at, confidence, frame_jpeg],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    /// Replace the best frame if a higher-confidence detection arrives.
    pub fn update_best_frame(
        &self,
        id:         i64,
        frame_jpeg: &[u8],
        confidence: f32,
    ) -> anyhow::Result<()> {
        self.conn.execute(
            "UPDATE events SET best_frame = ?1, best_confidence = ?2, frame_count = frame_count + 1
             WHERE id = ?3",
            params![frame_jpeg, confidence, id],
        )?;
        Ok(())
    }

    /// Increment frame count for an ongoing event without updating the best frame.
    pub fn increment_frame_count(&self, id: i64) -> anyhow::Result<()> {
        self.conn.execute(
            "UPDATE events SET frame_count = frame_count + 1 WHERE id = ?1",
            params![id],
        )?;
        Ok(())
    }

    /// Mark event as ended. clip_path is None until the recording is finalised.
    pub fn end_event(
        &self,
        id:        i64,
        ended_at:  i64,
        clip_path: Option<&str>,
    ) -> anyhow::Result<()> {
        self.conn.execute(
            "UPDATE events SET ended_at = ?1, clip_path = ?2 WHERE id = ?3",
            params![ended_at, clip_path, id],
        )?;
        Ok(())
    }

    /// Update clip_path once the MP4 file is finalised by the pipeline.
    pub fn set_clip_path(&self, id: i64, clip_path: &str) -> anyhow::Result<()> {
        self.conn.execute(
            "UPDATE events SET clip_path = ?1 WHERE id = ?2",
            params![clip_path, id],
        )?;
        Ok(())
    }

    /// Delete a false-positive event (frame_count < min_detections).
    pub fn cancel_event(&self, id: i64) -> anyhow::Result<()> {
        self.conn.execute("DELETE FROM events WHERE id = ?1", params![id])?;
        Ok(())
    }

    /// Fetch recent events across all cameras, newest first.
    pub fn list_all(&self, since: i64, limit: usize) -> anyhow::Result<Vec<Event>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, camera_id, class_id, class_name, started_at, ended_at,
                    best_confidence, frame_count, clip_path
             FROM events
             WHERE started_at >= ?1
             ORDER BY started_at DESC
             LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![since, limit as i64], |row| {
            Ok(Event {
                id:              row.get(0)?,
                camera_id:       row.get(1)?,
                class_id:        row.get::<_, i64>(2)? as usize,
                class_name:      row.get(3)?,
                started_at:      row.get(4)?,
                ended_at:        row.get(5)?,
                best_confidence: row.get(6)?,
                frame_count:     row.get::<_, i64>(7)? as u32,
                clip_path:       row.get(8)?,
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|e| anyhow!(e))
    }

    /// Fetch recent completed events for a camera, newest first.
    pub fn list(
        &self,
        camera_id: &str,
        since:     i64,
        limit:     usize,
    ) -> anyhow::Result<Vec<Event>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, camera_id, class_id, class_name, started_at, ended_at,
                    best_confidence, frame_count, clip_path
             FROM events
             WHERE camera_id = ?1 AND started_at >= ?2
             ORDER BY started_at DESC
             LIMIT ?3",
        )?;
        let rows = stmt.query_map(params![camera_id, since, limit as i64], |row| {
            Ok(Event {
                id:             row.get(0)?,
                camera_id:      row.get(1)?,
                class_id:       row.get::<_, i64>(2)? as usize,
                class_name:     row.get(3)?,
                started_at:     row.get(4)?,
                ended_at:       row.get(5)?,
                best_confidence: row.get(6)?,
                frame_count:    row.get::<_, i64>(7)? as u32,
                clip_path:      row.get(8)?,
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|e| anyhow!(e))
    }

    /// Fetch the clip path for a specific event, if recording is complete.
    pub fn get_clip_path(&self, id: i64) -> anyhow::Result<Option<String>> {
        self.conn.query_row(
            "SELECT clip_path FROM events WHERE id = ?1",
            params![id],
            |row| row.get(0),
        ).map_err(|e| anyhow!(e))
    }

    /// Total number of events for a camera (used for pagination).
    pub fn count(&self, camera_id: &str) -> anyhow::Result<i64> {
        self.conn.query_row(
            "SELECT COUNT(*) FROM events WHERE camera_id = ?1",
            params![camera_id],
            |row| row.get(0),
        ).map_err(|e| anyhow!(e))
    }

    /// Paginated event list for a camera, newest first.
    pub fn list_page(
        &self,
        camera_id: &str,
        offset:    usize,
        limit:     usize,
    ) -> anyhow::Result<Vec<Event>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, camera_id, class_id, class_name, started_at, ended_at,
                    best_confidence, frame_count, clip_path
             FROM events
             WHERE camera_id = ?1
             ORDER BY started_at DESC
             LIMIT ?2 OFFSET ?3",
        )?;
        let rows = stmt.query_map(params![camera_id, limit as i64, offset as i64], |row| {
            Ok(Event {
                id:              row.get(0)?,
                camera_id:       row.get(1)?,
                class_id:        row.get::<_, i64>(2)? as usize,
                class_name:      row.get(3)?,
                started_at:      row.get(4)?,
                ended_at:        row.get(5)?,
                best_confidence: row.get(6)?,
                frame_count:     row.get::<_, i64>(7)? as u32,
                clip_path:       row.get(8)?,
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(|e| anyhow!(e))
    }

    /// Fetch the JPEG thumbnail for a specific event.
    pub fn get_frame(&self, id: i64) -> anyhow::Result<Vec<u8>> {
        self.conn.query_row(
            "SELECT best_frame FROM events WHERE id = ?1",
            params![id],
            |row| row.get(0),
        ).map_err(|e| anyhow!(e))
    }
}

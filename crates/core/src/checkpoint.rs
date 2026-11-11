#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::{
    fs::{self, File, OpenOptions},
    io::{self, BufReader, BufWriter, Write},
    ops::Range,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

use ropey::Rope;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::{
    session::{Buffer, Session},
    Document,
};

static TEMPORARY_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Owns cheap rope snapshots; encoding and disk work can run on a worker thread.
#[derive(Serialize, Deserialize)]
pub struct Checkpoint {
    version: u32,
    active: usize,
    next_scratch: usize,
    buffers: Vec<StoredBuffer>,
}

#[derive(Serialize, Deserialize)]
struct StoredBuffer {
    text: StoredText,
    path: Option<PathBuf>,
    selection: Range<usize>,
    scratch_number: usize,
    dirty: bool,
}

struct StoredText(Rope);

impl Serialize for StoredText {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for StoredText {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        String::deserialize(deserializer).map(|text| Self(Rope::from_str(&text)))
    }
}

impl Checkpoint {
    pub fn capture(session: &Session) -> Self {
        let public: Vec<_> = session
            .buffers
            .iter()
            .enumerate()
            .filter(|(_, buffer)| !buffer.is_private())
            .collect();
        if public.is_empty() {
            return Self::capture(&Session::new("", None));
        }
        let active = public
            .iter()
            .position(|(index, _)| *index == session.active)
            .unwrap_or_else(|| {
                public
                    .iter()
                    .rposition(|(index, _)| *index < session.active)
                    .unwrap_or(0)
            });
        Self {
            version: 1,
            active,
            next_scratch: session.next_scratch,
            buffers: public
                .into_iter()
                .map(|(_, buffer)| {
                    let start = buffer.selection.start.min(buffer.document.len_chars());
                    let end = buffer
                        .selection
                        .end
                        .max(start)
                        .min(buffer.document.len_chars());
                    StoredBuffer {
                        text: StoredText(buffer.document.checkpoint_text()),
                        path: buffer.path.clone(),
                        selection: start..end,
                        scratch_number: buffer.scratch_number,
                        dirty: buffer.document.is_dirty(),
                    }
                })
                .collect(),
        }
    }

    /// Replace only the recovery file, never a buffer's original file destination.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        let sequence = TEMPORARY_COUNTER.fetch_add(1, Ordering::Relaxed);
        let temporary = path.with_file_name(format!(
            ".vibechar-session-{}-{sequence}.tmp",
            std::process::id()
        ));
        let mut options = OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        options.mode(0o600);
        let file = options.open(&temporary)?;
        let result = (|| {
            let mut writer = BufWriter::new(&file);
            serde_json::to_writer(&mut writer, self).map_err(io::Error::other)?;
            writer.flush()?;
            file.sync_all()?;
            fs::rename(&temporary, path)
        })();
        if result.is_err() {
            fs::remove_file(&temporary)?;
        }
        result
    }

    pub fn load(path: &Path) -> io::Result<Option<Session>> {
        let file = match File::open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        let checkpoint: Self =
            serde_json::from_reader(BufReader::new(file)).map_err(|_| invalid_snapshot())?;
        checkpoint.into_session().map(Some)
    }

    fn into_session(self) -> io::Result<Session> {
        let last_scratch = self
            .buffers
            .iter()
            .filter(|buffer| buffer.path.is_none())
            .map(|buffer| buffer.scratch_number)
            .max()
            .unwrap_or(0);
        if self.version != 1
            || self.buffers.is_empty()
            || self.active >= self.buffers.len()
            || self.next_scratch <= last_scratch
            || self.next_scratch == usize::MAX
        {
            return Err(invalid_snapshot());
        }
        let buffers = self
            .buffers
            .into_iter()
            .map(|buffer| {
                if buffer.selection.start > buffer.selection.end
                    || buffer.selection.end > buffer.text.0.len_chars()
                {
                    return Err(invalid_snapshot());
                }
                Ok(Buffer {
                    document: Document::restore(buffer.text.0, buffer.dirty),
                    path: buffer.path,
                    selection: buffer.selection,
                    scratch_number: buffer.scratch_number,
                    private: false,
                })
            })
            .collect::<io::Result<Vec<_>>>()?;
        Ok(Session {
            buffers,
            active: self.active,
            next_scratch: self.next_scratch,
            handoff: None,
        })
    }
}

fn invalid_snapshot() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "invalid or unsupported recovery snapshot",
    )
}

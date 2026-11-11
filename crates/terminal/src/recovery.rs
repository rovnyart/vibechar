#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::{
    env,
    fs::{DirBuilder, File, OpenOptions, TryLockError},
    io,
    path::{Path, PathBuf},
    sync::mpsc::{self, Receiver, Sender, TryRecvError},
    thread::{self, JoinHandle},
};

use vibechar_core::{checkpoint::Checkpoint, session::Session};

type SaveResult = (u64, io::Result<()>);
type SaveRequest = (u64, Checkpoint);

pub struct Recovery {
    _lock: File,
    requests: Option<Sender<SaveRequest>>,
    results: Receiver<SaveResult>,
    worker: Option<JoinHandle<()>>,
    next_id: u64,
    pending: usize,
}

impl Recovery {
    pub fn open(directory: &Path) -> io::Result<(Self, Option<Session>)> {
        let mut builder = DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        builder.mode(0o700);
        builder.create(directory)?;
        #[cfg(unix)]
        if directory.metadata()?.permissions().mode() & 0o077 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "session directory must be private (0700)",
            ));
        }
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        options.mode(0o600);
        let lock = options.open(directory.join("session.lock"))?;
        lock.try_lock().map_err(|error| match error {
            TryLockError::WouldBlock => io::Error::new(
                io::ErrorKind::WouldBlock,
                "another terminal editor is already using this session",
            ),
            TryLockError::Error(error) => error,
        })?;
        let path = directory.join("session.json");
        let restored = Checkpoint::load(&path)?;
        let (requests, input) = mpsc::channel::<SaveRequest>();
        let (output, results) = mpsc::channel();
        let worker = thread::Builder::new()
            .name("vibechar-recovery".into())
            .spawn(move || {
                while let Ok((id, checkpoint)) = input.recv() {
                    if output.send((id, checkpoint.save(&path))).is_err() {
                        break;
                    }
                }
            })?;
        Ok((
            Self {
                _lock: lock,
                requests: Some(requests),
                results,
                worker: Some(worker),
                next_id: 0,
                pending: 0,
            },
            restored,
        ))
    }

    pub fn submit(&mut self, checkpoint: Checkpoint) -> io::Result<u64> {
        self.next_id += 1;
        self.requests
            .as_ref()
            .ok_or_else(worker_stopped)?
            .send((self.next_id, checkpoint))
            .map_err(|_| worker_stopped())?;
        self.pending += 1;
        Ok(self.next_id)
    }

    pub fn is_saving(&self) -> bool {
        self.pending > 0
    }

    pub fn poll(&mut self) -> io::Result<Option<SaveResult>> {
        match self.results.try_recv() {
            Ok(result) => {
                self.pending -= 1;
                Ok(Some(result))
            }
            Err(TryRecvError::Empty) => Ok(None),
            Err(TryRecvError::Disconnected) => Err(worker_stopped()),
        }
    }

    pub fn flush(&mut self, checkpoint: Checkpoint) -> io::Result<()> {
        let latest = self.submit(checkpoint)?;
        loop {
            let (id, result) = self.results.recv().map_err(|_| worker_stopped())?;
            self.pending -= 1;
            if id == latest {
                return result;
            }
        }
    }
}

impl Drop for Recovery {
    fn drop(&mut self) {
        self.requests.take();
        if let Some(worker) = self.worker.take() {
            if worker.join().is_err() {
                eprintln!("vibechar: recovery worker stopped unexpectedly");
            }
        }
    }
}

pub fn directory() -> io::Result<PathBuf> {
    if let Some(directory) = env::var_os("VIBECHAR_STATE_DIR").filter(|value| !value.is_empty()) {
        return std::path::absolute(directory);
    }
    let home = || {
        env::var_os("HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    "HOME is required to locate session storage",
                )
            })
    };
    if cfg!(target_os = "macos") {
        return Ok(home()?.join("Library/Application Support/dev.vibechar.terminal"));
    }
    let base = env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute());
    Ok(base
        .map_or_else(|| home().map(|path| path.join(".local/state")), Ok)?
        .join("vibechar/terminal"))
}

fn worker_stopped() -> io::Error {
    io::Error::new(io::ErrorKind::BrokenPipe, "session writer is unavailable")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        sync::atomic::{AtomicUsize, Ordering},
    };
    static SEQUENCE: AtomicUsize = AtomicUsize::new(0);

    struct TemporaryDirectory(PathBuf);
    impl TemporaryDirectory {
        fn new() -> Self {
            Self(env::temp_dir().join(format!(
                "vibechar-terminal-test-{}-{}",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            )))
        }
    }
    impl Drop for TemporaryDirectory {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }

    #[test]
    fn flush_fences_pending_saves_and_only_one_process_can_own_the_session() {
        let directory = TemporaryDirectory::new();
        let (mut recovery, restored) = Recovery::open(&directory.0).unwrap();
        assert!(restored.is_none());
        assert!(Recovery::open(&directory.0).is_err());
        let mut session = Session::new("first", None);
        recovery.submit(Checkpoint::capture(&session)).unwrap();
        session
            .active_mut()
            .document
            .replace(0..5, "latest")
            .unwrap();
        recovery.flush(Checkpoint::capture(&session)).unwrap();
        assert!(!recovery.is_saving());
        drop(recovery);
        let (_recovery, restored) = Recovery::open(&directory.0).unwrap();
        assert_eq!(restored.unwrap().active().document.text(), "latest");
    }

    #[test]
    fn corrupt_recovery_is_retained_instead_of_starting_an_empty_writable_session() {
        let directory = TemporaryDirectory::new();
        let (recovery, _) = Recovery::open(&directory.0).unwrap();
        drop(recovery);
        let path = directory.0.join("session.json");
        fs::write(&path, b"{broken").unwrap();
        assert!(Recovery::open(&directory.0).is_err());
        assert_eq!(fs::read(path).unwrap(), b"{broken");
    }

    #[test]
    fn failed_worker_write_is_reported_and_can_be_retried() {
        let directory = TemporaryDirectory::new();
        let (mut recovery, _) = Recovery::open(&directory.0).unwrap();
        let path = directory.0.join("session.json");
        fs::create_dir(&path).unwrap();
        let session = Session::new("keep", None);
        assert!(recovery.flush(Checkpoint::capture(&session)).is_err());
        fs::remove_dir(path).unwrap();
        recovery.flush(Checkpoint::capture(&session)).unwrap();
    }
}

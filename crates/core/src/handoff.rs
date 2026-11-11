//! Local, memory-only Secret Drop transport. No command execution in the editor.
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs::{self, File},
    io::{self, Read, Write},
    os::{
        fd::AsRawFd,
        unix::{
            fs::{DirBuilderExt, MetadataExt, PermissionsExt},
            net::{UnixListener, UnixStream},
        },
    },
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, Weak,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

pub const MAX_SECRET: usize = 64 * 1024;
const IDLE: Duration = Duration::from_secs(30 * 60);
const FRAME_LIMIT: usize = 512 * 1024;
const PREFIX: &str = "vibechar://grant/";

struct Grant {
    value: String,
    used: Instant,
    uses: u64,
}
struct Store {
    grants: HashMap<String, Grant>,
    idle: Duration,
}
impl Store {
    fn prune(&mut self) {
        self.grants
            .retain(|_, grant| grant.used.elapsed() < self.idle);
    }
}
type Shared = Arc<Mutex<Store>>;

pub(crate) struct GrantLink {
    reference: String,
    token: String,
    store: Weak<Mutex<Store>>,
}
impl GrantLink {
    pub fn reference(&self) -> &str {
        &self.reference
    }
    pub fn uses(&self) -> Option<u64> {
        let store = self.store.upgrade()?;
        let mut store = store.lock().ok()?;
        store.prune();
        store.grants.get(&self.token).map(|grant| grant.uses)
    }
}
impl Drop for GrantLink {
    fn drop(&mut self) {
        if let Some(store) = self.store.upgrade() {
            if let Ok(mut store) = store.lock() {
                store.grants.remove(&self.token);
            }
        }
    }
}

pub struct DropHost {
    store: Shared,
    path: PathBuf,
    instance: String,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}
impl DropHost {
    pub fn start() -> io::Result<Self> {
        Self::start_at(&directory(), IDLE)
    }
    pub fn start_at(directory: &Path, idle: Duration) -> io::Result<Self> {
        secure_directory(directory)?;
        let instance = random_hex(8)?;
        let path = directory.join(format!("{instance}.sock"));
        let listener = UnixListener::bind(&path)?;
        if let Err(error) = fs::set_permissions(&path, fs::Permissions::from_mode(0o600)) {
            let _ = fs::remove_file(&path);
            return Err(error);
        }
        let store = Arc::new(Mutex::new(Store {
            grants: HashMap::new(),
            idle,
        }));
        let stop = Arc::new(AtomicBool::new(false));
        let (state, stopping) = (store.clone(), stop.clone());
        let worker = thread::Builder::new()
            .name("vibechar-drop".into())
            .spawn(move || {
                for stream in listener.incoming() {
                    if stopping.load(Ordering::Acquire) {
                        break;
                    }
                    let Ok(mut stream) = stream else { break };
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(1)));
                    let _ = stream.set_write_timeout(Some(Duration::from_secs(1)));
                    if !same_user(&stream) {
                        continue;
                    }
                    let response = match read_frame::<Request>(&mut stream, 512) {
                        Ok(request) => {
                            let Ok(mut store) = state.lock() else { break };
                            store.prune();
                            if let Some(grant) = store.grants.get_mut(&request.token) {
                                grant.used = Instant::now();
                                grant.uses += 1;
                                Response {
                                    value: Some(grant.value.clone()),
                                    error: None,
                                }
                            } else {
                                Response::denied()
                            }
                        }
                        Err(_) => Response::denied(),
                    };
                    let _ = write_frame(&mut stream, &response);
                }
                if let Ok(mut store) = state.lock() {
                    store.grants.clear();
                }
            })
            .inspect_err(|_| {
                let _ = fs::remove_file(&path);
            })?;
        Ok(Self {
            store,
            path,
            instance,
            stop,
            worker: Some(worker),
        })
    }
    pub(crate) fn publish(&self, value: String) -> io::Result<GrantLink> {
        validate_secret(&value)?;
        let token = random_hex(32)?;
        let mut store = self.store.lock().map_err(|_| unavailable())?;
        store.prune();
        if store.grants.len() >= 64 {
            return Err(io::Error::other(
                "Close an existing Secret Drop before creating another.",
            ));
        }
        store.grants.insert(
            token.clone(),
            Grant {
                value,
                used: Instant::now(),
                uses: 0,
            },
        );
        Ok(GrantLink {
            reference: format!("{PREFIX}{}/{token}", self.instance),
            token,
            store: Arc::downgrade(&self.store),
        })
    }
    pub fn revoke_all(&self) {
        if let Ok(mut store) = self.store.lock() {
            store.grants.clear();
        }
    }
    pub fn has_access(&self) -> bool {
        self.store.lock().is_ok_and(|mut store| {
            store.prune();
            !store.grants.is_empty()
        })
    }
}
impl Drop for DropHost {
    fn drop(&mut self) {
        self.revoke_all();
        self.stop.store(true, Ordering::Release);
        let _ = UnixStream::connect(&self.path);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        let _ = fs::remove_file(&self.path);
    }
}

#[derive(Serialize, Deserialize)]
struct Request {
    token: String,
}
#[derive(Serialize, Deserialize)]
struct Response {
    value: Option<String>,
    error: Option<String>,
}
impl Response {
    fn denied() -> Self {
        Self {
            value: None,
            error: Some("Secret Drop is closed or expired. Ask for a new reference.".into()),
        }
    }
}

pub fn validate_secret(value: &str) -> io::Result<()> {
    if value.is_empty() || value.len() > MAX_SECRET || value.contains('\0') {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Use nonempty private text up to 64 KiB, without NUL characters.",
        ))
    } else {
        Ok(())
    }
}
pub fn directory() -> PathBuf {
    std::env::var_os("VIBECHAR_HANDOFF_DIR").map_or_else(
        || PathBuf::from(format!("/tmp/vibechar-drop-{}", unsafe { libc::geteuid() })),
        PathBuf::from,
    )
}
pub fn instruction(reference: &str, executable: &str) -> String {
    let executable = format!("'{}'", executable.replace('\'', "'\\''"));
    format!("Use this local Vibechar Secret Drop for the current task:\n{reference}\nRun commands with:\n{executable} run '{reference}' --env API_TOKEN -- <program> [args...]\nChoose the environment variable name the command needs. Read the value inside the child process; do not echo, log, or write it to a file. Literal stdout/stderr matches are masked. The editor must stay open; edits, Stop, closing the tab, or 30 minutes without use close access. This reference grants local access; keep it within this task.")
}
pub fn fetch(reference: &str) -> io::Result<String> {
    fetch_at(reference, &directory())
}
pub fn fetch_at(reference: &str, directory: &Path) -> io::Result<String> {
    let (instance, token) = parse_reference(reference)?;
    check_directory(directory)?;
    let path = directory.join(format!("{instance}.sock"));
    let metadata = fs::symlink_metadata(&path).map_err(|_| unavailable())?;
    use std::os::unix::fs::FileTypeExt;
    if !metadata.file_type().is_socket()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err(unavailable());
    }
    let mut stream = UnixStream::connect(path).map_err(|_| unavailable())?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    if !same_user(&stream) {
        return Err(unavailable());
    }
    write_frame(
        &mut stream,
        &Request {
            token: token.to_owned(),
        },
    )?;
    let response: Response = read_frame(&mut stream, FRAME_LIMIT)?;
    response.value.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Secret Drop is closed or expired. Ask for a new reference.",
        )
    })
}
fn parse_reference(reference: &str) -> io::Result<(&str, &str)> {
    let Some((instance, token)) = reference
        .strip_prefix(PREFIX)
        .and_then(|s| s.split_once('/'))
    else {
        return Err(invalid_reference());
    };
    if instance.len() != 16
        || token.len() != 64
        || !instance
            .bytes()
            .chain(token.bytes())
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
    {
        return Err(invalid_reference());
    }
    Ok((instance, token))
}
fn invalid_reference() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "Invalid Secret Drop reference.",
    )
}
fn unavailable() -> io::Error {
    io::Error::new(io::ErrorKind::NotConnected, "Secret Drop is unavailable. Keep the originating editor open and ask for a fresh reference.")
}
fn secure_directory(path: &Path) -> io::Result<()> {
    match fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => (),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => (),
        Err(error) => return Err(error),
    }
    check_directory(path)
}
fn check_directory(path: &Path) -> io::Result<()> {
    let meta = fs::symlink_metadata(path).map_err(|_| unavailable())?;
    if !meta.is_dir() || meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o077 != 0 {
        return Err(unavailable());
    }
    Ok(())
}
fn random_hex(bytes: usize) -> io::Result<String> {
    let mut value = vec![0; bytes];
    File::open("/dev/urandom")?.read_exact(&mut value)?;
    Ok(value.iter().map(|b| format!("{b:02x}")).collect())
}
fn write_frame(stream: &mut UnixStream, value: &impl Serialize) -> io::Result<()> {
    let bytes =
        serde_json::to_vec(value).map_err(|_| io::Error::other("Local bridge encoding failed."))?;
    stream.write_all(&(bytes.len() as u32).to_be_bytes())?;
    stream.write_all(&bytes)
}
fn read_frame<T: serde::de::DeserializeOwned>(
    stream: &mut UnixStream,
    limit: usize,
) -> io::Result<T> {
    let mut size = [0; 4];
    stream.read_exact(&mut size)?;
    let size = u32::from_be_bytes(size) as usize;
    if size > limit {
        return Err(io::Error::other("Local bridge frame is too large."));
    }
    let mut bytes = vec![0; size];
    stream.read_exact(&mut bytes)?;
    serde_json::from_slice(&bytes).map_err(|_| io::Error::other("Invalid local bridge frame."))
}
fn same_user(stream: &UnixStream) -> bool {
    #[cfg(target_os = "macos")]
    unsafe {
        let (mut uid, mut gid) = (0, 0);
        libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) == 0 && uid == libc::geteuid()
    }
    #[cfg(target_os = "linux")]
    unsafe {
        let mut cred: libc::ucred = std::mem::zeroed();
        let mut size = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut cred as *mut _ as *mut _,
            &mut size,
        ) == 0
            && cred.uid == libc::geteuid()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{checkpoint::Checkpoint, session::Session};
    use std::os::unix::fs::FileTypeExt;
    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            Self(PathBuf::from(format!(
                "/tmp/vc-drop-test-{}-{}",
                std::process::id(),
                random_hex(6).unwrap()
            )))
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn grants_are_reusable_scoped_memory_only_and_revoked_on_all_document_changes() {
        let temp = Temp::new();
        let mut session = Session::new("public", None);
        session.handoff = Some(DropHost::start_at(&temp.0, IDLE).unwrap());
        assert!(session.share_active().is_err());
        session.open_private();
        assert!(session.share_active().is_err());
        let fixture = "DROP_FIXTURE_👩‍💻";
        session
            .active_mut()
            .document
            .replace(0..0, fixture)
            .unwrap();
        let reference = session.share_active().unwrap();
        assert!(!session
            .drop_instruction("/tmp/path with 'quotes'/vibechar")
            .unwrap()
            .contains(fixture));
        assert_eq!(fetch_at(&reference, &temp.0).unwrap(), fixture);
        assert_eq!(fetch_at(&reference, &temp.0).unwrap(), fixture);
        assert_eq!(session.active().document.drop_uses(), Some(2));
        assert_eq!(session.share_active().unwrap(), reference);
        let mut wrong = reference.clone();
        let last = wrong.pop().unwrap();
        wrong.push(if last == '0' { '1' } else { '0' });
        assert!(fetch_at(&wrong, &temp.0).is_err());
        let snapshot = serde_json::to_string(&Checkpoint::capture(&session)).unwrap();
        assert!(!snapshot.contains(fixture) && !snapshot.contains(&reference));
        assert!(fs::read_dir(&temp.0).unwrap().all(|entry| entry
            .unwrap()
            .file_type()
            .unwrap()
            .is_socket()));
        session
            .active_mut()
            .document
            .replace(0..fixture.chars().count(), fixture)
            .unwrap();
        assert!(
            fetch_at(&reference, &temp.0).is_ok(),
            "A no-op must not revoke access"
        );
        session.active_mut().document.replace(0..0, "!").unwrap();
        assert!(fetch_at(&reference, &temp.0).is_err());
        let reference = session.share_active().unwrap();
        session.active_mut().document.undo();
        assert!(fetch_at(&reference, &temp.0).is_err());
        let reference = session.share_active().unwrap();
        session.active_mut().document.redo();
        assert!(fetch_at(&reference, &temp.0).is_err());
        let reference = session.share_active().unwrap();
        session.revoke_all_drops();
        assert!(fetch_at(&reference, &temp.0).is_err());
        assert_eq!(fs::read_dir(&temp.0).unwrap().count(), 0);
        session.handoff = Some(DropHost::start_at(&temp.0, IDLE).unwrap());
        let reference = session.share_active().unwrap();
        session.close_active(true);
        assert!(fetch_at(&reference, &temp.0).is_err());
        session.open_private();
        session
            .active_mut()
            .document
            .replace(0..0, fixture)
            .unwrap();
        let reference = session.share_active().unwrap();
        drop(session);
        assert!(fetch_at(&reference, &temp.0).is_err());
        assert_eq!(fs::read_dir(&temp.0).unwrap().count(), 0);
    }

    #[test]
    fn completing_save_ends_private_mode_and_revokes_only_that_tabs_access() {
        let temp = Temp::new();
        let mut session = Session::new("ordinary", None);
        session.handoff = Some(DropHost::start_at(&temp.0, IDLE).unwrap());
        session.open_private();
        session
            .active_mut()
            .document
            .replace(0..0, "STILL_PRIVATE")
            .unwrap();
        let other = session.share_active().unwrap();
        session.open_private();
        session
            .active_mut()
            .document
            .replace(0..0, "SAVED_👩‍💻")
            .unwrap();
        session.active_mut().selection = 0..5;
        let reference = session.share_active().unwrap();
        let revision = session.active().document.revision();
        session.complete_save(temp.0.join("saved.txt"));
        assert!(!session.active().is_private());
        assert!(!session.active().needs_close_confirmation());
        assert_eq!(session.active().label(), "saved.txt");
        assert_eq!(session.active().selection, 0..5);
        assert_eq!(session.active().document.revision(), revision);
        assert!(fetch_at(&reference, &temp.0).is_err());
        assert_eq!(fetch_at(&other, &temp.0).unwrap(), "STILL_PRIVATE");
        assert!(session.share_active().is_err());
        let snapshot = serde_json::to_string(&Checkpoint::capture(&session)).unwrap();
        assert!(snapshot.contains("SAVED_👩‍💻") && snapshot.contains("saved.txt"));
        assert!(!snapshot.contains("STILL_PRIVATE") && !snapshot.contains(&reference));
        let checkpoint = temp.0.join("session.json");
        Checkpoint::capture(&session).save(&checkpoint).unwrap();
        let restored = Checkpoint::load(&checkpoint).unwrap().unwrap();
        assert_eq!(restored.buffers().len(), 2);
        assert_eq!(restored.active().document.text(), "SAVED_👩‍💻");
        assert!(!restored.active().is_private());
        assert!(session.active_mut().document.undo().is_some());
        assert!(session.active().document.is_dirty());
        assert!(!session.active().is_private());
    }

    #[test]
    fn expiry_metadata_and_independent_instances_fail_closed() {
        let a = Temp::new();
        let b = Temp::new();
        let host = DropHost::start_at(&a.0, IDLE).unwrap();
        let other = DropHost::start_at(&b.0, Duration::ZERO).unwrap();
        let grant = host.publish("fixture".into()).unwrap();
        let expired = other.publish("other".into()).unwrap();
        assert!(fetch_at(expired.reference(), &b.0).is_err());
        assert!(fetch_at(grant.reference(), &b.0).is_err());
        let before = host.store.lock().unwrap().grants[&grant.token].used;
        assert_eq!(grant.uses(), Some(0));
        assert_eq!(host.store.lock().unwrap().grants[&grant.token].used, before);
        assert!(fetch_at("vibechar://grant/../../secret", &a.0).is_err());
        assert!(host.publish("".into()).is_err());
        assert!(host.publish("no\0nul".into()).is_err());
        assert!(host.publish("x".repeat(MAX_SECRET + 1)).is_err());
        assert_eq!(
            fs::metadata(&host.path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        drop(grant);
        assert!(!host.has_access());
    }

    #[test]
    fn unsafe_directory_and_oversized_requests_are_rejected_without_disclosure() {
        let temp = Temp::new();
        fs::DirBuilder::new().mode(0o755).create(&temp.0).unwrap();
        assert!(DropHost::start_at(&temp.0, IDLE).is_err());
        fs::set_permissions(&temp.0, fs::Permissions::from_mode(0o700)).unwrap();
        let host = DropHost::start_at(&temp.0, IDLE).unwrap();
        let grant = host.publish("WIRE_FIXTURE".into()).unwrap();
        let mut stream = UnixStream::connect(&host.path).unwrap();
        stream.write_all(&10000u32.to_be_bytes()).unwrap();
        let response: Response = read_frame(&mut stream, FRAME_LIMIT).unwrap();
        assert!(response.value.is_none());
        assert_eq!(
            fetch_at(grant.reference(), &temp.0).unwrap(),
            "WIRE_FIXTURE"
        );
    }
}

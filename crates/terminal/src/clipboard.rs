use std::{
    io::{self, Read, Write},
    process::{Command, Stdio},
};
use vibechar_core::handoff::MAX_SECRET;

fn program(read: bool) -> Command {
    if let Some(program) = std::env::var_os(if read {
        "VIBECHAR_PASTE_COMMAND"
    } else {
        "VIBECHAR_COPY_COMMAND"
    }) {
        return Command::new(program);
    }
    if cfg!(target_os = "macos") {
        Command::new(if read {
            "/usr/bin/pbpaste"
        } else {
            "/usr/bin/pbcopy"
        })
    } else if std::env::var_os("WAYLAND_DISPLAY").is_some() {
        let mut cmd = Command::new(if read { "wl-paste" } else { "wl-copy" });
        if read {
            cmd.args(["--no-newline", "--type", "text"]);
        }
        cmd
    } else {
        let mut cmd = Command::new("xclip");
        cmd.args(["-selection", "clipboard"]);
        if read {
            cmd.arg("-o");
        }
        cmd
    }
}
fn unavailable() -> io::Error {
    io::Error::other(
        "Clipboard unavailable. Use a local clipboard (pbcopy/pbpaste, wl-copy/wl-paste or xclip).",
    )
}
pub fn read() -> io::Result<String> {
    let mut child = program(true)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| unavailable())?;
    let mut bytes = Vec::new();
    let result = child
        .stdout
        .take()
        .unwrap()
        .take((MAX_SECRET + 1) as u64)
        .read_to_end(&mut bytes);
    // A too-large producer may still be writing: close the pipe and stop it.
    if result.is_err() || bytes.len() > MAX_SECRET {
        let _ = child.kill();
    }
    let status = child.wait()?;
    result?;
    if !status.success() || bytes.len() > MAX_SECRET {
        return Err(unavailable());
    }
    String::from_utf8(bytes).map_err(|_| unavailable())
}
pub fn copy(text: &str) -> io::Result<()> {
    let mut child = program(false)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| unavailable())?;
    let result = child.stdin.take().unwrap().write_all(text.as_bytes());
    if result.is_err() {
        let _ = child.kill();
    }
    let status = child.wait()?;
    result?;
    if status.success() {
        Ok(())
    } else {
        Err(unavailable())
    }
}

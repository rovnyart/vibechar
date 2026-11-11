use std::{
    ffi::OsString,
    io::{self, Read, Write},
    os::unix::process::ExitStatusExt,
    process::{Command, Stdio},
    thread,
};

pub fn run(arguments: &[OsString]) -> io::Result<i32> {
    if arguments.len() < 5 || arguments[1] != "--env" || arguments[3] != "--" {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Usage: vibechar run <reference> --env NAME -- <program> [args...]",
        ));
    }
    let reference = arguments[0]
        .to_str()
        .ok_or_else(|| io::Error::other("Invalid Secret Drop reference."))?;
    let name = arguments[2]
        .to_str()
        .filter(|name| {
            !name.is_empty()
                && name.bytes().enumerate().all(|(i, c)| {
                    c == b'_' || c.is_ascii_alphabetic() || (i > 0 && c.is_ascii_digit())
                })
        })
        .ok_or_else(|| io::Error::other("Use a valid environment variable name."))?;
    let value = vibechar_core::handoff::fetch(reference)?;
    vibechar_core::handoff::validate_secret(&value)?;
    let mut child = Command::new(&arguments[4])
        .args(&arguments[5..])
        .env(name, &value)
        .stdin(Stdio::inherit())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|_| io::Error::other("Could not start the requested program."))?;
    let (stdout, stderr) = (child.stdout.take().unwrap(), child.stderr.take().unwrap());
    let pattern = value.into_bytes();
    let err_pattern = pattern.clone();
    let out = thread::spawn(move || mask(stdout, io::stdout().lock(), &pattern));
    let err = thread::spawn(move || mask(stderr, io::stderr().lock(), &err_pattern));
    let status = child.wait()?;
    out.join()
        .map_err(|_| io::Error::other("Output masking failed."))??;
    err.join()
        .map_err(|_| io::Error::other("Output masking failed."))??;
    Ok(status
        .code()
        .unwrap_or_else(|| 128 + status.signal().unwrap_or(1)))
}

// KMP keeps at most one potential match between reads, including binary output.
fn mask(mut input: impl Read, mut output: impl Write, secret: &[u8]) -> io::Result<()> {
    if secret.is_empty() {
        return Err(io::Error::other("Empty mask pattern."));
    }
    let mut prefix = vec![0; secret.len()];
    let mut matched = 0;
    for i in 1..secret.len() {
        while matched > 0 && secret[i] != secret[matched] {
            matched = prefix[matched - 1];
        }
        if secret[i] == secret[matched] {
            matched += 1;
        }
        prefix[i] = matched;
    }
    matched = 0;
    let mut buffer = [0; 8192];
    let mut ready = Vec::with_capacity(8192 + secret.len());
    loop {
        let length = input.read(&mut buffer)?;
        if length == 0 {
            break;
        }
        ready.clear();
        for &byte in &buffer[..length] {
            while matched > 0 && byte != secret[matched] {
                let next = prefix[matched - 1];
                ready.extend_from_slice(&secret[..matched - next]);
                matched = next;
            }
            if byte == secret[matched] {
                matched += 1;
                if matched == secret.len() {
                    ready.extend_from_slice(b"[REDACTED]");
                    matched = 0;
                }
            } else {
                ready.push(byte);
            }
        }
        output.write_all(&ready)?;
        output.flush()?;
    }
    output.write_all(&secret[..matched])?;
    output.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Chunks<'a>(&'a [u8], usize);
    impl Read for Chunks<'_> {
        fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
            let count = self.0.len().min(self.1).min(output.len());
            output[..count].copy_from_slice(&self.0[..count]);
            self.0 = &self.0[count..];
            Ok(count)
        }
    }
    #[test]
    fn masking_handles_chunk_boundaries_repeated_prefixes_and_unicode() {
        for secret in ["a", "aba", "aaaaab", "👩‍💻token"] {
            let input = format!("start {secret}{secret} abaaaaaab ending {secret}");
            for chunk in [1, 2, 7, 8192] {
                let mut output = Vec::new();
                mask(
                    Chunks(input.as_bytes(), chunk),
                    &mut output,
                    secret.as_bytes(),
                )
                .unwrap();
                assert_eq!(
                    String::from_utf8(output).unwrap(),
                    input.replace(secret, "[REDACTED]")
                );
            }
        }
    }
}

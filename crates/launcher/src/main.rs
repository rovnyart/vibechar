mod install;

use std::os::unix::process::CommandExt;
use std::{
    env,
    ffi::OsString,
    path::{Path, PathBuf},
    process::Command,
};

fn main() {
    if let Err(error) = run() {
        eprintln!("vc: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    let executable = env::current_exe()?.canonicalize()?;
    let directory = executable.parent().ok_or("Can't locate Vibechar.")?;
    if args.first().is_some_and(|arg| arg == "--install") {
        if args.len() != 1 {
            return Err("Use vc --install without extra arguments.".into());
        }
        let home = PathBuf::from(env::var_os("HOME").ok_or("HOME is unavailable.")?);
        let shell = env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into());
        let path = install::install(&executable, &home, &shell)?;
        println!("Installed {}\nOpen a new terminal, then use:\n  vc foo.txt\n  vc -t foo.txt\n  vc --terminal foo.txt", path.display());
        return Ok(());
    }
    if args
        .first()
        .is_some_and(|arg| arg == "--help" || arg == "-h")
    {
        println!("vc [FILE...]                  Open the Mac editor (terminal on Linux)\nvc -t, --terminal [FILE]       Edit in this terminal\nvc --install                  Install in ~/.local/bin and configure PATH\nvc run <reference> --env NAME -- <program> [args...]\nvc --version\n\nUse -- before a filename beginning with '-'. New files open without creating them until Save.");
        return Ok(());
    }
    if args.first().is_some_and(|arg| arg == "--version") {
        println!("vc {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    let helper = directory.join("vibechar");
    if args
        .first()
        .is_some_and(|arg| arg == "-t" || arg == "--terminal")
        && args
            .get(1)
            .is_some_and(|arg| arg == "--help" || arg == "-h" || arg == "--version")
    {
        return Err(Command::new(helper).args(&args[1..]).exec().into());
    }
    if args.first().is_some_and(|arg| arg == "run") {
        return Err(Command::new(helper).args(args).exec().into());
    }
    let (terminal, files) = parse(args)?;
    if terminal || !cfg!(target_os = "macos") {
        let paths = files
            .iter()
            .map(std::path::absolute)
            .collect::<Result<Vec<_>, _>>()?;
        return Err(Command::new(helper).args(paths).exec().into());
    }
    let app = directory
        .ancestors()
        .find(|path| path.extension().is_some_and(|e| e == "app"))
        .ok_or("The Mac app is missing. Reinstall Vibechar, or use vc --terminal.")?;
    let mut command = Command::new("/usr/bin/open");
    command.arg("-a").arg(app);
    for file in files {
        command.arg(open_url(&std::path::absolute(file)?)?);
    }
    if !command.status()?.success() {
        return Err("Couldn't open the Mac app.".into());
    }
    Ok(())
}

fn parse(args: Vec<OsString>) -> Result<(bool, Vec<OsString>), &'static str> {
    let mut terminal = false;
    let mut literal = false;
    let mut files = Vec::new();
    for arg in args {
        if !literal && arg == "--" {
            literal = true;
        } else if !literal && (arg == "-t" || arg == "--terminal") {
            terminal = true;
        } else if !literal && arg.to_string_lossy().starts_with('-') {
            return Err("Unknown option. Use vc --help, or -- before a filename.");
        } else {
            files.push(arg);
        }
    }
    Ok((terminal, files))
}

fn open_url(path: &Path) -> Result<String, &'static str> {
    let text = path.to_str().ok_or("Mac filenames must be valid UTF-8.")?;
    let mut url = String::from("vibechar://open?path=");
    use std::fmt::Write;
    for byte in text.bytes() {
        write!(&mut url, "%{byte:02X}").unwrap();
    }
    Ok(url)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn routes_terminal_flags_and_literal_option_names() {
        assert_eq!(
            parse(vec!["-t".into(), "a b.txt".into()]).unwrap(),
            (true, vec![OsString::from("a b.txt")])
        );
        assert_eq!(
            parse(vec!["--terminal".into(), "--".into(), "-t".into()]).unwrap(),
            (true, vec![OsString::from("-t")])
        );
        assert!(parse(vec!["--unknown".into()]).is_err());
        let uri = open_url(Path::new("/tmp/я 🦀&?#\n.txt")).unwrap();
        assert!(!uri.contains('&') && !uri.contains('#') && !uri.contains('\n'));
        assert!(uri.starts_with("vibechar://open?path=%2F%74%6D%70%2F"));
        assert!(uri.contains("%D1%8F") && uri.contains("%26%3F%23%0A"));
    }
}

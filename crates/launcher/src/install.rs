use std::os::unix::fs::symlink;
use std::{
    fs, io,
    path::{Path, PathBuf},
};

const BLOCK: &str = "\n# Vibechar command\ncase \":$PATH:\" in\n  *\":$HOME/.local/bin:\"*) ;;\n  *) export PATH=\"$HOME/.local/bin:$PATH\" ;;\nesac\n";

pub fn install(executable: &Path, home: &Path, shell: &str) -> io::Result<PathBuf> {
    if !home.is_absolute() || !executable.is_absolute() {
        return Err(io::Error::other("Installation paths must be absolute."));
    }
    let bin = home.join(".local/bin");
    fs::create_dir_all(&bin)?;
    let target = bin.join("vc");
    match fs::symlink_metadata(&target) {
        Ok(meta) if meta.file_type().is_symlink() => {
            let previous = fs::read_link(&target)?;
            // Never replace a command owned by another application.
            if previous != executable
                && !previous
                    .components()
                    .any(|c| c.as_os_str() == "Vibechar.app" || c.as_os_str() == "vibechar")
            {
                return Err(io::Error::other("~/.local/bin/vc already belongs to another application. It was left untouched."));
            }
        }
        Ok(_) => {
            return Err(io::Error::other(
                "~/.local/bin/vc already exists. It was left untouched.",
            ))
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    // Prepare and validate shell files before changing the link.
    let shell_name = Path::new(shell)
        .file_name()
        .unwrap_or_default()
        .to_string_lossy();
    let files = match shell_name.as_ref() {
        "zsh" => vec![home.join(".zprofile"), home.join(".zshrc")],
        "bash" => vec![
            home.join(if home.join(".bash_profile").exists() {
                ".bash_profile"
            } else {
                ".profile"
            }),
            home.join(".bashrc"),
        ],
        "fish" => vec![home.join(".config/fish/conf.d/vibechar.fish")],
        _ => vec![home.join(".profile")],
    };
    let mut updates = Vec::new();
    for path in files {
        let existing = match fs::read_to_string(&path) {
            Ok(text) => text,
            Err(e) if e.kind() == io::ErrorKind::NotFound => String::new(),
            Err(e) => return Err(e),
        };
        if existing.contains("# Vibechar command") {
            continue;
        }
        let addition = if shell_name == "fish" {
            "\n# Vibechar command\nfish_add_path --move --path $HOME/.local/bin\n"
        } else {
            BLOCK
        };
        updates.push((path, addition));
    }
    for (path, text) in updates {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        // Append only: preserve existing bytes, permissions and symlink destinations.
        use std::io::Write;
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)?;
        file.write_all(text.as_bytes())?;
    }
    let staged = bin.join(format!(".vc-install-{}", std::process::id()));
    symlink(executable, &staged)?;
    if let Err(error) = fs::rename(&staged, &target) {
        let _ = fs::remove_file(&staged);
        return Err(error);
    }
    Ok(target)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn user_install_is_idempotent_preserves_shell_text_and_refuses_other_commands() {
        let root = std::env::temp_dir().join(format!("vibechar-path-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let source = root.join("Vibechar.app/Contents/Helpers/vc");
        fs::create_dir_all(source.parent().unwrap()).unwrap();
        fs::write(&source, "fixture").unwrap();
        fs::write(root.join(".zshrc"), "export KEEP_ME=yes\n").unwrap();
        let link = install(&source, &root, "/bin/zsh").unwrap();
        install(&source, &root, "/bin/zsh").unwrap();
        assert_eq!(fs::read_link(&link).unwrap(), source);
        let shell = fs::read_to_string(root.join(".zshrc")).unwrap();
        assert!(shell.starts_with("export KEEP_ME=yes\n"));
        assert_eq!(shell.matches("# Vibechar command").count(), 1);
        fs::remove_file(&link).unwrap();
        fs::write(&link, "unrelated").unwrap();
        assert!(install(&source, &root, "/bin/zsh").is_err());
        assert_eq!(fs::read_to_string(link).unwrap(), "unrelated");
        fs::remove_dir_all(root).unwrap();
    }
}

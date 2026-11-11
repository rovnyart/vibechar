use std::{
    fs::{self, OpenOptions},
    io::{self, BufWriter, Write},
    path::Path,
};
use vibechar_core::Document;

pub fn load(path: &Path) -> io::Result<String> {
    match fs::read_to_string(path) {
        Ok(text) => Ok(text),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(String::new()),
        Err(error) => Err(error),
    }
}

pub fn save(path: &Path, document: &Document) -> io::Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => Some(metadata),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(error),
    };
    if metadata
        .as_ref()
        .is_some_and(|meta| meta.file_type().is_symlink() || meta.permissions().readonly())
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "refusing to replace a symlink or read-only file",
        ));
    }
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing filename"))?;
    let temporary = path.with_file_name(format!(
        ".{}.vibechar-{}.tmp",
        name.to_string_lossy(),
        std::process::id()
    ));
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    let result = (|| {
        if let Some(meta) = metadata {
            file.set_permissions(meta.permissions())?;
        }
        let mut writer = BufWriter::new(&file);
        document.write_to(&mut writer)?;
        writer.flush()?;
        file.sync_all()?;
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        fs::remove_file(&temporary)?;
    }
    result
}

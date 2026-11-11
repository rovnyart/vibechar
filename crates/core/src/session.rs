use std::{ops::Range, path::PathBuf};

use crate::Document;

pub struct Buffer {
    pub document: Document,
    pub path: Option<PathBuf>,
    pub selection: Range<usize>,
    pub(crate) scratch_number: usize,
}

impl Buffer {
    pub fn label(&self) -> String {
        self.path
            .as_ref()
            .and_then(|path| path.file_name())
            .map_or_else(
                || format!("Scratch {}", self.scratch_number),
                |name| name.to_string_lossy().into_owned(),
            )
    }
}

/// One in-memory editing session. At least one buffer always remains open.
pub struct Session {
    pub(crate) buffers: Vec<Buffer>,
    pub(crate) active: usize,
    pub(crate) next_scratch: usize,
}

impl Session {
    pub fn new(text: &str, path: Option<PathBuf>) -> Self {
        let mut session = Self {
            buffers: Vec::new(),
            active: 0,
            next_scratch: 1,
        };
        session.open(text, path);
        session
    }

    pub fn buffers(&self) -> &[Buffer] {
        &self.buffers
    }
    pub fn active_index(&self) -> usize {
        self.active
    }
    pub fn active(&self) -> &Buffer {
        &self.buffers[self.active]
    }
    pub fn active_mut(&mut self) -> &mut Buffer {
        &mut self.buffers[self.active]
    }
    pub fn has_unsaved(&self) -> bool {
        self.buffers.iter().any(|buffer| buffer.document.is_dirty())
    }

    pub fn select(&mut self, index: usize) -> bool {
        if index >= self.buffers.len() {
            return false;
        }
        self.active = index;
        true
    }

    pub fn open(&mut self, text: &str, path: Option<PathBuf>) {
        let document = if path.is_none() && !text.is_empty() {
            let mut document = Document::new("");
            document
                .replace(0..0, text)
                .expect("empty insertion is a valid range");
            document
        } else {
            Document::new(text)
        };
        let scratch_number = self.next_scratch;
        if path.is_none() {
            self.next_scratch += 1;
        }
        self.buffers.push(Buffer {
            document,
            path,
            selection: 0..0,
            scratch_number,
        });
        self.active = self.buffers.len() - 1;
    }

    /// Refuse to discard an edited buffer unless the caller has confirmed it.
    pub fn close_active(&mut self, discard: bool) -> bool {
        if self.active().document.is_dirty() && !discard {
            return false;
        }
        self.buffers.remove(self.active);
        if self.buffers.is_empty() {
            self.open("", None);
        } else {
            self.active = self.active.min(self.buffers.len() - 1);
        }
        true
    }
}

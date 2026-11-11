use std::{ops::Range, path::PathBuf};

use crate::Document;
use unicode_segmentation::UnicodeSegmentation;

pub struct Buffer {
    pub document: Document,
    pub path: Option<PathBuf>,
    pub selection: Range<usize>,
    pub(crate) scratch_number: usize,
    pub(crate) private: bool,
}

impl Buffer {
    pub fn label(&self) -> String {
        if self.private {
            return format!("Private {}", self.scratch_number);
        }
        self.path
            .as_ref()
            .and_then(|path| path.file_name())
            .map_or_else(
                || {
                    // Never scan/copy a large scratch just to draw its tab.
                    let prefix: String =
                        self.document.checkpoint_text().chars().take(256).collect();
                    let first_line = prefix.lines().map(str::trim).find(|line| {
                        line.chars()
                            .any(|c| !c.is_whitespace() && !"{}[],;:".contains(c))
                    });
                    first_line.map_or_else(
                        || format!("Scratch {}", self.scratch_number),
                        |line| {
                            let clean: String = line.chars().filter(|c| !c.is_control()).collect();
                            let mut title: String = clean.graphemes(true).take(32).collect();
                            if clean.graphemes(true).count() > 32 {
                                title.push('…');
                            }
                            if title.is_empty() {
                                format!("Scratch {}", self.scratch_number)
                            } else {
                                title
                            }
                        },
                    )
                },
                |name| name.to_string_lossy().into_owned(),
            )
    }

    pub fn is_private(&self) -> bool {
        self.private
    }

    pub fn needs_close_confirmation(&self) -> bool {
        self.document.is_dirty() || (self.private && self.document.len_chars() > 0)
    }
}

/// One in-memory editing session. At least one buffer always remains open.
pub struct Session {
    pub(crate) buffers: Vec<Buffer>,
    pub(crate) active: usize,
    pub(crate) next_scratch: usize,
    pub(crate) handoff: Option<crate::handoff::DropHost>,
}

impl Session {
    pub fn new(text: &str, path: Option<PathBuf>) -> Self {
        let mut session = Self {
            buffers: Vec::new(),
            active: 0,
            next_scratch: 1,
            handoff: None,
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

    pub fn has_private_text(&self) -> bool {
        self.buffers
            .iter()
            .any(|buffer| buffer.private && buffer.document.len_chars() > 0)
    }

    pub fn share_active(&mut self) -> std::io::Result<String> {
        if !self.active().is_private() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Use a private tab or Paste Secret for Agent.",
            ));
        }
        if self.active().document.drop_uses().is_some() {
            return Ok(self.active().document.drop_reference().unwrap().to_owned());
        }
        let value = self.active().document.text();
        crate::handoff::validate_secret(&value)?;
        if self.handoff.is_none() {
            self.handoff = Some(crate::handoff::DropHost::start()?);
        }
        let grant = self.handoff.as_ref().unwrap().publish(value)?;
        let reference = grant.reference().to_owned();
        self.active_mut().document.publish_drop(grant);
        Ok(reference)
    }
    pub fn has_drop_access(&self) -> bool {
        self.handoff.as_ref().is_some_and(|host| host.has_access())
    }
    pub fn revoke_all_drops(&mut self) {
        // Stopping all access also releases the idle broker and its socket.
        self.handoff = None;
    }
    pub fn drop_instruction(&self, executable: &str) -> Option<String> {
        self.active()
            .document
            .drop_reference()
            .map(|reference| crate::handoff::instruction(reference, executable))
    }

    /// Privacy is chosen before any text is inserted. Existing scratches cannot
    /// be converted: an earlier checkpoint may already contain their text.
    pub fn open_private(&mut self) {
        self.open("", None);
        self.active_mut().private = true;
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
            private: false,
        });
        self.active = self.buffers.len() - 1;
    }

    /// Refuse to discard an edited buffer unless the caller has confirmed it.
    pub fn close_active(&mut self, discard: bool) -> bool {
        if self.active().needs_close_confirmation() && !discard {
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

#[cfg(test)]
mod label_tests {
    use super::*;

    #[test]
    fn scratch_labels_are_bounded_unicode_previews_and_files_keep_their_names() {
        let mut session = Session::new("", None);
        assert_eq!(session.active().label(), "Scratch 1");
        session.open("\r\n  Привет 👩‍💻  \r\nsecond line", None);
        assert_eq!(session.active().label(), "Привет 👩‍💻");
        session.active_mut().document.replace(0..0, "{\n").unwrap();
        assert_eq!(session.active().label(), "Привет 👩‍💻");
        session.open(&"👩‍💻".repeat(40), None);
        assert_eq!(session.active().label(), format!("{}…", "👩‍💻".repeat(32)));
        session.open(&format!("{}hidden title", "\n".repeat(256)), None);
        assert_eq!(session.active().label(), "Scratch 4");
        session.open("different content", Some(PathBuf::from("/tmp/actual.json")));
        assert_eq!(session.active().label(), "actual.json");
    }
}

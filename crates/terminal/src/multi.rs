use super::*;

impl Editor {
    pub(super) fn sync_multi(&mut self) {
        if let Some(primary) = self.multi.primary() {
            self.cursor = primary.head;
            self.anchor = (primary.anchor != primary.head).then_some(primary.anchor);
            self.reveal_cursor = true;
        }
        self.message = self.multi.message.clone().unwrap_or_default();
        self.pointer = selection::Pointer::default();
    }
    pub fn pump_multi(&mut self) -> bool {
        let before = self.selection_state();
        if self.multi.pump(&mut self.session.active_mut().document) {
            self.sync_multi();
        }
        self.selection_state() != before
    }
    pub(super) fn multi_edit(&mut self, text: &str, kind: EditKind) {
        match self
            .multi
            .edit(&mut self.session.active_mut().document, text, kind)
        {
            Ok(_) => self.sync_multi(),
            Err(error) => self.message = error,
        }
    }
    pub(super) fn handle_multi_key(&mut self, key: KeyEvent) -> bool {
        self.pump_multi();
        let control = key.modifiers.contains(KeyModifiers::CONTROL);
        if control && matches!(key.code, KeyCode::Char('d' | 'l')) {
            if key.code == KeyCode::Char('l') && self.find.is_some() {
                self.select_find_matches();
                return true;
            }
            self.find = None;
            let range = self.selection();
            if let Err(error) = self.multi.request(
                &self.session.active().document,
                range,
                key.code == KeyCode::Char('l'),
            ) {
                self.message = error;
            } else {
                self.sync_multi();
            }
            return true;
        }
        if !self.multi.active(self.document()) {
            return false;
        }
        if key.code == KeyCode::Esc && self.multi.has_queued_input() {
            self.message = "Finishing matching · Esc again when ready".into();
            return true;
        }
        if key.code == KeyCode::Esc {
            self.multi.clear();
            self.message.clear();
            return true;
        }
        if key
            .modifiers
            .intersects(KeyModifiers::ALT | KeyModifiers::SUPER)
        {
            return false;
        }
        let direction = match key.code {
            KeyCode::Left if !control => Some(0),
            KeyCode::Right if !control => Some(1),
            KeyCode::Up if !control => Some(2),
            KeyCode::Down if !control => Some(3),
            KeyCode::Home => Some(if control { 6 } else { 4 }),
            KeyCode::End => Some(if control { 7 } else { 5 }),
            _ => None,
        };
        if let Some(direction) = direction {
            match self.multi.navigate(
                &self.session.active().document,
                direction,
                key.modifiers.contains(KeyModifiers::SHIFT),
            ) {
                Ok(()) => self.sync_multi(),
                Err(error) => self.message = error,
            }
            return true;
        }
        let kind = match key.code {
            KeyCode::Backspace if !control => Some(EditKind::Backspace),
            KeyCode::Delete if !control && !key.modifiers.contains(KeyModifiers::SHIFT) => {
                Some(EditKind::DeleteForward)
            }
            _ => None,
        };
        if let Some(kind) = kind {
            self.multi_edit("", kind);
            return true;
        }
        false
    }
}

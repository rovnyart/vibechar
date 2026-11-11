use ratatui::{
    layout::{Constraint, Layout},
    style::{Color, Style},
    text::{Line, Span},
    widgets::Paragraph,
    Frame,
};
use unicode_segmentation::UnicodeSegmentation;

use crate::editor::{cell_width, Editor};

pub fn draw(frame: &mut Frame, editor: &mut Editor) {
    let [header, body, status, footer] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(1),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .areas(frame.area());
    let line = editor.document().line_index(editor.cursor);
    let column = editor.cursor_column();
    editor.top = editor.top.min(line);
    if line >= editor.top + usize::from(body.height) {
        editor.top = line + 1 - usize::from(body.height);
    }
    editor.left = editor.left.min(column);
    if column >= editor.left + usize::from(body.width) {
        editor.left = column + 1 - usize::from(body.width);
    }

    let name = format!(
        "{}/{}  {}",
        editor.session.active_index() + 1,
        editor.session.buffers().len(),
        editor.session.active().label()
    );
    let dirty = if editor.document().is_dirty() {
        " ●"
    } else {
        ""
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                " vibechar ",
                Style::default()
                    .fg(Color::Black)
                    .bg(Color::Rgb(245, 158, 66)),
            ),
            Span::raw(format!("  {name}{dirty}")),
        ])),
        header,
    );

    let lines: Vec<_> = (editor.top
        ..(editor.top + usize::from(body.height)).min(editor.document().line_count()))
        .map(|index| {
            Line::raw(visible_line(
                &editor.document().line(index),
                editor.left,
                usize::from(body.width),
            ))
        })
        .collect();
    frame.render_widget(Paragraph::new(lines), body);
    let recovery = if editor.session.active().is_private() {
        if let Some(uses) = editor.document().drop_uses() {
            format!("PRIVATE · Agent access open · {uses} uses · F9 stop")
        } else {
            format!(
                "PRIVATE · not recovered · Other tabs: {}",
                editor.recovery_status
            )
        }
    } else {
        editor.recovery_status.to_owned()
    };
    frame.render_widget(
        Paragraph::new(format!(
            " {}  · {}:{}  UTF-8",
            recovery,
            line + 1,
            column + 1
        ))
        .style(Style::default().fg(Color::DarkGray)),
        status,
    );
    let prompt = editor.save_prompt.as_ref().map_or_else(
        || {
            if editor.message.is_empty() {
                " ^N new  ^P private  ^G give  F8 paste+give  F9 stop  F6 next  ^S save  ^Q quit"
                    .into()
            } else {
                format!(" {}", editor.message)
            }
        },
        |value| {
            if editor.session.active().is_private() {
                format!(" Save as (ends private mode): {value}  [Enter save · Esc cancel]")
            } else {
                format!(" Save as: {value}  [Enter save · Esc cancel]")
            }
        },
    );
    frame.render_widget(
        Paragraph::new(prompt).style(Style::default().fg(Color::Rgb(245, 158, 66))),
        footer,
    );
    if editor.save_prompt.is_none() && body.width > 0 && body.height > 0 {
        frame.set_cursor_position((
            body.x + (column - editor.left) as u16,
            body.y + (line - editor.top) as u16,
        ));
    }
}

fn visible_line(text: &str, left: usize, width: usize) -> String {
    let mut output = String::new();
    let mut column = 0;
    for grapheme in text.graphemes(true) {
        let size = cell_width(grapheme, column);
        let end = column + size;
        if column >= left + width {
            break;
        }
        if end > left {
            if grapheme == "\t" || column < left || end > left + width {
                let visible = end.min(left + width).saturating_sub(column.max(left));
                output.push_str(&" ".repeat(visible));
            } else if grapheme.chars().any(char::is_control) {
                output.push('�');
            } else {
                output.push_str(grapheme);
            }
        }
        column = end;
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::{backend::TestBackend, Terminal};

    #[test]
    fn renders_a_unicode_document_and_keeps_cursor_visible_after_resize() {
        let mut editor = Editor::new("я\n界界界界界界界界", None);
        editor.cursor = editor.document().len_chars();
        let mut terminal = Terminal::new(TestBackend::new(16, 5)).unwrap();
        terminal.draw(|frame| draw(frame, &mut editor)).unwrap();
        assert!(editor.left > 0);
        assert!(terminal
            .backend()
            .buffer()
            .content
            .iter()
            .any(|cell| cell.symbol() == "界"));
    }

    #[test]
    fn clipping_a_wide_grapheme_never_draws_half_a_character() {
        assert_eq!(visible_line("a界b", 2, 2), " b");
        assert_eq!(visible_line("\tx", 1, 4), "   x");
    }

    #[test]
    fn private_mode_is_visible_without_using_text_as_a_tab_title() {
        let mut editor = Editor::new("", None);
        editor.session.open_private();
        editor.insert("PRIVATE_VIEW_FIXTURE");
        editor.recovery_status = "Saved locally";
        let mut terminal = Terminal::new(TestBackend::new(100, 5)).unwrap();
        terminal.draw(|frame| draw(frame, &mut editor)).unwrap();
        let row = |y| {
            (0..100)
                .map(|x| terminal.backend().buffer()[(x, y)].symbol())
                .collect::<String>()
        };
        assert!(row(0).contains("Private"));
        assert!(!row(0).contains("PRIVATE_VIEW_FIXTURE"));
        assert!(row(3).contains("PRIVATE · not recovered · Other tabs: Saved locally"));
    }
}

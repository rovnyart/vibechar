mod editor;
mod files;
mod recovery;
mod view;

use std::{
    env,
    error::Error,
    io::{self, IsTerminal, Read},
    time::{Duration, Instant},
};

use crossterm::{
    event::{
        self, DisableBracketedPaste, EnableBracketedPaste, Event, KeyCode, KeyEventKind,
        KeyModifiers,
    },
    execute,
};

use editor::Editor;
use recovery::Recovery;
use vibechar_core::checkpoint::Checkpoint;

fn main() {
    if let Err(error) = run() {
        eprintln!("vibechar: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args
        .first()
        .is_some_and(|arg| arg == "--help" || arg == "-h")
    {
        println!("vibechar [FILE]\n\nA tiny text workbench. Also accepts piped UTF-8 text.\n\nCtrl+N new · Ctrl+P new private · F6/Shift+F6 switch · Ctrl+W close\nCtrl+S save file · Ctrl+Z undo · Ctrl+Y redo · Ctrl+Q save session and quit\n\nOrdinary tabs restore after restart. Private tabs do not enter recovery; quitting with private text requires confirmation. Explicitly saved files remain on disk. Highlighting and AI are still in development.");
        return Ok(());
    }
    if args.first().is_some_and(|arg| arg == "--version") {
        println!("vibechar {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    if args.len() > 1
        || args
            .first()
            .is_some_and(|arg| arg.to_string_lossy().starts_with('-'))
    {
        return Err("expected one filename; use --help for usage".into());
    }
    if !io::stdout().is_terminal() {
        return Err("interactive output requires a terminal".into());
    }
    let path = args.first().map(std::path::absolute).transpose()?;
    let (mut recovery, restored) = Recovery::open(&recovery::directory()?)?;
    let resumed = restored.is_some();
    let mut editor = restored.map_or_else(|| Editor::new("", None), Editor::from_session);
    if let Some(path) = path {
        let existing = editor
            .session
            .buffers()
            .iter()
            .position(|buffer| buffer.path.as_ref() == Some(&path));
        if let Some(index) = existing {
            editor.select_buffer(index);
        } else {
            let text = files::load(&path)?;
            if resumed {
                editor.open(&text, Some(path));
            } else {
                editor = Editor::new(&text, Some(path));
            }
        }
    } else if !io::stdin().is_terminal() {
        let mut text = String::new();
        io::stdin().read_to_string(&mut text)?;
        if resumed {
            editor.open(&text, None);
        } else {
            editor = Editor::new(&text, None);
        }
    }
    let mut terminal = ratatui::init();
    let result = (|| -> io::Result<()> {
        execute!(io::stdout(), EnableBracketedPaste)?;
        edit(&mut terminal, &mut editor, &mut recovery)
    })();
    let paste_result = execute!(io::stdout(), DisableBracketedPaste);
    ratatui::restore();
    if result.is_err() {
        flush(&mut editor, &mut recovery)?;
    }
    result?;
    paste_result?;
    Ok(())
}

fn edit(
    terminal: &mut ratatui::DefaultTerminal,
    editor: &mut Editor,
    recovery: &mut Recovery,
) -> io::Result<()> {
    let mut deadline = Some(Instant::now() + Duration::from_millis(500));
    let mut latest = 0;
    let mut quit_failed = false;
    loop {
        while let Some((id, result)) = recovery.poll()? {
            if id == latest && deadline.is_none() {
                editor.recovery_status = if result.is_ok() {
                    "Saved locally"
                } else {
                    "Recovery save failed · Ctrl+S saves a file"
                };
            }
        }
        if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            editor.remember_cursor();
            latest = recovery.submit(Checkpoint::capture(&editor.session))?;
            deadline = None;
        }
        terminal.draw(|frame| view::draw(frame, editor))?;
        let timeout = deadline.map(|deadline| deadline.saturating_duration_since(Instant::now()));
        let timeout = if recovery.is_saving() {
            Some(timeout.map_or(Duration::from_millis(50), |value| {
                value.min(Duration::from_millis(50))
            }))
        } else {
            timeout
        };
        if let Some(timeout) = timeout {
            if !event::poll(timeout)? {
                continue;
            }
        }
        match event::read()? {
            Event::Key(key) if key.kind != KeyEventKind::Release => {
                let quitting =
                    key.code == KeyCode::Char('q') && key.modifiers.contains(KeyModifiers::CONTROL);
                if quit_failed && !quitting {
                    editor.message.clear();
                    quit_failed = false;
                }
                if editor.handle(key) {
                    match flush(editor, recovery) {
                        Ok(()) => break,
                        Err(_) if quit_failed => break,
                        Err(_) => {
                            quit_failed = true;
                            deadline = None;
                            editor.recovery_status = "Recovery save failed";
                            editor.message = "Ctrl+S to save a file · Ctrl+Q again quits without saving latest changes".into();
                            continue;
                        }
                    }
                }
                deadline = Some(Instant::now() + Duration::from_millis(500));
                editor.recovery_status = "Saving locally…";
            }
            Event::Paste(text) => {
                if quit_failed {
                    editor.message.clear();
                    quit_failed = false;
                }
                editor.insert(&text);
                deadline = Some(Instant::now() + Duration::from_millis(500));
                editor.recovery_status = "Saving locally…";
            }
            _ => {}
        }
    }
    Ok(())
}

fn flush(editor: &mut Editor, recovery: &mut Recovery) -> io::Result<()> {
    editor.remember_cursor();
    recovery.flush(Checkpoint::capture(&editor.session))
}

mod agent;
mod clipboard;
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
        self, DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture,
        Event, KeyCode, KeyEventKind, KeyModifiers, MouseEventKind,
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
    if args.first().is_some_and(|arg| arg == "--syntax-licenses") {
        print!("{}", vibechar_core::syntax::licenses());
        return Ok(());
    }
    if args.first().is_some_and(|arg| arg == "--syntax-count") {
        println!("{}", vibechar_core::syntax::syntax_count());
        return Ok(());
    }
    if args.first().is_some_and(|arg| arg == "run") {
        std::process::exit(agent::run(&args[1..])?);
    }
    if args
        .first()
        .is_some_and(|arg| arg == "--help" || arg == "-h")
    {
        println!("vibechar [FILE]\nvibechar run <reference> --env NAME -- <program> [args...]\n\nA tiny text workbench. Also accepts piped UTF-8 text.\n\nCtrl+N new · Ctrl+P new private · F6/Shift+F6 switch · Ctrl+W close\nCtrl+G / F7 Copy for Agent · F8 Paste Secret for Agent · F9 Close All Agent Access\nCtrl+S save file · F4 Save As · Ctrl+Z undo · Ctrl+Y redo · Ctrl+Q save session and quit\nF2 language search · Auto detects file names and pasted text locally\nShift+arrows/Home/End select · Ctrl+A select all · Esc clear selection\nMouse: click places caret · drag selects · double click selects word · wheel scrolls\nCtrl+C/X/V copy/cut/paste (also Ctrl+Insert, Shift+Delete/Insert)\nSave As: Enter submits a filename; Enter again confirms replacement; Esc cancels.\n\nSecret Drop works with local agents on the same host. Keep the editor open.\nOrdinary tabs restore after restart. Private tabs do not enter recovery; quitting with private text requires confirmation. Successful file saving ends private mode and closes that tab's agent access. AI rewrites are still in development.");
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
    let panic_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = execute!(io::stdout(), DisableMouseCapture, DisableBracketedPaste);
        panic_hook(info);
    }));
    let result = (|| -> io::Result<()> {
        execute!(io::stdout(), EnableBracketedPaste, EnableMouseCapture)?;
        edit(&mut terminal, &mut editor, &mut recovery)
    })();
    let input_result = execute!(io::stdout(), DisableMouseCapture, DisableBracketedPaste);
    ratatui::restore();
    if result.is_err() {
        flush(&mut editor, &mut recovery)?;
    }
    result?;
    input_result?;
    Ok(())
}

fn edit(
    terminal: &mut ratatui::DefaultTerminal,
    editor: &mut Editor,
    recovery: &mut Recovery,
) -> io::Result<()> {
    let mut deadline = Some(Instant::now() + Duration::from_millis(500));
    let mut latest = 0;
    let mut syntax_deadline = Some(Instant::now() + Duration::from_millis(120));
    let mut quit_failed = false;
    let mut drag_deadline = None;
    loop {
        let find_before = editor.recovery_mark();
        if editor.pump_find() {
            deadline.get_or_insert(Instant::now() + Duration::from_millis(500));
        }
        if editor.recovery_mark() != find_before {
            deadline = Some(Instant::now() + Duration::from_millis(500));
            syntax_deadline = Some(Instant::now() + Duration::from_millis(120));
            editor.recovery_status = "Saving locally…";
        }
        let find_busy = editor.find_busy();
        if editor.drag_scrolling() {
            let now = Instant::now();
            let next = drag_deadline.get_or_insert(now + Duration::from_millis(80));
            if now >= *next {
                let selection = editor.selection_state();
                editor.tick_drag();
                if editor.selection_state() != selection {
                    deadline.get_or_insert(now + Duration::from_millis(500));
                }
                *next = now + Duration::from_millis(80);
            }
        } else {
            drag_deadline = None;
        }
        if syntax_deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            editor.session.submit_syntax();
            syntax_deadline = None;
        }
        // Read busy before taking the frame: a concurrent completion cannot get lost.
        let syntax_busy = editor.session.syntax_busy();
        editor.pump_syntax();
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
        let mut timeout =
            deadline.map(|deadline| deadline.saturating_duration_since(Instant::now()));
        if find_busy {
            timeout = Some(timeout.map_or(Duration::from_millis(25), |value| {
                value.min(Duration::from_millis(25))
            }));
        }
        if let Some(drag) = drag_deadline {
            let delay = drag.saturating_duration_since(Instant::now());
            timeout = Some(timeout.map_or(delay, |value| value.min(delay)));
        }
        if let Some(syntax) = syntax_deadline {
            let delay = syntax.saturating_duration_since(Instant::now());
            timeout = Some(timeout.map_or(delay, |current| current.min(delay)));
        }
        if syntax_busy {
            timeout = Some(timeout.map_or(Duration::from_millis(25), |value| {
                value.min(Duration::from_millis(25))
            }));
        }
        if editor.session.has_drop_access() {
            timeout = Some(timeout.map_or(Duration::from_secs(1), |value| {
                value.min(Duration::from_secs(1))
            }));
        }
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
        let before = editor.recovery_mark();
        let selection_before = editor.selection_state();
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
            }
            Event::Paste(text) => {
                if quit_failed {
                    editor.message.clear();
                    quit_failed = false;
                }
                editor.insert(&text);
            }
            Event::Mouse(mouse) => {
                if quit_failed
                    && matches!(
                        mouse.kind,
                        MouseEventKind::Down(_)
                            | MouseEventKind::ScrollUp
                            | MouseEventKind::ScrollDown
                    )
                {
                    editor.message.clear();
                    quit_failed = false;
                }
                editor.mouse(mouse);
            }
            _ => {}
        }
        if editor.recovery_mark() != before {
            deadline = Some(Instant::now() + Duration::from_millis(500));
            syntax_deadline = Some(Instant::now() + Duration::from_millis(120));
            editor.recovery_status = "Saving locally…";
        } else if editor.selection_state() != selection_before {
            // Preserve the caret on restart without flashing saving or delaying text writes.
            deadline.get_or_insert(Instant::now() + Duration::from_millis(500));
        }
    }
    Ok(())
}

fn flush(editor: &mut Editor, recovery: &mut Recovery) -> io::Result<()> {
    editor.remember_cursor();
    recovery.flush(Checkpoint::capture(&editor.session))
}

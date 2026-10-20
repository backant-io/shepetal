//! Hand test on Windows: `cargo run -p input --example demo`. Hold Ctrl+Win: red ring, release:
//! pulsing blue for 2 s. Esc: yellow plus a hint. Every event is printed. Quit from the tray.

#[cfg(windows)]
fn main() -> windows::core::Result<()> {
    use input::*;
    use std::time::Duration;
    let (ui, events) = spawn(Hotkey::default())?;
    let mut login = false;
    loop {
        let ev = events.recv_timeout(Duration::from_secs(2));
        println!("{ev:?}");
        match ev {
            Ok(Event::Key(
                KeyEvent {
                    key: Key::Hotkey,
                    down,
                },
                _,
            )) => ui.set_mode(if down {
                Mode::Recording
            } else {
                Mode::Processing
            }),
            Ok(Event::Key(
                KeyEvent {
                    key: Key::Esc,
                    down: true,
                },
                _,
            )) => {
                ui.set_mode(Mode::Error);
                ui.show_hint("Esc pressed", Duration::from_millis(HINT_MS));
            }
            Ok(Event::StartAtLogin) => {
                login = !login;
                ui.set_start_at_login(login);
            }
            Ok(Event::Quit) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return Ok(()),
            Err(_) => ui.set_mode(Mode::Idle),
            _ => {}
        }
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("Windows only");
}

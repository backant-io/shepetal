// A GUI-subsystem exe: Windows opens no console window for it. Tests keep the console.
#![cfg_attr(not(test), windows_subsystem = "windows")]
// The pure modules are tested everywhere but only wired up on Windows.
#![cfg_attr(not(windows), allow(dead_code))]

mod flow;
mod system;
#[cfg(windows)]
mod win;

fn main() {
    #[cfg(windows)]
    win::run();
    #[cfg(not(windows))]
    eprintln!("shepetal.exe runs on Windows. On Linux, use linux/ (see linux/README.md).");
}

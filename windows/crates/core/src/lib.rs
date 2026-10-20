//! The part of shepetal for Windows that needs no Windows API, so it builds and is tested on any OS.
//! The other crates in this workspace feed it what they read from Windows and act on what it returns.

pub mod focus;
pub mod gesture;
pub mod model;
pub mod retention;
pub mod text;

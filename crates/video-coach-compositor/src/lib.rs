pub mod compositor;
pub mod frame;

pub use compositor::{Compositor, CompositorError};
pub use frame::Frame;

#[cfg(test)]
mod tests {
    #[test]
    fn smoke() {
        // Module wiring verified — runtime tests in subsequent tasks.
    }
}

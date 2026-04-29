// Compiles `ui/main.slint` into Rust bindings exposed via
// `slint::include_modules!()` in src code. Slint regenerates only when
// the .slint sources change; cargo's build script tracking handles that.
fn main() {
    slint_build::compile("ui/main.slint").expect("compile ui/main.slint");
}

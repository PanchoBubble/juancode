//! Boot the default tree and print it. Mounts plugins, binds nothing.
//!
//! ```sh
//! cargo run -p juancoded-cordis --example dump_config
//! ```

fn main() {
    let (loader, report) = juancoded_cordis::boot();
    print!("{}", juancoded_cordis::dump_config(&loader));
    if !report.is_clean() {
        eprintln!();
        for line in report.diagnostics() {
            eprintln!("warning: {line}");
        }
    }
}

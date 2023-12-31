pub mod config;
pub mod consts;
pub mod error;
pub mod types;
pub mod utils;

pub type Result<T> = std::result::Result<T, error::Error>;

fn main() -> anyhow::Result<()> {
    // embed build info to the binary
    utils::build_info();

    utils::init::init_env(true, true, "info");

    // example: get config
    let cfg = crate::config::Config::get();
    println!("config: {cfg}");

    Ok(())
}

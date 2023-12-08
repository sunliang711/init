pub mod config;
pub mod consts;
pub mod error;
pub mod types;
pub mod utils;

pub type Result<T> = std::result::Result<T, error::Error>;

fn main() -> anyhow::Result<()> {
    // embed build info to the binary
    utils::build_info();

    utils::init::init_env(true, true);

    // example: get config
    let cfg = crate::config::Config::get();
    println!("redis_url: {}", cfg.server.redis_url);
    println!("port: {}", cfg.server.port);

    Ok(())
}

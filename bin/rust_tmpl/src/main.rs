pub mod config;
pub mod error;
pub mod types;
pub mod utils;

pub type Result<T> = std::result::Result<T, error::Error>;

fn main() -> anyhow::Result<()> {
    // embed build info to the binary
    utils::build_info();

    // load .env file
    dotenv::dotenv().ok();

    // init env_logger
    env_logger::init();

    // TODO

    Ok(())
}

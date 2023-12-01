use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
pub struct Config {
    // TODO: add fields you need
    pub server: Server,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            server: Server::default(),
        }
    }
}

#[derive(Debug, Serialize, Deserialize, Default)]
pub struct Server {
    pub port: u16,
    pub redis_url: String,
}

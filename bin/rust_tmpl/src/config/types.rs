use parse_display::Display;
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Display)]
#[display("Config {{ server: {server} }}")]
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

#[derive(Debug, Serialize, Deserialize, Default, Display)]
#[display("Server: {{ port: {port} redis url: {redis_url} }}")]
pub struct Server {
    pub port: u16,
    pub redis_url: String,
}

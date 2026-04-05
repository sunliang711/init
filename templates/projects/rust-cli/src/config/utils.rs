use crate::config::types::Config;
use crate::consts;

use figment::{
    providers::{Env, Format, Serialized, Toml},
    Figment,
};
use once_cell::sync::OnceCell;

static CONFIG: OnceCell<Config> = OnceCell::new();

impl Config {
    pub fn get() -> &'static Config {
        CONFIG.get_or_init(|| {
            Figment::from(Serialized::defaults(Config::default()))
                .merge(Toml::file(consts::DEFAULT_CONFIG_FILE))
                .merge(Toml::file(consts::PRIVATE_CONFIG_FILE))
                .merge(Env::prefixed(consts::CONFIG_ENV_PREFIX))
                .extract()
                .expect(consts::ERR_EXTRACT_FIGMENT)
        })
    }
}

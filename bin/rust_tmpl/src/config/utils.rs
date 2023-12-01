use crate::config::types::Config;
use crate::consts;

use figment::{
    providers::{Env, Format, Serialized, Toml},
    Figment,
};
use once_cell::sync::OnceCell;
use std::sync::{RwLock, RwLockReadGuard};
static CONFIG: OnceCell<RwLock<Config>> = OnceCell::new();

impl Config {
    pub fn get() -> RwLockReadGuard<'static, Config> {
        let c = CONFIG.get_or_init(|| {
            let config = Figment::from(Serialized::defaults(Config::default()))
                .merge(Toml::file(consts::CONFIG_TOML_FILE))
                .merge(Env::prefixed(consts::CONFIG_ENV_PREFIX))
                .extract()
                .expect(consts::ERR_EXTRACT_FIGMENT);

            RwLock::new(config)
        });
        c.read().expect(consts::ERR_GET_CONFIG)
    }
}

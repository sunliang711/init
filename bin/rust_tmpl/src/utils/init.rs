pub fn init_env(dotenv: bool, env_logger: bool, rust_log_value: &str) {
    if dotenv {
        // load .env file
        dotenv::dotenv().ok();
    }

    if env_logger {
        if !rust_log_value.is_empty() {
            std::env::set_var("RUST_LOG", rust_log_value)
        }
        // init env_logger
        env_logger::init();
    }
}

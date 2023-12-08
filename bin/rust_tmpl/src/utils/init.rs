pub fn init_env(dotenv: bool, env_logger: bool) {
    if dotenv {
        // load .env file
        dotenv::dotenv().ok();
    }

    if env_logger {
        // init env_logger
        env_logger::init();
    }
}

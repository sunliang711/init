pub fn build_info() {
    let version = option_env!("PROJECT_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"));
    println!("{} version: {}", env!("CARGO_PKG_NAME"), version);

    if let Some(build_time) = option_env!("BUILD_TIME") {
        println!("{} build time: {}", env!("CARGO_PKG_NAME"), build_time);
    }
}

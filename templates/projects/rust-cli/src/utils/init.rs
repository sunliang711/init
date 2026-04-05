use tracing_subscriber::{fmt::time::FormatTime, EnvFilter};

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

pub fn init_tracing() {
    let format = tracing_subscriber::fmt::format()
        .with_timer(LocalTime)
        .with_level(true)
        .with_target(true)
        .with_file(true)
        .with_line_number(true)
        .with_ansi(true);

    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .event_format(format)
        .init();
}

struct LocalTime;
impl FormatTime for LocalTime {
    fn format_time(&self, w: &mut tracing_subscriber::fmt::format::Writer<'_>) -> std::fmt::Result {
        write!(w, "{}", chrono::Local::now().format("%FT%T"))
    }
}

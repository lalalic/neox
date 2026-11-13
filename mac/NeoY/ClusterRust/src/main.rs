mod config;
mod server;
mod sessions;
mod supervisor;
#[actix_web::main]
async fn main() {
    if let Err(e) = supervisor::main_cli().await {
        eprintln!("neo-cluster-rust: {e}");
        std::process::exit(1)
    }
}

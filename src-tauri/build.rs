fn main() {
    if std::env::var_os("CARGO_FEATURE_SECURITY_TEST").is_some() {
        tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
            tauri_build::AppManifest::new().commands(&["security_probe", "secret_store_probe"]),
        ))
        .expect("failed to build security-test permissions");
    } else {
        tauri_build::build();
    }
}

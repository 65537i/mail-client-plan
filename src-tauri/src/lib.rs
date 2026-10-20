#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default();

    #[cfg(feature = "security-test")]
    let builder = builder.invoke_handler(tauri::generate_handler![secret_store_probe]);

    #[cfg(feature = "security-test")]
    let builder = builder
        .plugin(tauri_plugin_wdio::init())
        .plugin(tauri_plugin_wdio_webdriver::init());

    #[cfg(feature = "smoke-test")]
    let builder = builder.setup(|app| {
        let handle = app.handle().clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(2));
            handle.exit(0);
        });
        Ok(())
    });

    builder
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(feature = "security-test")]
#[tauri::command]
fn secret_store_probe(
    operation: String,
    run_id: String,
    value: Option<String>,
) -> SecretStoreProbeResult {
    if run_id.is_empty()
        || run_id.len() > 64
        || !run_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return SecretStoreProbeResult::Error("invalid synthetic test identifier".to_string());
    }

    let username = format!("security-test-{run_id}");
    let entry = match keyring::Entry::new("com.example.mailclient.security-test", &username) {
        Ok(entry) => entry,
        Err(error) => {
            return SecretStoreProbeResult::Error(format!("secure store unavailable: {error}"));
        }
    };

    let result = match operation.as_str() {
        "store" => {
            let Some(secret) = value else {
                return SecretStoreProbeResult::Error("test secret is required".to_string());
            };
            entry
                .set_password(&secret)
                .map(|()| "stored".to_string())
                .map_err(|error| format!("secure store write failed: {error}"))
        }
        "read" => entry
            .get_password()
            .map_err(|error| format!("secure store read failed: {error}")),
        "delete" => entry
            .delete_credential()
            .map(|()| "deleted".to_string())
            .map_err(|error| format!("secure store delete failed: {error}")),
        _ => Err("unsupported secret-store test operation".to_string()),
    };

    match result {
        Ok(value) => SecretStoreProbeResult::Success(value),
        Err(error) => SecretStoreProbeResult::Error(error),
    }
}

#[cfg(feature = "security-test")]
#[derive(serde::Serialize)]
#[serde(tag = "status", content = "message", rename_all = "camelCase")]
enum SecretStoreProbeResult {
    Success(String),
    Error(String),
}

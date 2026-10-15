#[flutter_rust_bridge::frb(sync)] // Synchronous mode for simplicity of the demo
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}

/// T0.2 桥接验证：返回当前运行平台，双端（Windows / Android）各调用一次，
/// 界面显示同一函数结果即桥接打通。
#[flutter_rust_bridge::frb(sync)]
pub fn ping_platform() -> String {
    if cfg!(target_os = "android") {
        "android"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else {
        std::env::consts::OS
    }
    .to_string()
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();
}

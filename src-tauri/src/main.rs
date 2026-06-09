#![cfg_attr(
  all(not(debug_assertions), target_os = "windows"),
  windows_subsystem = "windows"
)]

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::Duration;
use axum::{
    body::Body,
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use tower_http::services::ServeDir;
use tauri::Manager;

// Struct to store active running server process and configurations
struct RunningServer {
    child: Child,
    port: u16,
    gpu_layers: usize,
    ctx_size: usize,
}

// Global thread-safe map of active running model servers
static RUNNING_SERVERS: Lazy<Mutex<HashMap<String, RunningServer>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

#[derive(Serialize)]
struct ModelInfo {
    filename: String,
    size_gb: f64,
    is_31b: bool,
}

#[derive(Deserialize)]
struct StartServerRequest {
    model: String,
    turboquant: Option<bool>,
    ctx_size: Option<usize>,
}

#[derive(Serialize)]
struct StartServerResponse {
    status: String,
    model: String,
    gpu_layers: usize,
    port: u16,
}

#[derive(Deserialize)]
struct StopServerRequest {
    model: Option<String>,
}

#[derive(Serialize)]
struct StopServerResponse {
    status: String,
    stopped: Vec<String>,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
struct ChatMessage {
    role: String,
    content: String,
}

#[derive(Deserialize, Debug, Clone)]
struct ChatRequest {
    model: Option<String>,
    messages: Vec<ChatMessage>,
    stream: Option<bool>,
    n_predict: Option<usize>,
    temperature: Option<f32>,
}

#[derive(Serialize)]
struct ServerStatusDetail {
    status: String,
    port: u16,
    gpu_layers: usize,
    ctx_size: usize,
}

fn get_system_ram_gb() -> f64 {
    #[cfg(target_os = "macos")]
    {
        if let Ok(output) = Command::new("sysctl")
            .args(&["-n", "hw.memsize"])
            .output()
        {
            if let Ok(s) = String::from_utf8(output.stdout) {
                if let Ok(bytes) = s.trim().parse::<u64>() {
                    return bytes as f64 / (1024.0 * 1024.0 * 1024.0);
                }
            }
        }
    }
    
    #[cfg(target_os = "windows")]
    {
        if let Ok(output) = Command::new("wmic")
            .args(&["ComputerSystem", "get", "TotalPhysicalMemory"])
            .output()
        {
            if let Ok(s) = String::from_utf8(output.stdout) {
                let lines: Vec<&str> = s.lines().collect();
                if lines.len() >= 2 {
                    if let Ok(bytes) = lines[1].trim().parse::<u64>() {
                        return bytes as f64 / (1024.0 * 1024.0 * 1024.0);
                    }
                }
            }
        }
    }
    
    #[cfg(target_os = "linux")]
    {
        if let Ok(s) = fs::read_to_string("/proc/meminfo") {
            for line in s.lines() {
                if line.starts_with("MemTotal:") {
                    let parts: Vec<&str> = line.split_whitespace().collect();
                    if parts.len() >= 2 {
                        if let Ok(kb) = parts[1].parse::<u64>() {
                            return kb as f64 / (1024.0 * 1024.0);
                        }
                    }
                }
            }
        }
    }
    
    16.0
}

#[derive(Serialize)]
struct AppStatusResponse {
    status: String,
    model: Option<String>,
    gpu_layers: usize,
    running_servers: HashMap<String, ServerStatusDetail>,
    system_ram_gb: f64,
}

#[derive(Serialize, Clone)]
struct SpeedBenchmark {
    model: String,
    load_time_sec: f64,
    prompt_speed_ts: f64,
    gen_speed_ts: f64,
    avg_latency_sec: f64,
}

#[derive(Serialize, Clone)]
struct MemoryBenchmark {
    context_size: usize,
    f16_mem_mb: f64,
    tq_mem_mb: f64,
    saved_mb: f64,
    saved_pct: f64,
    f16_gen_ts: f64,
    tq_gen_ts: f64,
}

#[derive(Serialize)]
struct BenchmarkResponse {
    speeds: Vec<SpeedBenchmark>,
    memory: Vec<MemoryBenchmark>,
}

// --------------------------------------------------------------------------
// Path Resolver
// --------------------------------------------------------------------------
fn get_project_path(rel_path: &str) -> PathBuf {
    let p = PathBuf::from(rel_path);
    if p.exists() {
        p
    } else {
        let parent = PathBuf::from("..").join(rel_path);
        if parent.exists() {
            parent
        } else {
            p
        }
    }
}

// --------------------------------------------------------------------------
// Executable Path Locator
// --------------------------------------------------------------------------
fn find_executable() -> Option<PathBuf> {
    let ext = if cfg!(target_os = "windows") { ".exe" } else { "" };
    
    // Checks relative paths
    let candidates = vec![
        format!("bin/llama-server{}", ext),
        format!("bin/server{}", ext),
        format!("llama.cpp/build/bin/llama-server{}", ext),
        format!("llama.cpp/build/bin/Release/llama-server{}", ext),
    ];
    
    for c in candidates {
        let p = get_project_path(&c);
        if p.is_file() {
            return Some(p);
        }
    }
    
    // Checks standard system path (equivalent to shutil.which)
    if let Ok(paths) = std::env::var("PATH") {
        for path in std::env::split_paths(&paths) {
            let p1 = path.join(format!("llama-server{}", ext));
            if p1.is_file() {
                return Some(p1);
            }
            let p2 = path.join(format!("server{}", ext));
            if p2.is_file() {
                return Some(p2);
            }
        }
    }
    
    None
}

// Cleanup any processes that have terminated in the background
fn cleanup_dead_servers() {
    let mut servers = RUNNING_SERVERS.lock().unwrap();
    let mut dead = Vec::new();
    for (model, srv) in servers.iter_mut() {
        match srv.child.try_wait() {
            Ok(Some(_)) => {
                dead.push(model.clone());
            }
            Err(_) => {
                dead.push(model.clone());
            }
            Ok(None) => {}
        }
    }
    for m in dead {
        servers.remove(&m);
    }
}

// --------------------------------------------------------------------------
// Axum API Handlers
// --------------------------------------------------------------------------

// API: GET /api/models
async fn get_models() -> impl IntoResponse {
    let model_dir = get_project_path("models");
    if !model_dir.exists() {
        return Json(Vec::<ModelInfo>::new());
    }
    
    let mut models = Vec::new();
    if let Ok(entries) = fs::read_dir(&model_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() && path.extension().and_then(|s| s.to_str()) == Some("gguf") {
                if let Ok(metadata) = entry.metadata() {
                    let filename = entry.file_name().to_string_lossy().into_owned();
                    let size_gb = (metadata.len() as f64) / (1024.0 * 1024.0 * 1024.0);
                    let is_31b = ["31B", "32B", "72B", "70B", "35B", "27B", "122B", "397B"]
                        .iter()
                        .any(|x| filename.contains(x));
                        
                    models.push(ModelInfo {
                        filename,
                        size_gb: (size_gb * 100.0).round() / 100.0,
                        is_31b,
                    });
                }
            }
        }
    }
    
    models.sort_by(|a, b| a.size_gb.partial_cmp(&b.size_gb).unwrap());
    Json(models)
}

// API: GET /api/status
async fn get_status() -> axum::response::Response {
    cleanup_dead_servers();
    
    // Copy out running server metadata locally so we release the MutexGuard
    // before executing async HTTP requests. This keeps the handler Send-safe.
    let server_ports: Vec<(String, u16, usize, usize)> = {
        let servers = RUNNING_SERVERS.lock().unwrap();
        servers
            .iter()
            .map(|(model, srv)| (model.clone(), srv.port, srv.gpu_layers, srv.ctx_size))
            .collect()
    };
    
    let mut models_status = HashMap::new();
    
    let client = match reqwest::Client::builder()
        .timeout(Duration::from_millis(200))
        .build() {
            Ok(c) => c,
            Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
        };
        
    for (model, port, gpu_layers, ctx_size) in server_ports {
        // Query llama-server health endpoint
        let health_url = format!("http://localhost:{}/health", port);
        let is_ready = match client.get(&health_url).send().await {
            Ok(r) => r.status().is_success(),
            Err(_) => false,
        };
        
        models_status.insert(
            model,
            ServerStatusDetail {
                status: if is_ready { "Running".to_string() } else { "Starting".to_string() },
                port,
                gpu_layers,
                ctx_size,
            },
        );
    }
    
    let mut status = "Stopped".to_string();
    let mut active_model = None;
    let mut gpu_layers = 0;
    
    if !models_status.is_empty() {
        let first_key = models_status.keys().next().unwrap().clone();
        status = models_status[&first_key].status.clone();
        gpu_layers = models_status[&first_key].gpu_layers;
        active_model = Some(first_key);
    }
    
    Json(AppStatusResponse {
        status,
        model: active_model,
        gpu_layers,
        running_servers: models_status,
        system_ram_gb: get_system_ram_gb(),
    }).into_response()
}

// API: POST /api/start
#[axum::debug_handler]
async fn start_server(Json(payload): Json<StartServerRequest>) -> axum::response::Response {
    cleanup_dead_servers();
    
    let model_file = payload.model;
    let use_turboquant = payload.turboquant.unwrap_or(true);
    let ctx_size = payload.ctx_size.unwrap_or(4096);
    
    // Check if server is already running under lock
    {
        let servers = RUNNING_SERVERS.lock().unwrap();
        if let Some(srv) = servers.get(&model_file) {
            return Json(StartServerResponse {
                status: "Running".to_string(),
                model: model_file,
                gpu_layers: srv.gpu_layers,
                port: srv.port,
            }).into_response();
        }
    }
    
    let model_path = get_project_path("models").join(&model_file);
    if !model_path.is_file() {
        return (StatusCode::NOT_FOUND, "Model file not found".to_string()).into_response();
    }
    
    let exe_path = match find_executable() {
        Some(p) => p,
        None => return (StatusCode::INTERNAL_SERVER_ERROR, "Compiled C++ backend server (llama-server) not found. Please compile first.".to_string()).into_response(),
    };
    
    // Auto-adjust GPU layers based on model sizes
    let mut gpu_layers = 99;
    if model_file.contains("72B") || model_file.contains("70B") {
        gpu_layers = 18;
    } else if ["31B", "32B", "35B", "27B"].iter().any(|x| model_file.contains(x)) {
        gpu_layers = 32;
    } else if model_file.contains("122B") {
        gpu_layers = 10;
    } else if model_file.contains("397B") {
        gpu_layers = 0;
    }
    
    // Pick an unused port starting scanning at 8080
    let port = match portpicker::pick_unused_port() {
        Some(p) => p,
        None => return (StatusCode::INTERNAL_SERVER_ERROR, "Failed to allocate free port".to_string()).into_response(),
    };
    
    // Get threads count natively using std toolchain APIs
    let threads = std::cmp::max(1, std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).saturating_sub(2));
    
    let mut cmd_args = vec![
        "-m".to_string(),
        model_path.to_string_lossy().into_owned(),
        "-t".to_string(),
        threads.to_string(),
        "-ngl".to_string(),
        gpu_layers.to_string(),
        "-c".to_string(),
        ctx_size.to_string(),
        "--port".to_string(),
        port.to_string(),
    ];
    
    if use_turboquant {
        cmd_args.push("-ctk".to_string());
        cmd_args.push("q4_0".to_string());
        cmd_args.push("-ctv".to_string());
        cmd_args.push("q4_0".to_string());
    }
    
    println!("[*] Starting llama-server on port {}: {:?}", port, cmd_args);
    
    let child = match Command::new(&exe_path)
        .args(&cmd_args)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    };

    // Store child under lock scope and immediately release lock to stay Send-safe
    {
        let mut servers = RUNNING_SERVERS.lock().unwrap();
        servers.insert(
            model_file.clone(),
            RunningServer {
                child,
                port,
                gpu_layers,
                ctx_size,
            },
        );
    }

    // Allow 1.5 seconds for startup diagnostic check (await is Send-safe here as MutexGuard is dropped)
    tokio::time::sleep(Duration::from_millis(1500)).await;
    
    let mut crashed = false;
    {
        let mut servers_check = RUNNING_SERVERS.lock().unwrap();
        if let Some(srv) = servers_check.get_mut(&model_file) {
            if let Ok(Some(_status)) = srv.child.try_wait() {
                crashed = true;
            }
        }
    }
    
    if crashed {
        let mut servers_cleanup = RUNNING_SERVERS.lock().unwrap();
        servers_cleanup.remove(&model_file);
        return (StatusCode::INTERNAL_SERVER_ERROR, "llama-server subprocess failed to start. Check models configuration.".to_string()).into_response();
    }
    
    Json(StartServerResponse {
        status: "Started".to_string(),
        model: model_file,
        gpu_layers,
        port,
    }).into_response()
}

// API: POST /api/stop
async fn stop_server(Json(payload): Json<StopServerRequest>) -> Json<StopServerResponse> {
    cleanup_dead_servers();
    
    let mut servers = RUNNING_SERVERS.lock().unwrap();
    let mut stopped = Vec::new();
    
    if let Some(model_file) = payload.model {
        if let Some(mut srv) = servers.remove(&model_file) {
            let _ = srv.child.kill();
            stopped.push(model_file);
        }
    } else {
        // Kill all
        let keys: Vec<String> = servers.keys().cloned().collect();
        for k in keys {
            if let Some(mut srv) = servers.remove(&k) {
                let _ = srv.child.kill();
                stopped.push(k);
            }
        }
    }
    
    Json(StopServerResponse {
        status: "Stopped".to_string(),
        stopped,
    })
}

// API: POST /api/chat (SSE Stream proxy)
async fn proxy_chat(Json(payload): Json<ChatRequest>) -> axum::response::Response {
    cleanup_dead_servers();
    
    let model_file = match payload.model {
        Some(m) => m,
        None => {
            let servers = RUNNING_SERVERS.lock().unwrap();
            if servers.is_empty() {
                return (StatusCode::SERVICE_UNAVAILABLE, "No model backend is running".to_string()).into_response();
            }
            servers.keys().next().unwrap().clone()
        }
    };
    
    let port = {
        let servers = RUNNING_SERVERS.lock().unwrap();
        match servers.get(&model_file) {
            Some(srv) => srv.port,
            None => return (StatusCode::SERVICE_UNAVAILABLE, "Specified model backend is not running".to_string()).into_response(),
        }
    };
    
    // Map messages payload to chat format
    let mut prompt = String::new();
    for m in payload.messages {
        match m.role.as_str() {
            "system" => prompt.push_str(&format!("<|im_start|>system\n{}<|im_end|>\n", m.content)),
            "user" => prompt.push_str(&format!("<|im_start|>user\n{}<|im_end|>\n", m.content)),
            "assistant" => prompt.push_str(&format!("<|im_start|>assistant\n{}<|im_end|>\n", m.content)),
            _ => {}
        }
    }
    prompt.push_str("<|im_start|>assistant\n");
    
    let llama_payload = serde_json::json!({
        "prompt": prompt,
        "stream": payload.stream.unwrap_or(true),
        "n_predict": payload.n_predict.unwrap_or(1024),
        "temperature": payload.temperature.unwrap_or(0.7),
        "stop": vec!["<|im_end|>", "<|im_start|>", "<|im_end|>\n"]
    });
    
    let client = reqwest::Client::new();
    let request_url = format!("http://localhost:{}/completion", port);
    
    let res = match client
        .post(&request_url)
        .json(&llama_payload)
        .send()
        .await {
            Ok(r) => r,
            Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
        };
        
    let headers = res.headers().clone();
    let stream = res.bytes_stream();
    let body = Body::from_stream(stream);
    
    let mut response_builder = axum::response::Response::builder()
        .status(StatusCode::OK);
        
    for (name, val) in headers.iter() {
        response_builder = response_builder.header(name, val);
    }
    
    let response = match response_builder.body(body) {
        Ok(r) => r.into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    };
    
    response
}

// API: GET /api/benchmarks
async fn get_benchmarks() -> axum::response::Response {
    let fallback_speeds = vec![
        SpeedBenchmark { model: "gemma-4-E2B-it-Q4_K_M".to_string(), load_time_sec: 0.0, prompt_speed_ts: 499.8, gen_speed_ts: 68.7, avg_latency_sec: 8.89 },
        SpeedBenchmark { model: "gemma-4-E4B-it-Q4_K_M".to_string(), load_time_sec: 0.0, prompt_speed_ts: 283.5, gen_speed_ts: 47.8, avg_latency_sec: 12.71 },
        SpeedBenchmark { model: "gemma-4-12B-it-Q4_K_M".to_string(), load_time_sec: 0.0, prompt_speed_ts: 116.6, gen_speed_ts: 23.6, avg_latency_sec: 24.32 },
        SpeedBenchmark { model: "gemma-4-26B-A4B-it-UD-Q4_K_M".to_string(), load_time_sec: 0.0, prompt_speed_ts: 177.7, gen_speed_ts: 43.6, avg_latency_sec: 16.16 },
        SpeedBenchmark { model: "gemma-4-31B-it-Q4_K_M".to_string(), load_time_sec: 0.0, prompt_speed_ts: 11.9, gen_speed_ts: 5.9, avg_latency_sec: 138.18 },
    ];
    
    let fallback_memory = vec![
        MemoryBenchmark { context_size: 1024, f16_mem_mb: 3145.2, tq_mem_mb: 3135.1, saved_mb: 10.1, saved_pct: 0.3, f16_gen_ts: 98.5, tq_gen_ts: 76.9 },
        MemoryBenchmark { context_size: 4096, f16_mem_mb: 3163.0, tq_mem_mb: 3144.1, saved_mb: 19.0, saved_pct: 0.6, f16_gen_ts: 97.5, tq_gen_ts: 78.8 },
        MemoryBenchmark { context_size: 8192, f16_mem_mb: 3185.8, tq_mem_mb: 3154.1, saved_mb: 31.8, saved_pct: 1.0, f16_gen_ts: 94.3, tq_gen_ts: 80.9 },
        MemoryBenchmark { context_size: 16384, f16_mem_mb: 3234.2, tq_mem_mb: 3161.3, saved_mb: 72.9, saved_pct: 2.3, f16_gen_ts: 96.8, tq_gen_ts: 79.1 },
        MemoryBenchmark { context_size: 32768, f16_mem_mb: 3329.7, tq_mem_mb: 3196.7, saved_mb: 133.0, saved_pct: 4.0, f16_gen_ts: 97.5, tq_gen_ts: 81.4 },
    ];
    
    let filepath = get_project_path("benchmark_results.md");
    if !filepath.is_file() {
        return Json(BenchmarkResponse {
            speeds: fallback_speeds,
            memory: fallback_memory,
        }).into_response();
    }
    
    let mut speeds = Vec::new();
    let mut memory = Vec::new();
    
    if let Ok(content) = fs::read_to_string(&filepath) {
        let mut current_section = "";
        for line in content.lines() {
            let line_trimmed = line.trim();
            if line_trimmed.is_empty() {
                continue;
            }
            
            if line_trimmed.contains("Speed & Efficiency Comparison") {
                current_section = "speeds";
                continue;
            } else if line_trimmed.contains("Context Length & Memory Scaling Benchmark") {
                current_section = "memory";
                continue;
            } else if line_trimmed.starts_with("## ") && line_trimmed.contains("Specialized Intelligence") {
                current_section = "";
            }
            
            if line_trimmed.starts_with('|') {
                let parts: Vec<&str> = line_trimmed.split('|').map(|s| s.trim()).collect();
                if parts.len() < 3 {
                    continue;
                }
                
                // Skip table headers and separators
                let first_cell = parts[1];
                if first_cell.contains("Model Name")
                    || first_cell.contains("Context Size")
                    || first_cell.contains("---")
                    || first_cell.contains(":---")
                {
                    continue;
                }
                
                if current_section == "speeds" && parts.len() >= 6 {
                    let model = parts[1].replace("**", "");
                    let load_time = parts[2].replace('s', "").parse::<f64>().unwrap_or(0.0);
                    let prompt_speed = parts[3].replace("t/s", "").parse::<f64>().unwrap_or(0.0);
                    let gen_speed = parts[4].replace("t/s", "").parse::<f64>().unwrap_or(0.0);
                    let avg_latency = parts[5].replace('s', "").parse::<f64>().unwrap_or(0.0);
                    speeds.push(SpeedBenchmark {
                        model,
                        load_time_sec: load_time,
                        prompt_speed_ts: prompt_speed,
                        gen_speed_ts: gen_speed,
                        avg_latency_sec: avg_latency,
                    });
                } else if current_section == "memory" && parts.len() >= 8 {
                    let ctx_size = parts[1].parse::<usize>().unwrap_or(0);
                    let f16_mem = parts[2].replace("MB", "").parse::<f64>().unwrap_or(0.0);
                    let tq_mem = parts[3].replace("MB", "").parse::<f64>().unwrap_or(0.0);
                    let saved_mb = parts[4].replace("MB", "").parse::<f64>().unwrap_or(0.0);
                    let saved_pct = parts[5].replace('%', "").replace("**", "").parse::<f64>().unwrap_or(0.0);
                    let f16_gen = parts[6].replace("t/s", "").parse::<f64>().unwrap_or(0.0);
                    let tq_gen = parts[7].replace("t/s", "").parse::<f64>().unwrap_or(0.0);
                    memory.push(MemoryBenchmark {
                        context_size: ctx_size,
                        f16_mem_mb: f16_mem,
                        tq_mem_mb: tq_mem,
                        saved_mb,
                        saved_pct: saved_pct,
                        f16_gen_ts: f16_gen,
                        tq_gen_ts: tq_gen,
                    });
                }
            }
        }
    }
    
    Json(BenchmarkResponse {
        speeds: if speeds.is_empty() { fallback_speeds } else { speeds },
        memory: if memory.is_empty() { fallback_memory } else { memory },
    }).into_response()
}

// --------------------------------------------------------------------------
// Hugging Face Search & Model Downloader APIs
// --------------------------------------------------------------------------

#[derive(Deserialize)]
struct SearchRequest {
    q: String,
}

async fn search_huggingface(axum::extract::Query(params): axum::extract::Query<SearchRequest>) -> impl IntoResponse {
    let client = match reqwest::Client::builder()
        .user_agent("turbobitquant")
        .build() {
            Ok(c) => c,
            Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
        };
        
    let url = "https://huggingface.co/api/models";
    match client.get(url)
        .query(&[
            ("search", &params.q),
            ("filter", &"gguf".to_string()),
            ("sort", &"downloads".to_string()),
            ("direction", &"-1".to_string()),
            ("limit", &"15".to_string()),
        ])
        .send()
        .await {
            Ok(res) => {
                if let Ok(bytes) = res.bytes().await {
                    let body = String::from_utf8_lossy(&bytes).to_string();
                    return (StatusCode::OK, [("content-type", "application/json")], body).into_response();
                }
            }
            Err(e) => {
                return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response();
            }
        }
        
    (StatusCode::INTERNAL_SERVER_ERROR, "Failed to query Hugging Face API".to_string()).into_response()
}

#[derive(Deserialize)]
struct FilesRequest {
    repo: String,
}

async fn get_hf_files(axum::extract::Query(params): axum::extract::Query<FilesRequest>) -> impl IntoResponse {
    let client = match reqwest::Client::builder()
        .user_agent("turbobitquant")
        .build() {
            Ok(c) => c,
            Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
        };
        
    let url = format!("https://huggingface.co/api/models/{}", params.repo);
    
    match client.get(&url).send().await {
        Ok(res) => {
            if let Ok(bytes) = res.bytes().await {
                let body = String::from_utf8_lossy(&bytes).to_string();
                return (StatusCode::OK, [("content-type", "application/json")], body).into_response();
            }
        }
        Err(e) => {
            return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response();
        }
    }
    
    (StatusCode::INTERNAL_SERVER_ERROR, "Failed to fetch model details from Hugging Face".to_string()).into_response()
}

#[derive(Serialize, Clone)]
struct DownloadState {
    filename: String,
    downloaded_bytes: u64,
    total_bytes: u64,
    percent: f64,
    speed_mbps: f64,
    status: String,
}

static ACTIVE_DOWNLOADS: Lazy<Mutex<HashMap<String, DownloadState>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

#[derive(Deserialize)]
struct DownloadStartRequest {
    repo: String,
    filename: String,
}

async fn start_download(Json(payload): Json<DownloadStartRequest>) -> impl IntoResponse {
    let repo = payload.repo.clone();
    let filename = payload.filename.clone();
    
    let safe_basename = Path::new(&filename)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(&filename)
        .to_string();
        
    // Check if already downloading
    {
        let downloads = ACTIVE_DOWNLOADS.lock().unwrap();
        if downloads.contains_key(&safe_basename) {
            return (StatusCode::BAD_REQUEST, "Model is already downloading".to_string()).into_response();
        }
    }
    
    // Spawn task to perform download in background
    tokio::spawn(async move {
        perform_download(repo, filename).await;
    });
    
    Json(serde_json::json!({ "status": "Started", "filename": safe_basename })).into_response()
}

async fn perform_download(repo: String, filename: String) {
    let client = reqwest::Client::new();
    let url = format!("https://huggingface.co/{}/resolve/main/{}", repo, filename);
    
    let safe_basename = Path::new(&filename)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(&filename)
        .to_string();
        
    let models_dir = get_project_path("models");
    let dest_path = models_dir.join(&safe_basename);
    let _ = fs::create_dir_all(&models_dir);
    
    {
        let mut downloads = ACTIVE_DOWNLOADS.lock().unwrap();
        downloads.insert(
            safe_basename.clone(),
            DownloadState {
                filename: safe_basename.clone(),
                downloaded_bytes: 0,
                total_bytes: 0,
                percent: 0.0,
                speed_mbps: 0.0,
                status: "Connecting".to_string(),
            },
        );
    }
    
    let res = match client.get(&url).send().await {
        Ok(r) => r,
        Err(e) => {
            update_download_status(&safe_basename, "Failed".to_string(), 0, 0, e.to_string());
            return;
        }
    };
    
    if !res.status().is_success() {
        update_download_status(&safe_basename, "Failed".to_string(), 0, 0, format!("HTTP {}", res.status()));
        return;
    }
    
    let total_size = res.content_length().unwrap_or(0);
    
    let mut file = match tokio::fs::File::create(&dest_path).await {
        Ok(f) => f,
        Err(e) => {
            update_download_status(&safe_basename, "Failed".to_string(), 0, 0, e.to_string());
            return;
        }
    };
    
    let mut stream = res.bytes_stream();
    let mut downloaded: u64 = 0;
    let start_time = std::time::Instant::now();
    let mut last_update = std::time::Instant::now();
    
    use futures_util::StreamExt;
    use tokio::io::AsyncWriteExt;
    
    while let Some(chunk_result) = stream.next().await {
        {
            let downloads = ACTIVE_DOWNLOADS.lock().unwrap();
            if !downloads.contains_key(&safe_basename) {
                // Cancelled
                drop(file);
                let _ = fs::remove_file(dest_path);
                return;
            }
        }
        
        let chunk = match chunk_result {
            Ok(c) => c,
            Err(e) => {
                update_download_status(&safe_basename, "Failed".to_string(), downloaded, total_size, e.to_string());
                return;
            }
        };
        
        if let Err(e) = file.write_all(&chunk).await {
            update_download_status(&safe_basename, "Failed".to_string(), downloaded, total_size, e.to_string());
            return;
        }
        
        downloaded += chunk.len() as u64;
        
        if last_update.elapsed() >= Duration::from_millis(500) {
            let elapsed_sec = start_time.elapsed().as_secs_f64();
            let speed_mbps = if elapsed_sec > 0.0 {
                (downloaded as f64 / (1024.0 * 1024.0)) / elapsed_sec
            } else {
                0.0
            };
            
            let percent = if total_size > 0 {
                (downloaded as f64 / total_size as f64) * 100.0
            } else {
                0.0
            };
            
            {
                let mut downloads = ACTIVE_DOWNLOADS.lock().unwrap();
                if let Some(state) = downloads.get_mut(&safe_basename) {
                    state.downloaded_bytes = downloaded;
                    state.total_bytes = total_size;
                    state.percent = percent;
                    state.speed_mbps = speed_mbps;
                    state.status = "Downloading".to_string();
                }
            }
            last_update = std::time::Instant::now();
        }
    }
    
    let _ = file.flush().await;
    
    {
        let mut downloads = ACTIVE_DOWNLOADS.lock().unwrap();
        if let Some(state) = downloads.get_mut(&safe_basename) {
            state.downloaded_bytes = total_size;
            state.total_bytes = total_size;
            state.percent = 100.0;
            state.speed_mbps = 0.0;
            state.status = "Completed".to_string();
        }
    }
}

fn update_download_status(filename: &str, status: String, downloaded: u64, total: u64, err_msg: String) {
    let mut downloads = ACTIVE_DOWNLOADS.lock().unwrap();
    if let Some(state) = downloads.get_mut(filename) {
        state.status = if status == "Failed" { format!("Failed: {}", err_msg) } else { status };
        state.downloaded_bytes = downloaded;
        state.total_bytes = total;
    }
}

async fn get_download_status() -> impl IntoResponse {
    let downloads = ACTIVE_DOWNLOADS.lock().unwrap();
    let list: Vec<DownloadState> = downloads.values().cloned().collect();
    Json(list)
}

#[derive(Deserialize)]
struct DownloadCancelRequest {
    filename: String,
}

async fn cancel_download(Json(payload): Json<DownloadCancelRequest>) -> impl IntoResponse {
    let mut downloads = ACTIVE_DOWNLOADS.lock().unwrap();
    if downloads.remove(&payload.filename).is_some() {
        Json(serde_json::json!({ "status": "Cancelled" })).into_response()
    } else {
        Json(serde_json::json!({ "status": "NotFound" })).into_response()
    }
}

// --------------------------------------------------------------------------
// Axum Engine Starter
// --------------------------------------------------------------------------
async fn start_axum_server(port: u16) {
    let app = Router::new()
        .route("/api/models", get(get_models))
        .route("/api/status", get(get_status))
        .route("/api/start", post(start_server))
        .route("/api/stop", post(stop_server))
        .route("/api/chat", post(proxy_chat))
        .route("/api/benchmarks", get(get_benchmarks))
        .route("/api/hf/search", get(search_huggingface))
        .route("/api/hf/files", get(get_hf_files))
        .route("/api/download/start", post(start_download))
        .route("/api/download/status", get(get_download_status))
        .route("/api/download/cancel", post(cancel_download))
        .fallback_service(ServeDir::new(get_project_path("static"))); // Tauri executes from project root usually

    let listener = tokio::net::TcpListener::bind(format!("127.0.0.1:{}", port))
        .await
        .unwrap();
    println!("[*] Axum local coordinator listening on http://127.0.0.1:{}", port);
    axum::serve(listener, app).await.unwrap();
}

// --------------------------------------------------------------------------
// Main App Entry point
// --------------------------------------------------------------------------
fn main() {
    // Start local HTTP coordinator in the background on tokio runtime
    let axum_port = portpicker::pick_unused_port().unwrap_or(5000);
    
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(start_axum_server(axum_port));
    });

    tauri::Builder::default()
        .setup(move |app| {
            let window = app.get_webview_window("main").unwrap();
            let start_url = format!("http://localhost:{}", axum_port);
            println!("[*] Pointing webview window to {}", start_url);
            
            // Navigate the window to the local web server
            let _ = window.navigate(start_url.parse().unwrap());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

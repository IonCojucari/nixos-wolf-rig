//! A web page for the `transcribe` command (modules/whisper.nix).
//!
//! Upload audio or video files from a phone or a browser. They wait in a
//! queue that runs one at a time (there is one GPU), and each transcript
//! comes back as .txt, .srt and .vtt. Each job is a folder under
//! $STATE_DIRECTORY/jobs holding job.json and the files `transcribe` writes,
//! so the queue, its order and what was paused survive a restart. Uploads are
//! streamed to disk, never held in memory.
//!
//! Pausing: the whole queue (the running job finishes, the next one waits),
//! a queued job (skipped until resumed) or the running job (SIGSTOP on its
//! process group, so it continues where it stopped; it keeps its GPU memory
//! meanwhile and the queue waits behind it).
//!
//! Env: LISTEN (default [::]:8091), TRANSCRIBE (path of the command),
//!      KEEP_DAYS (finished jobs are deleted after this, default 7, 0 = never)

use std::{
    collections::{HashMap, VecDeque},
    fmt::Display,
    path::{Path as FsPath, PathBuf},
    process::Stdio,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use axum::{
    body::Body,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::{header, StatusCode},
    response::{Html, IntoResponse, Response},
    routing::{delete, get, post},
    Json, Router,
};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncWriteExt, BufReader},
    process::Command,
    sync::{watch, Notify},
};

const INDEX: &str = include_str!("index.html");
const LANGS: &[&str] = &["ro", "en", "ru", "uk", "fr", "de", "it", "es", "auto"];
const OUTPUTS: &[&str] = &["txt", "srt", "vtt"];
const PREVIEW_LINES: usize = 3;
const ERROR_LINES: usize = 20;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Status {
    Queued,
    Running,
    Done,
    Failed,
}

#[derive(Clone, Serialize, Deserialize)]
struct Job {
    id: String,
    name: String,
    lang: String,
    input: String,
    size: u64,
    status: Status,
    #[serde(default)]
    progress: u8,
    created: f64,
    /// Place in the queue, lowest first.
    #[serde(default)]
    rank: f64,
    /// Queued: skipped by the queue. Running: stopped (SIGSTOP).
    #[serde(default)]
    paused: bool,
    #[serde(default)]
    started: Option<f64>,
    #[serde(default)]
    finished: Option<f64>,
    /// When the running job was stopped, and how long it has been stopped in
    /// all, so the page can show the time it actually ran.
    #[serde(default)]
    paused_at: Option<f64>,
    #[serde(default)]
    paused_total: f64,
    #[serde(default)]
    preview: Vec<String>,
    #[serde(default)]
    error: Option<String>,
    /// What a running job does after the transcription itself (the repair).
    #[serde(default)]
    stage: Option<String>,
    /// Passages that came out as a loop or as invented text and were
    /// transcribed again (see repair()).
    #[serde(default)]
    repaired: u32,
}

/// The job transcribe is running for.
struct Current {
    id: String,
    pid: Option<u32>,
    /// Set to true to stop the job; it can run several processes (the
    /// transcription, then one per repaired passage), so this is a watch.
    cancel: watch::Sender<bool>,
}

struct App {
    dir: PathBuf,
    transcribe: String,
    keep: Duration,
    jobs: Mutex<HashMap<String, Job>>,
    /// The whole queue is paused; this file exists while it is.
    queue_paused: AtomicBool,
    wake: Notify,
    current: Mutex<Option<Current>>,
}

type Error = (StatusCode, String);

fn internal(e: impl Display) -> Error {
    (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
}
fn bad(m: &str) -> Error {
    (StatusCode::BAD_REQUEST, m.to_string())
}
fn conflict(m: &str) -> Error {
    (StatusCode::CONFLICT, m.to_string())
}
fn not_found() -> Error {
    (StatusCode::NOT_FOUND, "nu există".to_string())
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn new_id() -> String {
    use std::sync::atomic::AtomicU32;
    static N: AtomicU32 = AtomicU32::new(0);
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("{t:x}{:04x}", N.fetch_add(1, Ordering::Relaxed) & 0xffff)
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 40 && id.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Sends a signal to a process group we created.
fn signal_group(pid: u32, sig: libc::c_int) {
    // SAFETY: plain kill(2); the negative pid names the group.
    unsafe { libc::kill(-(pid as i32), sig) };
}

impl App {
    fn job_dir(&self, id: &str) -> PathBuf {
        self.dir.join(id)
    }

    fn paused_flag(&self) -> PathBuf {
        self.dir.with_file_name("queue-paused")
    }

    fn save(&self, job: &Job) {
        let path = self.job_dir(&job.id).join("job.json");
        let tmp = path.with_extension("json.tmp");
        let res = serde_json::to_vec(job)
            .map_err(std::io::Error::other)
            .and_then(|b| std::fs::write(&tmp, b))
            .and_then(|_| std::fs::rename(&tmp, &path));
        if let Err(e) = res {
            eprintln!("saving job {}: {e}", job.id);
        }
    }

    /// Change a job in place; false when it no longer exists (deleted).
    fn update(&self, id: &str, f: impl FnOnce(&mut Job)) -> bool {
        match self.jobs.lock().unwrap().get_mut(id) {
            Some(j) => {
                f(j);
                true
            }
            None => false,
        }
    }

    /// The pid of the running job, if `id` is it and transcribe has started.
    fn running_pid(&self, id: &str) -> Option<u32> {
        let cur = self.current.lock().unwrap();
        cur.as_ref().filter(|c| c.id == id).and_then(|c| c.pid)
    }

    /// Queued jobs that are not paused, first in line first.
    fn next_job(&self) -> Option<String> {
        let jobs = self.jobs.lock().unwrap();
        jobs.values()
            .filter(|j| j.status == Status::Queued && !j.paused)
            .min_by(|a, b| a.rank.total_cmp(&b.rank))
            .map(|j| j.id.clone())
    }
}

/// Jobs from disk. Folders without a readable job.json are uploads that never
/// finished and are removed; jobs that were queued or running go back in the
/// queue at the place they had.
fn load(dir: &FsPath) -> HashMap<String, Job> {
    let mut jobs = HashMap::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return jobs;
    };
    for e in entries.flatten() {
        let path = e.path();
        let id = e.file_name().to_string_lossy().into_owned();
        let job = std::fs::read(path.join("job.json"))
            .ok()
            .and_then(|b| serde_json::from_slice::<Job>(&b).ok());
        match job {
            Some(mut j) if j.id == id => {
                if j.rank == 0.0 {
                    j.rank = j.created;
                }
                if matches!(j.status, Status::Queued | Status::Running) {
                    j.status = Status::Queued;
                    j.progress = 0;
                    j.started = None;
                    j.paused_at = None;
                    j.paused_total = 0.0;
                    j.preview.clear();
                    j.stage = None;
                }
                jobs.insert(id, j);
            }
            _ => {
                let _ = std::fs::remove_dir_all(&path);
            }
        }
    }
    jobs
}

fn clean_name(n: &str) -> String {
    let base = n.rsplit(['/', '\\']).next().unwrap_or(n);
    let s: String = base.chars().filter(|c| !c.is_control()).take(200).collect();
    let s = s.trim();
    if s.is_empty() {
        "fisier".to_string()
    } else {
        s.to_string()
    }
}

/// The extension is only a hint, ffmpeg probes the content anyway.
fn ext_of(name: &str) -> String {
    match name.rsplit_once('.') {
        Some((_, e)) if (1..=8).contains(&e.len()) && e.bytes().all(|b| b.is_ascii_alphanumeric()) => {
            e.to_ascii_lowercase()
        }
        _ => "bin".to_string(),
    }
}

#[derive(Deserialize)]
struct UploadQuery {
    name: String,
    #[serde(default = "default_lang")]
    lang: String,
}
fn default_lang() -> String {
    "ro".to_string()
}

async fn upload(
    State(app): State<Arc<App>>,
    Query(q): Query<UploadQuery>,
    body: Body,
) -> Result<Json<Job>, Error> {
    if !LANGS.contains(&q.lang.as_str()) {
        return Err(bad("limbă necunoscută"));
    }
    let name = clean_name(&q.name);
    let id = new_id();
    let dir = app.job_dir(&id);
    tokio::fs::create_dir_all(&dir).await.map_err(internal)?;
    let input = format!("audio.{}", ext_of(&name));
    match receive(&dir.join(&input), body).await {
        Ok(size) if size > 0 => {
            let t = now();
            let job = Job {
                id: id.clone(),
                name,
                lang: q.lang,
                input,
                size,
                status: Status::Queued,
                progress: 0,
                created: t,
                rank: t,
                paused: false,
                started: None,
                finished: None,
                paused_at: None,
                paused_total: 0.0,
                preview: Vec::new(),
                error: None,
                stage: None,
                repaired: 0,
            };
            app.save(&job);
            app.jobs.lock().unwrap().insert(id, job.clone());
            app.wake.notify_one();
            Ok(Json(job))
        }
        Ok(_) => {
            let _ = tokio::fs::remove_dir_all(&dir).await;
            Err(bad("fișierul e gol"))
        }
        Err(e) => {
            let _ = tokio::fs::remove_dir_all(&dir).await;
            Err(internal(e))
        }
    }
}

async fn receive(path: &FsPath, body: Body) -> std::io::Result<u64> {
    let file = tokio::fs::File::create(path).await?;
    let mut out = tokio::io::BufWriter::with_capacity(1 << 20, file);
    let mut stream = body.into_data_stream();
    let mut n = 0u64;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(std::io::Error::other)?;
        n += chunk.len() as u64;
        out.write_all(&chunk).await?;
    }
    out.flush().await?;
    Ok(n)
}

#[derive(Serialize)]
struct Listing {
    paused: bool,
    now: f64,
    jobs: Vec<Job>,
}

async fn list(State(app): State<Arc<App>>) -> Json<Listing> {
    let mut jobs: Vec<Job> = app.jobs.lock().unwrap().values().cloned().collect();
    jobs.sort_by(|a, b| b.created.total_cmp(&a.created));
    Json(Listing {
        paused: app.queue_paused.load(Ordering::Relaxed),
        now: now(),
        jobs,
    })
}

async fn queue_pause(State(app): State<Arc<App>>) -> Result<StatusCode, Error> {
    std::fs::write(app.paused_flag(), b"").map_err(internal)?;
    app.queue_paused.store(true, Ordering::Relaxed);
    Ok(StatusCode::NO_CONTENT)
}

async fn queue_resume(State(app): State<Arc<App>>) -> Result<StatusCode, Error> {
    let _ = std::fs::remove_file(app.paused_flag());
    app.queue_paused.store(false, Ordering::Relaxed);
    app.wake.notify_one();
    Ok(StatusCode::NO_CONTENT)
}

fn status_of(app: &App, id: &str) -> Result<Status, Error> {
    if !valid_id(id) {
        return Err(not_found());
    }
    app.jobs.lock().unwrap().get(id).map(|j| j.status).ok_or_else(not_found)
}

async fn pause(State(app): State<Arc<App>>, Path(id): Path<String>) -> Result<StatusCode, Error> {
    match status_of(&app, &id)? {
        Status::Queued => {}
        Status::Running => {
            let pid = app.running_pid(&id).ok_or_else(|| conflict("încă pornește, încearcă iar"))?;
            signal_group(pid, libc::SIGSTOP);
        }
        _ => return Err(conflict("s-a terminat deja")),
    }
    app.update(&id, |j| {
        if !j.paused {
            j.paused = true;
            if j.status == Status::Running {
                j.paused_at = Some(now());
            }
            app.save(j);
        }
    });
    Ok(StatusCode::NO_CONTENT)
}

async fn resume(State(app): State<Arc<App>>, Path(id): Path<String>) -> Result<StatusCode, Error> {
    match status_of(&app, &id)? {
        Status::Queued => {}
        Status::Running => {
            let pid = app.running_pid(&id).ok_or_else(|| conflict("încă pornește, încearcă iar"))?;
            signal_group(pid, libc::SIGCONT);
        }
        _ => return Err(conflict("s-a terminat deja")),
    }
    app.update(&id, |j| {
        if j.paused {
            j.paused = false;
            if let Some(t) = j.paused_at.take() {
                j.paused_total += now() - t;
            }
            app.save(j);
        }
    });
    app.wake.notify_one();
    Ok(StatusCode::NO_CONTENT)
}

async fn retry(State(app): State<Arc<App>>, Path(id): Path<String>) -> Result<StatusCode, Error> {
    if !matches!(status_of(&app, &id)?, Status::Failed | Status::Done) {
        return Err(conflict("e deja în coadă"));
    }
    let mut jobs = app.jobs.lock().unwrap();
    let j = jobs.get_mut(&id).ok_or_else(not_found)?;
    if !app.job_dir(&id).join(&j.input).exists() {
        return Err(conflict("fișierul original nu mai există, încarcă-l din nou"));
    }
    j.status = Status::Queued;
    j.rank = now();
    j.paused = false;
    j.progress = 0;
    j.started = None;
    j.finished = None;
    j.paused_at = None;
    j.paused_total = 0.0;
    j.preview.clear();
    j.error = None;
    j.stage = None;
    j.repaired = 0;
    app.save(j);
    drop(jobs);
    app.wake.notify_one();
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct MoveQuery {
    to: String,
}

async fn move_job(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
    Query(q): Query<MoveQuery>,
) -> Result<StatusCode, Error> {
    if status_of(&app, &id)? != Status::Queued {
        return Err(conflict("doar fișierele din coadă se pot muta"));
    }
    let mut jobs = app.jobs.lock().unwrap();
    let mut line: Vec<(f64, String)> = jobs
        .values()
        .filter(|j| j.status == Status::Queued)
        .map(|j| (j.rank, j.id.clone()))
        .collect();
    line.sort_by(|a, b| a.0.total_cmp(&b.0));
    let i = line.iter().position(|(_, x)| *x == id).ok_or_else(not_found)?;
    let changes: Vec<(String, f64)> = match q.to.as_str() {
        "top" if i > 0 => vec![(id.clone(), line[0].0 - 1.0)],
        "up" if i > 0 => vec![(id.clone(), line[i - 1].0), (line[i - 1].1.clone(), line[i].0)],
        "down" if i + 1 < line.len() => {
            vec![(id.clone(), line[i + 1].0), (line[i + 1].1.clone(), line[i].0)]
        }
        "top" | "up" | "down" => Vec::new(),
        _ => return Err(bad("to=top|up|down")),
    };
    for (jid, rank) in changes {
        if let Some(j) = jobs.get_mut(&jid) {
            j.rank = rank;
            app.save(j);
        }
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn remove(State(app): State<Arc<App>>, Path(id): Path<String>) -> Result<StatusCode, Error> {
    if !valid_id(&id) {
        return Err(not_found());
    }
    let job = app.jobs.lock().unwrap().remove(&id).ok_or_else(not_found)?;
    if job.status == Status::Running {
        // The worker removes the folder once transcribe has stopped.
        let mut cur = app.current.lock().unwrap();
        if let Some(c) = cur.as_mut().filter(|c| c.id == id) {
            c.cancel.send_replace(true);
        }
    } else {
        let _ = tokio::fs::remove_dir_all(app.job_dir(&id)).await;
    }
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct DownloadQuery {
    inline: Option<String>,
}

async fn download(
    State(app): State<Arc<App>>,
    Path((id, ext)): Path<(String, String)>,
    Query(q): Query<DownloadQuery>,
) -> Result<Response, Error> {
    if !valid_id(&id) || !OUTPUTS.contains(&ext.as_str()) {
        return Err(not_found());
    }
    let name = {
        let jobs = app.jobs.lock().unwrap();
        let job = jobs.get(&id).ok_or_else(not_found)?;
        if job.status != Status::Done {
            return Err(not_found());
        }
        job.name.clone()
    };
    let data = tokio::fs::read(app.job_dir(&id).join(format!("audio.{ext}")))
        .await
        .map_err(|_| not_found())?;
    let stem = name.rsplit_once('.').map_or(name.as_str(), |(s, _)| s);
    let file = format!("{stem}.{ext}");
    let ctype = if ext == "vtt" { "text/vtt; charset=utf-8" } else { "text/plain; charset=utf-8" };
    let disposition = if q.inline.is_some() {
        "inline".to_string()
    } else {
        format!(
            "attachment; filename=\"{}\"; filename*=UTF-8''{}",
            ascii_fallback(&file),
            percent(&file)
        )
    };
    Ok((
        [
            (header::CONTENT_TYPE, ctype.to_string()),
            (header::CONTENT_DISPOSITION, disposition),
            (header::CACHE_CONTROL, "no-store".to_string()),
        ],
        data,
    )
        .into_response())
}

fn ascii_fallback(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_ascii_alphanumeric() || " .-_()".contains(c) { c } else { '_' })
        .collect()
}

fn percent(s: &str) -> String {
    s.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

/// Text of a segment line printed by whisper-cli: `[00:00.000 --> 00:04.000]  text`
fn segment_text(line: &str) -> Option<String> {
    let l = line.trim_start();
    if !l.starts_with('[') || !l.contains("-->") {
        return None;
    }
    let t = l.split_once(']')?.1.trim();
    (!t.is_empty()).then(|| t.to_string())
}

/// `whisper_print_progress_callback: progress =  42%`
fn progress_of(line: &str) -> Option<u8> {
    let i = line.find("progress =")?;
    line[i + "progress =".len()..].trim().trim_end_matches('%').trim().parse().ok()
}

/// Calls `f` with each line, decoded lossily so a stray byte cannot stop the
/// reader (and with it the pipe, and the process writing into it).
async fn each_line(r: impl AsyncRead + Unpin, mut f: impl FnMut(&str)) {
    let mut r = BufReader::new(r);
    let mut buf = Vec::new();
    loop {
        buf.clear();
        match r.read_until(b'\n', &mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(_) => f(String::from_utf8_lossy(&buf).trim_end()),
        }
    }
}

/// Live output of a run goes to the job's progress and preview; the repair
/// runs only report their stage.
#[derive(Clone, Copy, PartialEq)]
enum Report {
    Live,
    Quiet,
}

const CANCELLED: &str = "anulat";

/// Runs `transcribe` once and waits for it. `env` narrows it to a part of
/// the input or changes its settings (see modules/whisper.nix).
#[allow(clippy::too_many_arguments)]
async fn run_transcribe(
    app: &Arc<App>,
    id: &str,
    dir: &FsPath,
    input: &str,
    lang: &str,
    env: &[(&str, String)],
    report: Report,
    cancel: &mut watch::Receiver<bool>,
) -> Result<(), String> {
    if *cancel.borrow() {
        return Err(CANCELLED.to_string());
    }
    let mut cmd = Command::new(&app.transcribe);
    cmd.arg(dir.join(input))
        .arg(lang)
        .current_dir(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // Its own process group, so pause and cancel reach ffmpeg and
        // whisper-cli too and not only the shell script around them.
        .process_group(0)
        .kill_on_drop(true);
    for (k, v) in env {
        cmd.env(k, v);
    }
    let mut child = cmd.spawn().map_err(|e| format!("transcribe nu a pornit: {e}"))?;
    let pid = child.id();
    if let Some(c) = app.current.lock().unwrap().as_mut() {
        c.pid = pid;
    }
    // A pause that came while no process was running yet (between the
    // transcription and a repair) still holds.
    if let Some(pid) = pid {
        if app.jobs.lock().unwrap().get(id).is_some_and(|j| j.paused) {
            signal_group(pid, libc::SIGSTOP);
        }
    }

    let stdout = child.stdout.take().expect("piped stdout");
    let (a, i) = (app.clone(), id.to_string());
    let out_task = tokio::spawn(async move {
        each_line(stdout, |line| {
            if report == Report::Quiet {
                return;
            }
            if let Some(t) = segment_text(line) {
                a.update(&i, |j| {
                    j.preview.push(t);
                    let n = j.preview.len();
                    if n > PREVIEW_LINES {
                        j.preview.drain(..n - PREVIEW_LINES);
                    }
                });
            }
        })
        .await
    });

    let stderr = child.stderr.take().expect("piped stderr");
    let (a, i) = (app.clone(), id.to_string());
    let err_task = tokio::spawn(async move {
        let mut tail = VecDeque::new();
        each_line(stderr, |line| {
            if let Some(p) = progress_of(line) {
                if report == Report::Live {
                    a.update(&i, |j| j.progress = p.min(98));
                }
            } else if !line.trim().is_empty() {
                tail.push_back(line.to_string());
                if tail.len() > ERROR_LINES {
                    tail.pop_front();
                }
            }
        })
        .await;
        tail
    });

    let status = tokio::select! {
        s = child.wait() => s.map_err(|e| e.to_string())?,
        Ok(()) = async { cancel.wait_for(|stop| *stop).await.map(|_| ()) } => {
            if let Some(pid) = pid {
                // CONT as well: a stopped process only acts on TERM once it runs.
                signal_group(pid, libc::SIGTERM);
                signal_group(pid, libc::SIGCONT);
            }
            let _ = child.wait().await;
            return Err(CANCELLED.to_string());
        }
    };
    if let Some(c) = app.current.lock().unwrap().as_mut() {
        c.pid = None;
    }
    let _ = out_task.await;
    let tail = err_task.await.unwrap_or_default();

    if status.success() {
        Ok(())
    } else if tail.is_empty() {
        Err(format!("transcribe a ieșit cu {status}"))
    } else {
        Err(Vec::from(tail).join("\n"))
    }
}

// ---------------------------------------------------------------------------
// Repair of loops and invented text
// ---------------------------------------------------------------------------
//
// Over silence, noise or a break in a lecture, Whisper has nothing to go on
// but the text before it, and it falls back on what its training data (a lot
// of YouTube subtitles) puts there: "don't forget to like and subscribe",
// "thanks for watching", the subtitler's credit. Because each 30 s window is
// primed with the previous one, one such sentence then repeats itself for
// minutes. So after the transcription every passage that is a run of the
// same segment, or one of those sentences, is transcribed again on its own
// and without the previous text as a prompt, which is what breaks the loop.
// Whatever is still invented the second time is dropped, and a passage with
// nothing left becomes "[pasaj neclar]" so the gap stays visible.

/// Sentences Whisper invents, lower case, as they appear in its output.
const INVENTED: &[&str] = &[
    "dați like", "dati like", "lăsați un comentariu", "lasati un comentariu",
    "abonați-vă", "abonati-va", "abonează-te", "aboneaza-te", "vă abonați",
    "distribuiți acest material", "mulțumesc pentru vizionare", "mulțumim pentru vizionare",
    "vă mulțumesc pentru vizionare", "subtitrare realizată", "subtitrarea", "traducerea și adaptarea",
    "thanks for watching", "thank you for watching", "please subscribe", "like and subscribe",
    "don't forget to subscribe", "subtitles by", "amara.org",
    "продолжение следует", "субтитры", "спасибо за просмотр", "подписывайтесь",
    "untertitel", "sous-titres", "sottotitoli",
];
/// This many identical segments in a row are a loop, not speech.
const LOOP_RUN: usize = 3;
/// At most this many passages are transcribed again per file.
const MAX_REPAIRS: usize = 40;
const UNCLEAR: &str = "[pasaj neclar]";

#[derive(Clone, Debug, PartialEq)]
struct Seg {
    start: f64,
    end: f64,
    text: String,
}

fn invented(text: &str) -> bool {
    let t = text.to_lowercase();
    INVENTED.iter().any(|p| t.contains(p))
}

/// Text reduced to letters and digits, for comparing segments.
fn norm(text: &str) -> String {
    text.to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// `00:25:41,900` or `00:25:41.900` in seconds.
fn parse_ts(s: &str) -> Option<f64> {
    let s = s.trim().replace(',', ".");
    let mut parts = s.rsplitn(3, ':');
    let sec: f64 = parts.next()?.parse().ok()?;
    let min: f64 = parts.next()?.parse().ok()?;
    let hour: f64 = parts.next().map_or(Some(0.0), |h| h.parse().ok())?;
    Some(hour * 3600.0 + min * 60.0 + sec)
}

fn fmt_ts(t: f64, sep: char) -> String {
    let ms = (t.max(0.0) * 1000.0).round() as u64;
    format!("{:02}:{:02}:{:02}{sep}{:03}", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
}

fn parse_srt(s: &str) -> Vec<Seg> {
    let mut segs = Vec::new();
    for block in s.replace("\r\n", "\n").split("\n\n") {
        let mut lines = block.lines().skip_while(|l| !l.contains("-->"));
        let Some(times) = lines.next() else { continue };
        let Some((a, b)) = times.split_once("-->") else { continue };
        let (Some(start), Some(end)) = (parse_ts(a), parse_ts(b)) else { continue };
        let text = lines.collect::<Vec<_>>().join(" ").trim().to_string();
        segs.push(Seg { start, end, text });
    }
    segs
}

/// Index ranges (inclusive) of the passages to transcribe again.
fn suspicious(segs: &[Seg]) -> Vec<(usize, usize)> {
    let mut bad = vec![false; segs.len()];
    let mut i = 0;
    while i < segs.len() {
        let n = norm(&segs[i].text);
        let mut j = i;
        while j + 1 < segs.len() && !n.is_empty() && norm(&segs[j + 1].text) == n {
            j += 1;
        }
        if j + 1 - i >= LOOP_RUN {
            bad[i..=j].iter_mut().for_each(|b| *b = true);
        }
        i = j + 1;
    }
    for (b, s) in bad.iter_mut().zip(segs) {
        *b |= invented(&s.text);
    }
    let mut ranges: Vec<(usize, usize)> = Vec::new();
    for (k, &b) in bad.iter().enumerate() {
        if !b {
            continue;
        }
        match ranges.last_mut() {
            // Neighbours (or one good segment between two bad ones) are one passage.
            Some((_, end)) if k <= *end + 2 => *end = k,
            _ => ranges.push((k, k)),
        }
    }
    ranges
}

/// The repaired text of a passage: no invented sentences, no repeats.
fn clean(segs: Vec<Seg>) -> Vec<Seg> {
    let mut out: Vec<Seg> = Vec::new();
    for s in segs {
        if s.text.is_empty() || invented(&s.text) {
            continue;
        }
        if out.last().is_some_and(|p| norm(&p.text) == norm(&s.text)) {
            continue;
        }
        out.push(s);
    }
    out
}

/// Writes audio.txt/.srt/.vtt the way whisper-cli does.
fn write_outputs(dir: &FsPath, segs: &[Seg]) -> std::io::Result<()> {
    let mut txt = String::new();
    let mut srt = String::new();
    let mut vtt = String::from("WEBVTT\n\n");
    for (i, s) in segs.iter().enumerate() {
        txt.push_str(&format!(" {}\n", s.text));
        srt.push_str(&format!("{}\n{} --> {}\n {}\n\n", i + 1, fmt_ts(s.start, ','), fmt_ts(s.end, ','), s.text));
        vtt.push_str(&format!("{} --> {}\n {}\n\n", fmt_ts(s.start, '.'), fmt_ts(s.end, '.'), s.text));
    }
    for (ext, body) in [("txt", txt), ("srt", srt), ("vtt", vtt)] {
        let path = dir.join(format!("audio.{ext}"));
        let tmp = dir.join(format!("audio.{ext}.tmp"));
        std::fs::write(&tmp, body)?;
        std::fs::rename(&tmp, &path)?;
    }
    Ok(())
}

/// Finds loops and invented text in the finished transcript and transcribes
/// those passages again. Returns how many were repaired; only a cancel is
/// an error, a repair that does not work leaves the transcript as it was.
async fn repair(
    app: &Arc<App>,
    id: &str,
    dir: &FsPath,
    input: &str,
    lang: &str,
    cancel: &mut watch::Receiver<bool>,
) -> Result<u32, String> {
    let Ok(srt) = tokio::fs::read_to_string(dir.join("audio.srt")).await else {
        return Ok(0);
    };
    let segs = parse_srt(&srt);
    let ranges: Vec<(usize, usize)> = suspicious(&segs).into_iter().take(MAX_REPAIRS).collect();
    if ranges.is_empty() {
        return Ok(0);
    }

    let total = ranges.len();
    let mut out: Vec<Seg> = Vec::with_capacity(segs.len());
    let mut next = 0;
    for (k, &(i, j)) in ranges.iter().enumerate() {
        out.extend_from_slice(&segs[next..i]);
        next = j + 1;
        // From the end of the last good segment to the start of the next
        // one, so the speech that the loop covered is all in it.
        let start = if i > 0 { segs[i - 1].end } else { 0.0 };
        let end = segs.get(j + 1).map_or(segs[j].end, |s| s.start).max(start + 1.0);
        app.update(id, |job| {
            job.stage = Some(format!("Repar pasajul {}/{} ({})", k + 1, total, &fmt_ts(start, '.')[..8]));
        });

        let prefix = dir.join(format!("repair-{k}"));
        let env = [
            ("WHISPER_START", format!("{start:.3}")),
            ("WHISPER_LENGTH", format!("{:.3}", end - start)),
            ("WHISPER_CONTEXT", "0".to_string()),
            ("WHISPER_OUT", prefix.display().to_string()),
        ];
        let result = run_transcribe(app, id, dir, input, lang, &env, Report::Quiet, cancel).await;
        let srt_path = prefix.with_extension("srt");
        let redone = match result {
            Err(e) if e == CANCELLED => return Err(e),
            Err(e) => {
                eprintln!("job {id}: repairing {start:.0}-{end:.0} s failed: {e}");
                None
            }
            Ok(()) => tokio::fs::read_to_string(&srt_path).await.ok().map(|s| {
                parse_srt(&s)
                    .into_iter()
                    .map(|s| Seg { start: s.start + start, end: (s.end + start).min(end), text: s.text })
                    .collect::<Vec<_>>()
            }),
        };
        for ext in ["txt", "srt", "vtt"] {
            let _ = tokio::fs::remove_file(prefix.with_extension(ext)).await;
        }
        match redone.map(clean) {
            Some(new) if !new.is_empty() => out.extend(new),
            Some(_) => out.push(Seg { start, end, text: UNCLEAR.to_string() }),
            // The rerun itself failed: keep what was there, minus the loop.
            None => out.extend(clean(segs[i..=j].to_vec())),
        }
    }
    out.extend_from_slice(&segs[next..]);

    if let Err(e) = write_outputs(dir, &out) {
        eprintln!("job {id}: writing the repaired transcript: {e}");
        return Ok(0);
    }
    Ok(total as u32)
}

async fn worker(app: Arc<App>) {
    loop {
        let next = if app.queue_paused.load(Ordering::Relaxed) { None } else { app.next_job() };
        let Some(id) = next else {
            // Every change that can start a job calls notify_one, whose
            // permit is kept if nobody waits yet, so no wakeup is lost.
            app.wake.notified().await;
            continue;
        };

        // `current` is filled before the job is marked running, so a delete
        // that sees "running" always finds a way to stop it.
        let (tx, mut cancel) = watch::channel(false);
        *app.current.lock().unwrap() = Some(Current { id: id.clone(), pid: None, cancel: tx });
        let started = {
            let mut jobs = app.jobs.lock().unwrap();
            match jobs.get_mut(&id) {
                Some(j) if j.status == Status::Queued && !j.paused => {
                    j.status = Status::Running;
                    j.started = Some(now());
                    j.progress = 0;
                    app.save(j);
                    Some((j.input.clone(), j.lang.clone()))
                }
                _ => None,
            }
        };
        let Some((input, lang)) = started else {
            *app.current.lock().unwrap() = None;
            continue;
        };

        let dir = app.job_dir(&id);
        let outcome = async {
            run_transcribe(&app, &id, &dir, &input, &lang, &[], Report::Live, &mut cancel).await?;
            if !dir.join("audio.txt").exists() {
                return Err("transcribe nu a scris niciun text".to_string());
            }
            app.update(&id, |j| {
                j.progress = 99;
                j.stage = Some("Verific dacă s-a blocat pe repetiții…".to_string());
            });
            repair(&app, &id, &dir, &input, &lang, &mut cancel).await
        }
        .await;
        *app.current.lock().unwrap() = None;

        let kept = app.update(&id, |j| {
            j.finished = Some(now());
            j.paused = false;
            j.stage = None;
            if let Some(t) = j.paused_at.take() {
                j.paused_total += now() - t;
            }
            match &outcome {
                Ok(repaired) => {
                    j.status = Status::Done;
                    j.progress = 100;
                    j.repaired = *repaired;
                }
                Err(e) => {
                    j.status = Status::Failed;
                    j.error = Some(e.clone());
                }
            }
            app.save(j);
        });
        // The recording stays until the job is deleted (by hand or after
        // KEEP_DAYS), so a transcript can be redone.
        if !kept {
            let _ = tokio::fs::remove_dir_all(&dir).await;
        }
    }
}

async fn janitor(app: Arc<App>) {
    let mut tick = tokio::time::interval(Duration::from_secs(3600));
    loop {
        tick.tick().await;
        let cutoff = now() - app.keep.as_secs_f64();
        let old: Vec<String> = {
            let mut jobs = app.jobs.lock().unwrap();
            let ids: Vec<String> = jobs
                .values()
                .filter(|j| matches!(j.status, Status::Done | Status::Failed))
                .filter(|j| j.finished.unwrap_or(j.created) < cutoff)
                .map(|j| j.id.clone())
                .collect();
            for id in &ids {
                jobs.remove(id);
            }
            ids
        };
        for id in old {
            let _ = tokio::fs::remove_dir_all(app.job_dir(&id)).await;
        }
    }
}

#[tokio::main]
async fn main() {
    let env = |k: &str, d: &str| std::env::var(k).unwrap_or_else(|_| d.to_string());
    let dir = PathBuf::from(env("STATE_DIRECTORY", "/var/lib/whisper-web")).join("jobs");
    std::fs::create_dir_all(&dir).unwrap_or_else(|e| panic!("{}: {e}", dir.display()));
    let listen = env("LISTEN", "[::]:8091");
    let keep_days = env("KEEP_DAYS", "7").parse::<f64>().unwrap_or(7.0).max(0.0);

    let jobs = load(&dir);
    let app = Arc::new(App {
        queue_paused: AtomicBool::new(dir.with_file_name("queue-paused").exists()),
        dir,
        transcribe: env("TRANSCRIBE", "transcribe"),
        keep: Duration::from_secs_f64(keep_days * 86400.0),
        jobs: Mutex::new(jobs),
        wake: Notify::new(),
        current: Mutex::new(None),
    });
    for j in app.jobs.lock().unwrap().values() {
        if j.status == Status::Queued {
            app.save(j);
        }
    }
    tokio::spawn(worker(app.clone()));
    if keep_days > 0.0 {
        tokio::spawn(janitor(app.clone()));
    }

    let router = Router::new()
        .route("/", get(|| async { Html(INDEX) }))
        .route("/api/jobs", get(list))
        .route("/api/queue/pause", post(queue_pause))
        .route("/api/queue/resume", post(queue_resume))
        .route("/api/jobs/{id}", delete(remove))
        .route("/api/jobs/{id}/pause", post(pause))
        .route("/api/jobs/{id}/resume", post(resume))
        .route("/api/jobs/{id}/retry", post(retry))
        .route("/api/jobs/{id}/move", post(move_job))
        .route("/api/upload", post(upload))
        .route("/dl/{id}/{ext}", get(download))
        .layer(DefaultBodyLimit::disable())
        .with_state(app);

    let listener = tokio::net::TcpListener::bind(&listen)
        .await
        .unwrap_or_else(|e| panic!("listen on {listen}: {e}"));
    eprintln!("whisper-web listening on {listen}");
    axum::serve(listener, router).await.expect("server");
}

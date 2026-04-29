use std::path::PathBuf;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::process::{Child, Command};
use tokio::sync::mpsc;

#[derive(Debug, serde::Deserialize)]
pub struct Frame {
    #[serde(default)]
    pub event: Option<String>,
    #[serde(default)]
    pub reply_to: Option<String>,
    #[serde(default)]
    pub ok: Option<bool>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub ts: Option<u128>,
    #[serde(flatten)]
    pub other: serde_json::Map<String, serde_json::Value>,
}

pub struct App {
    child: Child,
    events: mpsc::UnboundedReceiver<Frame>,
    sock_writer: tokio::net::tcp::OwnedWriteHalf,
    next_id: u64,
}

impl App {
    /// Locate the app binary. `CARGO_BIN_EXE_<name>` is only set for tests
    /// of the SAME crate that owns the binary — useless cross-crate. Walk
    /// up from the current test executable instead: cargo runs tests at
    /// `target/<profile>/deps/<test>-<hash>`, so `target/<profile>/` is
    /// two pops up, and the app binary lives there.
    pub fn binary_path() -> PathBuf {
        let mut p = std::env::current_exe().expect("current_exe must succeed");
        p.pop(); // drop test binary name
        if p.ends_with("deps") {
            p.pop();
        } // target/<profile>/deps -> target/<profile>
        p.push(if cfg!(windows) {
            "video-coach-app.exe"
        } else {
            "video-coach-app"
        });
        p
    }

    pub async fn launch() -> anyhow::Result<Self> {
        let mut cmd = Command::new(Self::binary_path());
        cmd.arg("--json-logs").arg("--control-socket").arg("0");
        cmd.stdout(Stdio::piped()).stderr(Stdio::null());
        let mut child = cmd.spawn()?;

        let stdout = child.stdout.take().expect("piped stdout");
        let mut lines = BufReader::new(stdout).lines();

        // Drain stdout looking for the control_socket.ready event.
        let mut port: Option<u16> = None;
        while let Some(line) = lines.next_line().await? {
            let v: serde_json::Value = serde_json::from_str(&line)?;
            if v["fields"]["event"] == "control_socket.ready" {
                let addr = v["fields"]["addr"].as_str().unwrap_or("");
                port = addr.rsplit(':').next().and_then(|s| s.parse().ok());
                break;
            }
        }
        let port = port.ok_or_else(|| anyhow::anyhow!("never saw control_socket.ready"))?;

        let stream = TcpStream::connect(("127.0.0.1", port)).await?;
        let (read_half, write_half) = stream.into_split();

        let (event_tx, event_rx) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            let mut sock_lines = BufReader::new(read_half).lines();
            while let Ok(Some(line)) = sock_lines.next_line().await {
                if let Ok(frame) = serde_json::from_str::<Frame>(&line) {
                    let _ = event_tx.send(frame);
                }
            }
        });

        Ok(Self {
            child,
            events: event_rx,
            sock_writer: write_half,
            next_id: 0,
        })
    }

    pub async fn send(&mut self, cmd: serde_json::Value) -> anyhow::Result<Frame> {
        self.next_id += 1;
        let id = self.next_id.to_string();
        let mut frame = cmd;
        frame
            .as_object_mut()
            .unwrap()
            .insert("id".into(), id.clone().into());
        let line = serde_json::to_string(&frame)?;
        self.sock_writer.write_all(line.as_bytes()).await?;
        self.sock_writer.write_all(b"\n").await?;
        loop {
            let f = self
                .events
                .recv()
                .await
                .ok_or_else(|| anyhow::anyhow!("event channel closed"))?;
            if f.reply_to.as_deref() == Some(&id) {
                return Ok(f);
            }
        }
    }

    pub async fn next_event(&mut self) -> Option<Frame> {
        self.events.recv().await
    }

    pub async fn wait_for_event(
        &mut self,
        name: &str,
        timeout: std::time::Duration,
    ) -> anyhow::Result<Frame> {
        tokio::time::timeout(timeout, async {
            loop {
                let f = self
                    .events
                    .recv()
                    .await
                    .ok_or_else(|| anyhow::anyhow!("channel closed"))?;
                if f.event.as_deref() == Some(name) {
                    return Ok(f);
                }
            }
        })
        .await?
    }

    pub async fn quit(mut self) -> anyhow::Result<std::process::ExitStatus> {
        let _ = self.send(serde_json::json!({"cmd": "quit"})).await;
        Ok(self.child.wait().await?)
    }
}

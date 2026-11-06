# OmniGet in Docker

OmniGet is a Tauri 2 **desktop** application: the Svelte frontend talks to Rust
over Tauri IPC, so there is no web build that can be served by nginx. To run it
on a server we start the real app inside a virtual X display and expose that
display through noVNC. The result is the complete application, used from a
browser tab.

```
browser ──HTTPS──► reverse proxy ──► :6080 noVNC ──► x11vnc ──► Xvfb :99 ──► OmniGet (WebKitGTK)
```

Two images are published by `.github/workflows/docker.yml`:

| Image | Purpose | Size (approx.) |
| --- | --- | --- |
| `ghcr.io/<owner>/omniget` | Full desktop app over noVNC (`:6080`) | 1.4–1.8 GB |
| `ghcr.io/<owner>/omniget-cli` | Headless `omniget-cli` for automation/cron | 400–600 MB |

Both are `linux/amd64`.

## Quick start (Docker Compose)

```bash
cp docker/env.example .env      # then edit VNC_PASSWORD
docker compose up -d
```

Open <http://localhost:6080/vnc.html?autoconnect=1&resize=scale> and type the
`VNC_PASSWORD` you set in `.env`. `http://localhost:6080/` redirects there.

Without Compose:

```bash
docker run -d --name omniget \
  -p 6080:6080 \
  -e VNC_PASSWORD=change-me \
  -v omniget-data:/data \
  -v omniget-downloads:/home/omniget/Downloads \
  --shm-size=1g \
  ghcr.io/<owner>/omniget:latest
```

CLI:

```bash
docker run --rm -it \
  -v omniget-data:/data \
  -v "$PWD/downloads:/downloads" \
  ghcr.io/<owner>/omniget-cli:latest info "https://www.youtube.com/watch?v=..."
```

## Volumes

| Path | Contents |
| --- | --- |
| `/data` | `settings.json`, cookies, SQLite DBs, plugins, managed `yt-dlp` |
| `/home/omniget/Downloads` | Downloaded media (the app's default output dir) |

Both must survive container replacement; the named volumes in
`docker-compose.yml` do that. The optional `filebrowser` sidecar shares the
downloads volume at `/srv` so files can be fetched without the desktop UI.

## Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `OMNIGET_DATA_DIR` | `/data` | App profile directory (settings, cookies, plugins) |
| `VNC_PASSWORD` | `omniget` | Password for x11vnc/noVNC — **change it** |
| `RESOLUTION` | `1440x900x24` | Virtual screen geometry |
| `WEB_PORT` | `6080` | noVNC/websockify listen port |
| `VNC_PORT` | `5900` | x11vnc port (bound to 127.0.0.1 only) |
| `TZ` | container default | Timezone passed to the app |
| `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS` | `1` | Required in containers without user namespaces |

MediaForge-style variables (`APP_PORT`, `API_KEY`, `MAX_CONCURRENT_JOBS`,
`AI_ENGINE_URL`, `S3_*`, `NVIDIA_RIVA_*`, `RATE_LIMIT_*`) are **not** read by
OmniGet. The app has no HTTP API, no S3 uploader and no Riva integration. AI
keys (Gemini/OpenAI/…) are entered in **Settings → AI** and stored inside
`/data/tools/ai-keys.json`. Download concurrency lives in
`settings.json → download.max_concurrent_downloads` (default 2).

## Build locally

```bash
docker build -f docker/Dockerfile.desktop -t omniget .
docker build -f docker/Dockerfile.cli     -t omniget-cli .
```

The Rust stage is heavy (the workspace includes torrents, Telegram, courses and
image/PDF tooling); allow 20–45 minutes for the first build and keep BuildKit
cache mounts enabled (they are in the Dockerfile).

## GitHub Actions → GHCR

`.github/workflows/docker.yml` runs on pushes to `main`, on version tags, on a
weekly schedule and on demand. It authenticates with the repository's own
`GITHUB_TOKEN` — no personal access token is needed or stored.

After the first successful run, open the package on GitHub and set its
visibility to **Public** (Package settings → Change visibility) if you want
server deployments to pull it without registry credentials. For a private
package, create a token with only `read:packages` and register it in your
hosting panel.

## EasyPanel

1. **Fork** `OpenSelena/omniget`, push this branch, wait for the workflow, then
   make both GHCR packages public (or add `ghcr.io` credentials).
2. **Create → App**:
   - Source: *Docker Image* → `ghcr.io/<owner>/omniget:latest`
   - Port: `6080` (HTTP)
   - Domain: e.g. `omniget.example.com`, HTTPS on (Let's Encrypt), **Basic
     Auth on** — the VNC password is the second lock, not the only one.
   - Mounts: volume → `/data`, volume → `/home/omniget/Downloads`
   - Environment: `OMNIGET_DATA_DIR=/data`, `VNC_PASSWORD=…`,
     `RESOLUTION=1440x900x24`, `TZ=Africa/Cairo`,
     `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1`
   - Resources: at least **2 vCPU / 2 GB RAM**
   - Healthcheck: HTTP `GET /` on port `6080`, start period 90 s
   - Restart policy: `unless-stopped`
3. Open `https://your-domain/` → noVNC login → OmniGet onboarding.
4. *(Optional)* second app from `filebrowser/filebrowser:latest`, same
   downloads volume mounted at `/srv`, port `80`, basic auth on the domain.
   First login is `admin` / `adminadmin`; change it with:

   ```bash
   docker compose exec files filebrowser -d /database/filebrowser.db \
     users update admin --password 'new-strong-password'
   ```

> EasyPanel apps do not expose `shm_size`. If WebKit runs out of shared memory
> (`/dev/shm` too small), deploy `docker-compose.yml` as an EasyPanel **Compose**
> service instead — it sets `shm_size: 1gb`.

## Updating

- Rebuild is automatic on every push/schedule; servers only need to pull the
  new `:latest`.
- The app's own updater cannot replace the container binary; rebuild the image
  instead.
- Keep `/data` across updates — settings, cookies and login sessions live there.

## Limitations

- **No audio** over noVNC. Downloads are unaffected; in-app playback is silent.
- **No GPU**: WebKit renders in software, so CPU matters more than usual.
- **Single user**: this is a desktop session, not multi-tenant. Everyone who
  opens the domain sees the same window. Protect it with HTTPS, Basic Auth and
  a strong VNC password.
- **Browser extension bridge** (`127.0.0.1:47720–47729`) stays inside the
  container and is not reachable from outside.
- Telegram QR login and course webview logins work through the virtual display;
  cookies persist in `/data`.
- Downloaded files live on the server: schedule cleanup and watch disk usage.

## Security

- Never bake API keys into the image. Enter them in-app (they stay in `/data`)
  or mount a pre-seeded `ai-keys.json`.
- The image runs the app as UID 1000 (`omniget`), not root.
- x11vnc listens on `127.0.0.1` only; the only exposed port is noVNC (`6080`).
- Rotate `VNC_PASSWORD` and any panel Basic Auth credentials if they leak.

## License

OmniGet is GPL-3.0. If you distribute a modified image, publish the modified
source as well.
# VPS one-time setup for the Build & Deploy workflow

The `Build and Deploy` GitHub Actions workflow (`.github/workflows/build-and-deploy.yml`)
builds Docker images for the Rails app and the Go renderer, pushes them to GHCR,
SSHes into the VPS, and runs `docker compose -f docker-compose.vps.yml pull && up -d`.

This document covers the one-time VPS-side preparation. Do these steps once.

## 1. Create a deploy user

```bash
sudo adduser --disabled-password --gecos "" deploy
sudo usermod -aG docker deploy
sudo mkdir -p /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
sudo chown -R deploy:deploy /home/deploy/.ssh
```

## 2. SSH key for GitHub Actions → VPS

On your laptop:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/fraktur_deploy -N ""
ssh-copy-id -i ~/.ssh/fraktur_deploy.pub deploy@YOUR_VPS_HOST
```

Copy the **private** key (`~/.ssh/fraktur_deploy`) into the GitHub repo:
**Settings → Secrets and variables → Actions → New repository secret**

| Secret | Value |
|---|---|
| `VPS_HOST` | the VPS hostname or IP |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | contents of `~/.ssh/fraktur_deploy` (the private key) |

## 3. Postgres

Postgres runs as a container in `docker-compose.vps.yml` (service `postgres`,
named volume `postgres_data`). No host-side Postgres setup is required —
just make sure no native Postgres is bound to port 5432, or the container
won't be reachable cross-network. (We don't expose 5432 to the host, so the
two can technically coexist, but it's cleaner to disable any native Postgres
service: `sudo systemctl disable --now postgresql` if installed.)

## 4. Deploy directory and `.env` on the VPS

```bash
sudo mkdir -p /srv/fraktur_ocr
sudo chown deploy:deploy /srv/fraktur_ocr
sudo -u deploy bash <<'EOF'
cd /srv/fraktur_ocr
mkdir -p storage log
EOF
```

Place `docker-compose.vps.yml` (committed in the repo) on the VPS:

```bash
sudo -u deploy curl -L \
  https://raw.githubusercontent.com/YOUR_OWNER/YOUR_REPO/main/docker-compose.vps.yml \
  -o /srv/fraktur_ocr/docker-compose.vps.yml
```

Create `/srv/fraktur_ocr/.env` (substitute real values, **never commit this**):

```env
GHCR_OWNER=your_lowercase_github_owner
IMAGE_TAG=latest

RAILS_MASTER_KEY=copy_from_config_master_key
RAILS_HOSTNAME=fraktur.example.com
RAILS_MAX_THREADS=5

POSTGRES_USER=fraktur
POSTGRES_PASSWORD=THE_LONG_PASSWORD_FROM_STEP_3
POSTGRES_DB=fraktur_ocr_production

INTERNAL_AUTH_SECRET=GENERATE_WITH_OPENSSL_RAND_HEX_32

HOST_PORT=3000
```

`chmod 600 /srv/fraktur_ocr/.env`.

## 5. GHCR pull authentication on the VPS

If your GHCR packages are **private** (default), the VPS needs a Personal Access Token to pull:

```bash
# In your GitHub UI: Settings → Developer settings → Personal access tokens
# → Tokens (classic) → Generate new token
# Scopes needed: read:packages
# Save it as e.g. ghp_xxxxx

sudo -u deploy bash <<'EOF'
echo "ghp_xxxxx" | docker login ghcr.io -u YOUR_GH_USERNAME --password-stdin
EOF
```

Credentials are stored in `/home/deploy/.docker/config.json` and persist across reboots.

If you'd rather skip this step, make the packages public after the first push:
**GitHub → your profile → Packages → fraktur_ocr/web → Package settings → Change visibility → Public** (and same for `render`). Public packages need no login.

## 6. First-time bootstrap

```bash
sudo -u deploy bash <<'EOF'
cd /srv/fraktur_ocr
docker compose -f docker-compose.vps.yml pull
docker compose -f docker-compose.vps.yml up -d
docker compose -f docker-compose.vps.yml exec -T web bin/rails db:migrate
EOF
```

After this initial boot, every `git push` to `main` will:
1. Run Ruby + Go tests on GitHub Actions.
2. Build and push two images to GHCR (`web`, `render`) tagged with the commit SHA and `latest`.
3. SSH into the VPS, pull the new images, recreate containers, run `db:migrate`, and prune old images.

## 7. nginx and TLS

Out of scope for this doc — see `nginx-fraktur-ocr.conf` in the repo. Make sure it points to `127.0.0.1:${HOST_PORT}` and that any `/internal/*` requests from outside loopback are blocked at the nginx layer.

## Troubleshooting

- **`could not connect to server` on first boot**: usually the `postgres` container hasn't finished its first init. Wait 20 s and `docker compose -f docker-compose.vps.yml up -d` again — the healthcheck will gate the others properly on subsequent boots.
- **`unauthorized` on `docker compose pull`**: GHCR auth (step 5). Run `docker login ghcr.io` again.
- **Workflow `deploy` step fails with permission denied**: SSH key isn't on the VPS, or wrong user. Test manually: `ssh -i ~/.ssh/fraktur_deploy deploy@VPS_HOST`.
- **Migration step fails**: usually a broken migration. SSH in, `docker compose -f docker-compose.vps.yml logs web`, fix locally, push again.

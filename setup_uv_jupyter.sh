#!/usr/bin/env bash
set -euo pipefail

# -------- Helpers --------
prompt_default() {
  local prompt="$1" default="$2" var
  read -rp "$prompt [$default]: " var
  echo "${var:-$default}"
}
log() { printf "\n\033[1;32m[+] %s\033[0m\n" "$*"; }
err() { printf "\n\033[1;31m[!] %s\033[0m\n" "$*"; }

SUDO=""; command -v sudo >/dev/null 2>&1 && SUDO="sudo"
export PATH="$HOME/.local/bin:$PATH"

# -------- Prompt for inputs (with defaults) --------
PROJECT_NAME=$(prompt_default "Project name" "my_project")
JUPYTER_PORT=$(prompt_default "Jupyter port" "5000")

# -------- 1) Install uv --------
log "Installing uv…"
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

# -------- 2) Install nano and tmux --------
log "Installing nano & tmux via apt…"
$SUDO apt update -y
$SUDO apt install -y nano tmux

# -------- 3) Create uv project --------
log "Creating uv project: ${PROJECT_NAME}"
uv init "${PROJECT_NAME}"
cd "${PROJECT_NAME}"

# -------- 4) Install Jupyter --------
log "Adding Jupyter packages with uv…"
uv add jupyter notebook
uv sync

# -------- 5) Activate env --------
log "Activating virtualenv…"
[[ -d ".venv" ]] || { uv venv; uv sync; }
# shellcheck disable=SC1091
source .venv/bin/activate

# Paths we’ll use explicitly from the venv
VENV_DIR="$PWD/.venv"
JUP_BIN="$VENV_DIR/bin/jupyter"
PY_BIN="$VENV_DIR/bin/python"

# -------- 6) Configure Jupyter for remote use --------
log "Generating and writing Jupyter config…"
"$JUP_BIN" notebook --generate-config >/dev/null 2>&1 || true
CONFIG="${HOME}/.jupyter/jupyter_notebook_config.py"
cat > "${CONFIG}" <<EOF
c = get_config()

# Modern Jupyter (ServerApp)
c.ServerApp.ip = '0.0.0.0'
c.ServerApp.port = ${JUPYTER_PORT}
c.ServerApp.open_browser = False
c.ServerApp.allow_remote_access = True
c.ServerApp.allow_origin = '*'

# Backward-compat (NotebookApp)
c.NotebookApp.ip = '0.0.0.0'
c.NotebookApp.port = ${JUPYTER_PORT}
c.NotebookApp.open_browser = False
c.NotebookApp.allow_remote_access = True
c.NotebookApp.allow_origin = '*'
EOF

# -------- 7) Launch Jupyter Lab inside tmux (robust) --------
SESSION="jupyter_${PROJECT_NAME}"
log "Starting Jupyter Lab in tmux session '${SESSION}' on port ${JUPYTER_PORT}…"
tmux has-session -t "${SESSION}" 2>/dev/null && tmux kill-session -t "${SESSION}" || true

# Use a login shell + cd + explicit venv jupyter to avoid PATH/CWD issues
tmux new-session -d -s "${SESSION}" \
  "bash -lc 'cd \"${PWD}\" && exec \"$JUP_BIN\" lab --port=${JUPYTER_PORT} --no-browser --allow-root'"

# -------- 8) Poll for server & print token (more flexible) --------
log "Fetching Jupyter server token…"

# A small helper to query server list from the same venv without relying on activation state
server_list() { "$JUP_BIN" server list 2>/dev/null || true; }

TOKEN_LINE=""
for i in $(seq 1 90); do
  # Accept either hostnames or localhost, both http/https, trailing spaces, etc.
  # Match the specific port anywhere on the line.
  TOKEN_LINE=$(server_list | awk -v p=":${JUPYTER_PORT}/" '$0 ~ p {print; exit}')
  if [[ -n "$TOKEN_LINE" ]]; then
    break
  fi
  sleep 1
done

TOKEN=""
if [[ -n "$TOKEN_LINE" ]]; then
  # Extract token if present
  TOKEN=$(printf "%s" "$TOKEN_LINE" | sed -n 's/.*token=\([^[:space:]]*\).*/\1/p')
fi

# -------- 9) Final info + diagnostics if needed --------
cat <<INFO

========================================================
✅ Setup complete.

Project:     ${PROJECT_NAME}
Directory:   $(pwd)
Virtualenv:  $(pwd)/.venv
Jupyter:     running in tmux session '${SESSION}' on port ${JUPYTER_PORT}

Attach to the session:
  tmux attach -t ${SESSION}

Set a password (optional, one-time):
  tmux new-window -t ${SESSION} -n setpass "$JUP_BIN lab password"

List running servers:
  tmux new-window -t ${SESSION} -n servers "$JUP_BIN server list"
  
SSH port-forward from your laptop:
  ssh -N -L ${JUPYTER_PORT}:localhost:${JUPYTER_PORT} user@your-server
========================================================
INFO

if [[ -n "$TOKEN_LINE" ]]; then
  echo "Server URL (raw):"
  echo "  $TOKEN_LINE"
  if [[ -n "$TOKEN" ]]; then
    echo
    echo "Open in browser after SSH port-forwarding:"
    echo "  http://localhost:${JUPYTER_PORT}/?token=${TOKEN}"
  fi
else
  err "Could not retrieve the Jupyter URL yet (port ${JUPYTER_PORT})."

  echo -e "\nDiagnostics:"
  echo "1) tmux sessions:"
  tmux ls || true

  echo -e "\n2) Last 80 lines from the Jupyter tmux pane:"
  # Capture last 80 lines from the first (index 0) pane of the session
  tmux capture-pane -t "${SESSION}:.+0" -p -S -80 || true

  echo -e "\n3) Manual checks you can run:"
  echo "   tmux attach -t ${SESSION}"
  echo "   $JUP_BIN server list"
fi

#!/usr/bin/env bash
# start_server.sh — launch the project headless with the web server up so the
# POST /mcp handler is reachable for curl tests. Seeds fixture data on startup.
#
#   ./start_server.sh            # runs in the foreground; Ctrl-C to stop
# Then in another shell:  ./run_curl_tests.sh
#
# Uses a throwaway data file under test/ so it never touches the project's Data.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$HERE/.." && pwd)/Project/4d-mcp-server.4DProject"
TOOL="${TOOL4D:-/Applications/tool4d.app/Contents/MacOS/tool4d}"
DATA="$HERE/_serverdata/data.4DD"

if [ ! -x "$TOOL" ]; then
  echo "tool4d not found at: $TOOL   (set TOOL4D=/path/to/tool4d)" >&2
  exit 1
fi

mkdir -p "$HERE/_serverdata"
echo "Starting 4D web server on http://localhost:8044/mcp ..."
exec "$TOOL" --project "$PROJECT" --opening-mode interpreted \
  --startup-method MCP_StartServer --data "$DATA" --create-data

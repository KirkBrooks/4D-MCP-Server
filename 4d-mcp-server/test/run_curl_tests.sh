#!/usr/bin/env bash
# run_curl_tests.sh — exercise every 4D Data MCP action over real HTTP.
#
# Half B in isolation: a Bearer token + JSON body, no MCP server required
# (wire contract §5). Start a live 4D first (see test/start_server.sh), then:
#   ./run_curl_tests.sh [BASE_URL]
# Default BASE_URL: http://localhost:8044/mcp
#
# Fixture tokens (see cs.MCP_Auth._loadTokens):
#   SECRET_FULL  read [Customer,Order] write [Order] call [ping,order_count]
#   SECRET_RO    read [Customer]       (no write, no call)

set -u
BASE="${1:-http://localhost:8044/mcp}"
FULL="SECRET_FULL"
RO="SECRET_RO"

pass=0; fail=0

# req <token> <json-body>  -> sets $HTTP (status) and $BODY (response text).
# Pass token "" to send no Authorization header.
req() {
  local token="$1" body="$2" resp
  if [ -z "$token" ]; then
    resp=$(curl -s -w $'\n%{http_code}' -X POST "$BASE" \
      -H 'Content-Type: application/json' --data "$body")
  else
    resp=$(curl -s -w $'\n%{http_code}' -X POST "$BASE" \
      -H 'Content-Type: application/json' -H "Authorization: Bearer $token" --data "$body")
  fi
  HTTP="${resp##*$'\n'}"
  BODY="${resp%$'\n'*}"
}

# jget <json-path> — extract a value from $BODY via python (e.g. env.ok, error.code).
jget() { python3 -c "import json,sys
try:
    d=json.loads(sys.argv[2])
    for p in sys.argv[1].split('.'):
        d = d[int(p)] if isinstance(d,list) else d[p]
    print(d)
except Exception:
    print('<none>')" "$1" "$BODY"; }

# check <name> <expected-http> <json-path> <expected-value>
check() {
  local name="$1" ehttp="$2" path="$3" eval="$4" got
  got=$(jget "$path")
  if [ "$HTTP" = "$ehttp" ] && [ "$got" = "$eval" ]; then
    printf '  PASS  %-34s http=%s %s=%s\n' "$name" "$HTTP" "$path" "$got"; pass=$((pass+1))
  else
    printf '  FAIL  %-34s http=%s (want %s)  %s=%s (want %s)\n' "$name" "$HTTP" "$ehttp" "$path" "$got" "$eval"
    printf '        body: %s\n' "$BODY"; fail=$((fail+1))
  fi
}

echo "Target: $BASE"
echo "--- happy paths (8 action invocations) ---"

# 1. get_schema_digest
req "$FULL" '{"v":1,"action":"get_schema_digest","params":{}}'
check "get_schema_digest" 200 "ok" "True"

# 2. query_entities (with placeholder binding)
req "$FULL" '{"v":1,"action":"query_entities","params":{"dataclass":"Customer","filter":"name = :1","params":["Acme Co"]}}'
check "query_entities.filter" 200 "meta.total" "1"

# 3. get_entity
req "$FULL" '{"v":1,"action":"get_entity","params":{"dataclass":"Customer","key":1}}'
check "get_entity" 200 "data.name" "Acme Co"

# 4. create_entity — capture new key
req "$FULL" '{"v":1,"action":"create_entity","params":{"dataclass":"Order","values":{"customerID":1,"total":42,"status":"new"}}}'
check "create_entity" 200 "data.created" "True"
NEWKEY=$(jget "data.key")
echo "        (new Order key = $NEWKEY)"

# 5. update_entity
req "$FULL" "{\"v\":1,\"action\":\"update_entity\",\"params\":{\"dataclass\":\"Order\",\"key\":$NEWKEY,\"values\":{\"total\":250}}}"
check "update_entity" 200 "data.updated" "True"

# 6. delete_entity
req "$FULL" "{\"v\":1,\"action\":\"delete_entity\",\"params\":{\"dataclass\":\"Order\",\"key\":$NEWKEY}}"
check "delete_entity" 200 "data.deleted" "True"

# 7. call_method (ping)
req "$FULL" '{"v":1,"action":"call_method","params":{"name":"ping","args":["hello"]}}'
check "call_method.ping" 200 "data.result.pong" "True"

# 8. call_method (order_count)
req "$FULL" '{"v":1,"action":"call_method","params":{"name":"order_count"}}'
check "call_method.order_count" 200 "data.name" "order_count"

echo "--- error taxonomy ---"

# AUTH_DENIED — no token
req "" '{"v":1,"action":"get_schema_digest","params":{}}'
check "AUTH_DENIED.no_token" 401 "error.code" "AUTH_DENIED"

# AUTH_DENIED — bad token
req "nope" '{"v":1,"action":"get_schema_digest","params":{}}'
check "AUTH_DENIED.bad_token" 401 "error.code" "AUTH_DENIED"

# CAP_DENIED — RO token reading Order
req "$RO" '{"v":1,"action":"query_entities","params":{"dataclass":"Order"}}'
check "CAP_DENIED.read" 403 "error.code" "CAP_DENIED"

# CAP_DENIED — FULL token writing Customer (write is Order-only)
req "$FULL" '{"v":1,"action":"create_entity","params":{"dataclass":"Customer","values":{"name":"x"}}}'
check "CAP_DENIED.write" 403 "error.code" "CAP_DENIED"

# CAP_DENIED — call action not in registry / token
req "$FULL" '{"v":1,"action":"call_method","params":{"name":"no_such_action"}}'
check "CAP_DENIED.call" 403 "error.code" "CAP_DENIED"

# BAD_VERSION
req "$FULL" '{"v":2,"action":"get_schema_digest","params":{}}'
check "BAD_VERSION" 400 "error.code" "BAD_VERSION"

# UNKNOWN_ACTION
req "$FULL" '{"v":1,"action":"frobnicate","params":{}}'
check "UNKNOWN_ACTION" 400 "error.code" "UNKNOWN_ACTION"

# BAD_PARAMS — missing dataclass
req "$FULL" '{"v":1,"action":"query_entities","params":{}}'
check "BAD_PARAMS" 400 "error.code" "BAD_PARAMS"

# NOT_FOUND — bad key
req "$FULL" '{"v":1,"action":"get_entity","params":{"dataclass":"Customer","key":999999}}'
check "NOT_FOUND" 404 "error.code" "NOT_FOUND"

echo "-------------------------------------------"
echo "PASSED: $pass   FAILED: $fail"
[ "$fail" -eq 0 ]

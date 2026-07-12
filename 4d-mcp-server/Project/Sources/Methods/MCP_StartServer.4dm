//%attributes = {"shared":true}
// MCP_StartServer — seed fixtures and start the web server so the POST /mcp
// handler is reachable for curl testing. The server stays up (no QUIT).
// Run with:  tool4d --project <..> --opening-mode interpreted \
//              --startup-method MCP_StartServer --create-data --data <path>
// Then:      curl http://localhost:8044/mcp ...   (see test/run_curl_tests.sh)

cs.MCP_Test.me.seedFixtures()

var $port : Integer
$port:=8044

WEB SET OPTION(Web port ID; $port)
WEB START SERVER

LOG EVENT(Into system standard outputs; "MCP server listening on http://localhost:"+String($port)+"/mcp"+Char(Line feed))

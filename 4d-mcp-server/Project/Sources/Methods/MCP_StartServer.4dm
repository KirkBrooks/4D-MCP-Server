//%attributes = {"shared":true}
// MCP_StartServer — standalone/test entry point: seed fixtures, then run the
// same startup a host database would (MCP_Initialize_Host). The server stays
// up (no QUIT). Port comes from HTTP_PORT in 4D-mcp-config.pref (8044).
// Run with:  tool4d --project <..> --opening-mode interpreted \
//              --startup-method MCP_StartServer --create-data --data <path>
// Then:      curl http://localhost:8044/mcp ...   (see test/run_curl_tests.sh)

If (Not(I_am_a_component))  // standalone dev/test run — never seed a host's datastore
	cs.MCP_Test.me.seedFixtures()
End if

var $status : Object
$status:=MCP_Initialize_Host

If (Not(Bool($status.success)))
	log_worker("MCP_StartServer failed: "+String($status.message)+Char(Line feed))
End if

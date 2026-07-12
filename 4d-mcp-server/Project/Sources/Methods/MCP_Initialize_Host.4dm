//%attributes = {"shared":true,"preemptive":"capable"}
/* Purpose: Call from the HOST database's startup to initialize the MCP component.
 ------------------
MCP_Initialize_Host () : Object   // {success; port; message}
 Created by: Kirk Brooks as Designer, Created: 07/11/26, 17:32:55

 1. Ensures the deployment config exists in the host's Project/Sources
    (getConfig copies the component's default there on first read).
 2. Starts the component's OWN web server (WebServer object) on HTTP_PORT,
    so the /mcp handler runs isolated from the host's web server.
    HTTP_PORT <= 0 skips the start — serve /mcp from the host's web
    server instead.
*/

#DECLARE : Object

var $config : Object
$config:=cs.MCP_Handler.me.getConfig()
If ($config=Null)
	// getConfig fails closed: missing/uncopyable default, unparseable JSON,
	// or a malformed {comment, value} entry. Say so at startup instead of
	// letting every request answer 500 INTERNAL.
	var $configPath : Text
	$configPath:=Folder(fk database folder; *).file("Project/Sources/4D-mcp-config.pref").platformPath
	log_worker("MCP init FAILED: config unavailable or malformed — check "+$configPath+Char(Line feed))
	return New object("success"; False; "port"; 0; "message"; "MCP config unavailable or malformed — check "+$configPath)
End if 

var $port : Integer
$port:=Num($config.HTTP_PORT)
If ($port<=0)
	log_worker("MCP init: HTTP_PORT<=0, component web server not started (serve /mcp from the host's web server)"+Char(Line feed))
	return New object("success"; True; "port"; 0; "message"; "HTTP_PORT<=0 — component web server not started")
End if 

var $webServer : 4D.WebServer
$webServer:=WEB Server  // this project's server: the component's own when embedded

If ($webServer.isRunning)
	return New object("success"; True; "port"; $port; "message"; "MCP web server already running")
End if 

var $status : Object
$status:=$webServer.start(New object("HTTPPort"; $port))

If (Bool($status.success))
	log_worker("MCP server listening on http://localhost:"+String($port)+"/mcp"+Char(Line feed))
	return New object("success"; True; "port"; $port; "message"; "MCP web server started")
End if 

var $reason : Text
$reason:=JSON Stringify($status.errors)
log_worker("MCP web server FAILED to start on port "+String($port)+": "+$reason+Char(Line feed))
return New object("success"; False; "port"; $port; "message"; $reason)

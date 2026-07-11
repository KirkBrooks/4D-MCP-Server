// MCP_Fixture_Ping — HOST fixture method exposed via METHOD_WHITELIST as "ping".
// Liveness check. Optional positional arg 1: text echoed back.
#DECLARE($echo : Text) : Object
var $out : Object
$out:=New object("pong"; True)
If (Count parameters>=1)
	$out.echo:=$echo
End if
return $out

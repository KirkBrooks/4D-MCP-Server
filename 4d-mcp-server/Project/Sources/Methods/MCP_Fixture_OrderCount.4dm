//%attributes = {"shared":true}
// MCP_Fixture_OrderCount — HOST fixture method exposed via METHOD_WHITELIST
// as "order_count". Optional positional arg 1: status text to filter by.
#DECLARE($status : Text) : Object
If (Count parameters>=1)
	return New object("count"; ds.Order.query("status = :1"; $status).length; "status"; $status)
End if
return New object("count"; ds.Order.all().length)

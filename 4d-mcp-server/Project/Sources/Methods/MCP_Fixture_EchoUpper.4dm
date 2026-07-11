// MCP_Fixture_EchoUpper — HOST fixture method exposed via METHOD_WHITELIST as
// "echo_upper". Required positional arg 1: text to uppercase. Exists so the
// tests can exercise required-arg and arg-type validation.
#DECLARE($text : Text) : Object
return New object("upper"; Uppercase($text))

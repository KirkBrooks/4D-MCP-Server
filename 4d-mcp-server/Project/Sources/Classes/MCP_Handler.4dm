// MCP_Handler — the single POST /mcp request handler (registered in
// HTTPHandlers.json). Requires 4D 20 R8+ (HTTP request handlers).
//
// dispatch() is the thin HTTP adapter: it pulls the Bearer token and JSON body
// off the request, delegates to handle(), and renders a 4D.OutgoingMessage.
// handle($token; $body) contains ALL the gate logic and is pure (token + body
// in, {status, env} out) so it can be unit-tested headless without HTTP
// (see the MCP_Test project method).
//
// Gate order (wire contract 2), exact:
//   1. token present & valid   -> AUTH_DENIED    (401)
//   2. v == 1                   -> BAD_VERSION    (400)
//   3. action known            -> UNKNOWN_ACTION (400)
//   4. params well-formed      -> BAD_PARAMS     (400)
//   5. capability for action   -> CAP_DENIED     (403)
//   6. execute                 -> success | NOT_FOUND | QUERY_ERROR | INTERNAL
//
// Envelopes (1): success {v,ok:true,data,meta?}; error {v,ok:false,error:{code,message}}.
// error carries code + message ONLY (no details, no retryable).

shared singleton Class constructor()

// =============================================================================
//  HTTP adapter
// =============================================================================
Function dispatch($request : 4D.IncomingMessage) : 4D.OutgoingMessage
	var $bodyText : Text
	$bodyText:=""
	Try
		$bodyText:=$request.getText()
	Catch
		$bodyText:=""
	End try
	var $body : Object
	$body:=Null
	if (Length($bodyText)>0)
		$body:=Try(JSON Parse($bodyText))
	end if

	var $result : Object
	$result:=This.handle(This._bearer($request); $body)
	return This._respond($result.status; $result.env)

// =============================================================================
//  Pure gate chain — returns { status: Integer; env: Object }
// =============================================================================
Function handle($token : Text; $body : Object) : Object
	// --- Gate 1: token present & valid ---
	var $cap : Object
	$cap:=cs.MCP_Auth.me.validate($token)
	if ($cap=Null)
		return This._fail(401; "AUTH_DENIED"; "Missing or invalid token")
	end if

	// Body must be a JSON object to carry v/action/params.
	if ($body=Null)
		return This._fail(400; "BAD_PARAMS"; "Request body must be a JSON object")
	end if
	if (Value type($body)#Is object)
		return This._fail(400; "BAD_PARAMS"; "Request body must be a JSON object")
	end if

	// --- Gate 2: version ---
	if (Num($body.v)#1)
		return This._fail(400; "BAD_VERSION"; "Unsupported contract version (expected v:1)")
	end if

	// --- Gate 3: known action ---
	var $action : Text
	$action:=String($body.action)
	if (This._actions().indexOf($action)<0)
		return This._fail(400; "UNKNOWN_ACTION"; "Unknown action: "+$action)
	end if

	var $params : Object
	$params:=$body.params
	if ($params=Null)
		$params:=New object
	end if
	if (Value type($params)#Is object)
		return This._fail(400; "BAD_PARAMS"; "params must be a JSON object")
	end if

	// --- Gate 4: params well-formed ---
	var $pv : Text
	$pv:=This._validateParams($action; $params)
	if (Length($pv)>0)
		return This._fail(400; "BAD_PARAMS"; $pv)
	end if

	// --- Gate 5: capability ---
	var $cv : Text
	$cv:=This._checkCapability($action; $params; $cap)
	if (Length($cv)>0)
		return This._fail(403; "CAP_DENIED"; $cv)
	end if

	// --- Gate 6: execute ---
	var $res : Object
	Try
		$res:=This._execute($action; $params; $cap)
	Catch
		return This._fail(500; "INTERNAL"; This._lastErrorText())
	End try

	if ($res.error#Null)
		return This._fail(This._httpFor(String($res.error.code)); String($res.error.code); String($res.error.message))
	end if
	return This._ok($res.data; $res.meta)

// --- Routing tables ---------------------------------------------------------

Function _actions() : Collection
	return New collection(\
		"get_schema_digest"; "query_entities"; "get_entity"; \
		"create_entity"; "update_entity"; "delete_entity"; "call_method")

Function _execute($action : Text; $params : Object; $cap : Object) : Object
	Case of
		: ($action="get_schema_digest")
			return New object("data"; cs.MCP_Schema.me.digest($cap))
		: ($action="query_entities")
			return cs.MCP_DataAccess.me.query_entities($params)
		: ($action="get_entity")
			return cs.MCP_DataAccess.me.get_entity($params)
		: ($action="create_entity")
			return cs.MCP_DataAccess.me.create_entity($params)
		: ($action="update_entity")
			return cs.MCP_DataAccess.me.update_entity($params)
		: ($action="delete_entity")
			return cs.MCP_DataAccess.me.delete_entity($params)
		: ($action="call_method")
			return cs.MCP_DataAccess.me.call_method($params)
	End case
	return New object("error"; New object("code"; "INTERNAL"; "message"; "Unrouted action: "+$action))

// --- Gate 4 helpers ---------------------------------------------------------

Function _validateParams($action : Text; $params : Object) : Text
	Case of
		: ($action="get_schema_digest")
			return ""
		: ($action="query_entities")
			return This._needDataclass($params)
		: ($action="get_entity")
			var $m1 : Text
			$m1:=This._needDataclass($params)
			if (Length($m1)>0)
				return $m1
			end if
			if ($params.key=Null)
				return "Missing required param: key"
			end if
			return ""
		: ($action="create_entity")
			var $m2 : Text
			$m2:=This._needDataclass($params)
			if (Length($m2)>0)
				return $m2
			end if
			if (Value type($params.values)#Is object)
				return "Missing or invalid required param: values (object)"
			end if
			return ""
		: ($action="update_entity")
			var $m3 : Text
			$m3:=This._needDataclass($params)
			if (Length($m3)>0)
				return $m3
			end if
			if ($params.key=Null)
				return "Missing required param: key"
			end if
			if (Value type($params.values)#Is object)
				return "Missing or invalid required param: values (object)"
			end if
			return ""
		: ($action="delete_entity")
			var $m4 : Text
			$m4:=This._needDataclass($params)
			if (Length($m4)>0)
				return $m4
			end if
			if ($params.key=Null)
				return "Missing required param: key"
			end if
			return ""
		: ($action="call_method")
			if (This._blankText($params.name))
				return "Missing required param: name"
			end if
			return ""
	End case
	return ""

Function _needDataclass($params : Object) : Text
	if (This._blankText($params.dataclass))
		return "Missing required param: dataclass"
	end if
	return ""

// --- Gate 5 helpers ---------------------------------------------------------

Function _checkCapability($action : Text; $params : Object; $cap : Object) : Text
	Case of
		: ($action="get_schema_digest")
			return ""
		: ($action="query_entities") | ($action="get_entity")
			if ($cap.read.indexOf(String($params.dataclass))<0)
				return "Token cannot read dataclass: "+String($params.dataclass)
			end if
			return ""
		: ($action="create_entity") | ($action="update_entity") | ($action="delete_entity")
			if ($cap.write.indexOf(String($params.dataclass))<0)
				return "Token cannot write dataclass: "+String($params.dataclass)
			end if
			return ""
		: ($action="call_method")
			var $name : Text
			$name:=String($params.name)
			if ($cap.call.indexOf($name)<0)
				return "Token cannot call action: "+$name
			end if
			if (Not(cs.MCP_DataAccess.me.hasAction($name)))
				return "Action not registered: "+$name
			end if
			return ""
	End case
	return ""

// --- Result descriptors -----------------------------------------------------

Function _ok($data : Variant; $meta : Variant) : Object
	var $env : Object
	$env:=New object("v"; 1; "ok"; True; "data"; $data)
	if ($meta#Null)
		$env.meta:=$meta
	end if
	return New object("status"; 200; "env"; $env)

Function _fail($http : Integer; $code : Text; $message : Text) : Object
	var $env : Object
	$env:=New object("v"; 1; "ok"; False; \
		"error"; New object("code"; $code; "message"; $message))
	return New object("status"; $http; "env"; $env)

// --- Request / response plumbing --------------------------------------------

Function _bearer($request : 4D.IncomingMessage) : Text
	var $headers : Object
	$headers:=$request.headers
	if ($headers=Null)
		return ""
	end if
	var $auth : Text
	$auth:=""
	if ($headers.authorization#Null)
		$auth:=String($headers.authorization)
	else
		if ($headers.Authorization#Null)
			$auth:=String($headers.Authorization)
		end if
	end if
	if (Length($auth)=0)
		return ""
	end if
	// Case-insensitive "Bearer " scheme prefix.
	if (Lowercase(Substring($auth; 1; 7))="bearer ")
		return Substring($auth; 8)
	end if
	return $auth

Function _respond($status : Integer; $env : Object) : 4D.OutgoingMessage
	var $r : 4D.OutgoingMessage
	$r:=4D.OutgoingMessage.new()
	$r.setBody(JSON Stringify($env))
	$r.setHeader("Content-Type"; "application/json")
	$r.status:=$status
	return $r

Function _httpFor($code : Text) : Integer
	Case of
		: ($code="AUTH_DENIED")
			return 401
		: ($code="BAD_VERSION")
			return 400
		: ($code="UNKNOWN_ACTION")
			return 400
		: ($code="BAD_PARAMS")
			return 400
		: ($code="CAP_DENIED")
			return 403
		: ($code="NOT_FOUND")
			return 404
		: ($code="QUERY_ERROR")
			return 422
		: ($code="INTERNAL")
			return 500
	End case
	return 500

// --- misc helpers -----------------------------------------------------------

Function _blankText($v : Variant) : Boolean
	if ($v=Null)
		return True
	end if
	if (Value type($v)#Is text)
		return True
	end if
	return (Length($v)=0)

Function _lastErrorText() : Text
	var $errs : Collection
	$errs:=Last errors
	if ($errs=Null)
		return "Unknown 4D error"
	end if
	if ($errs.length=0)
		return "Unknown 4D error"
	end if
	var $msgs : Collection
	$msgs:=New collection
	var $e : Object
	For each ($e; $errs)
		$msgs.push(String($e.message))
	End for each
	return $msgs.join("; ")

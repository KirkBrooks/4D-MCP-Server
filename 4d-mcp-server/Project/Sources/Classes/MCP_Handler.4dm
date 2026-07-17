// MCP_Handler — the single POST /mcp request handler (registered in
// HTTPHandlers.json). Requires 4D 20 R8+ (HTTP request handlers).
//
// dispatch() is the HTTP adapter: transport-level config gates (HTTPS
// requirement, body size, per-token rate limit, host request hook), then
// delegates to handle(), then response-side plumbing (request log, write
// audit, host error hook) and renders a 4D.OutgoingMessage.
// handle($token; $body) contains ALL the gate logic and is pure (token + body
// in, {status, env} out) so it can be unit-tested headless without HTTP
// (see the MCP_Test project method).
//
// Gate order (wire contract 2), exact:
//   0. deployment config       -> INTERNAL if unreadable; CAP_DENIED if
//      ENABLED is false (gate 0 precedes the wire contract: a disabled or
//      unconfigured deployment answers nothing, valid token or not)
//   1. token present & valid   -> AUTH_DENIED    (401)
//   2. v == 1                   -> BAD_VERSION    (400)
//   3. action known            -> UNKNOWN_ACTION (400)
//   4. params well-formed      -> BAD_PARAMS     (400)
//   5a. config verb+exposure gate (_checkConfigGate): ALLOW_* verb gates, plus
//       table/field exposure — an entity action on an unexposed dataclass, a
//       filter/orderBy naming an unexposed field, or create/update values
//       naming one -> CAP_DENIED (403). Runs before the token capability so
//       config bounds every token, wildcard included.
//   5b. token capability for action (_checkCapability) -> CAP_DENIED (403).
//       Denial messages at 5a/5b are identical ("Access denied") so a token
//       cannot distinguish "hidden" from "ungranted" and map the schema.
//   6. execute                 -> success | NOT_FOUND | QUERY_ERROR | INTERNAL
//
// Envelopes (1): success {v,ok:true,data,meta?}; error {v,ok:false,error:{code,message}}.
// error carries code + message ONLY (no details, no retryable).

shared singleton Class constructor()

// =============================================================================
//  HTTP adapter
// =============================================================================
Function dispatch($request : 4D.IncomingMessage) : 4D.OutgoingMessage
	var $t0 : Integer
	$t0:=Milliseconds

	var $config : Object
	$config:=This.getConfig()
	if ($config=Null)
		return This._respond(500; This._fail(500; "INTERNAL"; "Server configuration unavailable").env)
	end if

	// --- Gate 0: deployment ENABLED, checked before any other dispatch-level
	// gate (rate limit, request hook) per wire contract 2: a disabled
	// deployment answers nothing, valid token or not. handle() re-checks this
	// as defense-in-depth for direct (non-HTTP) callers.
	if (Not(Bool($config.ENABLED)))
		return This._finish($config; This._fail(403; "CAP_DENIED"; "MCP component is disabled"); Null; ""; $t0)
	end if

	var $bodyText : Text
	$bodyText:=""
	Try
		$bodyText:=$request.getText()
	Catch
		$bodyText:=""
	End try

	// --- Transport gates: HTTPS requirement, body size ---
	// WEB Is secured connection is verified to work inside request handlers
	// (full 4D; tool4d has no web server so this line never runs headless).
	var $tg : Object
	$tg:=This._checkTransport($config; Bool(Try(WEB Is secured connection)); Length($bodyText))
	if ($tg#Null)
		return This._finish($config; $tg; Null; ""; $t0)
	end if

	var $body : Object
	$body:=Null
	if (Length($bodyText)>0)
		$body:=Try(JSON Parse($bodyText))
	end if

	var $bearer : Text
	$bearer:=This._bearer($request)

	// --- Rate limit: per validated token, fixed one-minute window ---
	// Unknown/missing tokens fall through to handle(), which 401s them.
	var $tokenId : Text
	$tokenId:=""
	var $cap : Object
	$cap:=cs.MCP_Auth.me.validate($bearer)
	if ($cap#Null)
		$tokenId:=String($cap.token_id)
		if (Not(This._checkRate($tokenId; Num($config.RATE_LIMIT))))
			return This._finish($config; \
				This._fail(429; "RATE_LIMITED"; "Rate limit exceeded ("+String(Num($config.RATE_LIMIT))+"/min)"); \
				$body; $tokenId; $t0)
		end if
	end if

	// --- ON_REQUEST_CALL: host observe/veto hook ---
	// Only invoked once the token has resolved to a valid capability (wire
	// contract 2 gate 1 outranks this hook): a missing/invalid token must
	// fall through to handle(), which 401s it, rather than being vetoed here
	// with a 403 CAP_DENIED. Mirrors the rate-limit check above, which skips
	// accounting for unresolved tokens for the same reason.
	if ($cap#Null)
		var $veto : Object
		$veto:=This._requestHook($config; $body; $tokenId)
		if ($veto#Null)
			return This._finish($config; $veto; $body; $tokenId; $t0)
		end if
	end if

	var $result : Object
	$result:=This.handle($bearer; $body)
	return This._finish($config; $result; $body; $tokenId; $t0)

// =============================================================================
//  Transport gates & response-side plumbing (dispatch only — handle() never
//  sees these; they are HTTP concerns, not wire-contract gates)
// =============================================================================

// _checkTransport: the transport-level config gates. Pure (scalars in,
// descriptor out) so it is testable headless. Returns Null to proceed.
Function _checkTransport($config : Object; $secured : Boolean; $bodyLength : Integer) : Object
	if (Bool($config.REQUIRE_HTTPS)) && (Not($secured))
		return This._fail(403; "CAP_DENIED"; "HTTPS is required")
	end if
	if ((Num($config.MAX_BODY_SIZE)>0) && ($bodyLength>Num($config.MAX_BODY_SIZE)))
		return This._fail(400; "BAD_PARAMS"; "Request body exceeds MAX_BODY_SIZE ("+String(Num($config.MAX_BODY_SIZE))+" bytes)")
	end if
	return Null

// _checkRate: fixed one-minute window counter per token, kept in the
// component's Storage (singletons are stateless; Storage is the one shared
// mutable place this build allows). True = request allowed.
Function _checkRate($tokenId : Text; $limit : Integer) : Boolean
	if ($limit<=0)
		return True
	end if
	var $window : Text
	$window:=String(Current date)+"|"+Substring(Time string(Current time); 1; 5)
	Use (Storage)
		if (Storage.mcpRate=Null)
			Storage.mcpRate:=New shared object("window"; ""; "counts"; New shared object)
		end if
	End use
	var $allowed : Boolean
	Use (Storage.mcpRate)
		if (Storage.mcpRate.window#$window)
			Storage.mcpRate.window:=$window
			Storage.mcpRate.counts:=New shared object
		end if
		var $n : Integer
		$n:=Num(Storage.mcpRate.counts[$tokenId])+1
		Storage.mcpRate.counts[$tokenId]:=$n
		$allowed:=($n<=$limit)
	End use
	return $allowed

// _requestHook: calls the host method named by ON_REQUEST_CALL with
// {action, token_id}. Only invoked by dispatch() once the Bearer token has
// already resolved to a valid capability (gate 1 outranks this hook; see the
// call site) — $tokenId is therefore always the resolved token_id here, never
// "". If the method returns {deny: true {; message}} the request is refused
// with CAP_DENIED. Hook errors never block traffic.
Function _requestHook($config : Object; $body : Object; $tokenId : Text) : Object
	var $name : Text
	$name:=String($config.ON_REQUEST_CALL)
	if (Length($name)=0)
		return Null
	end if
	var $info : Object
	$info:=New object("action"; ""; "token_id"; $tokenId)
	if ($body#Null)
		$info.action:=String($body.action)
	end if
	var $hr : Variant
	Try
		EXECUTE METHOD($name; $hr; $info)
	Catch
		return Null
	End try
	if (Value type($hr)=Is object)
		if (Bool($hr.deny))
			var $msg : Text
			$msg:="Denied by host request hook"
			if ($hr.message#Null)
				$msg:=String($hr.message)
			end if
			return This._fail(403; "CAP_DENIED"; $msg)
		end if
	end if
	return Null

// _finish: request log, write audit, ON_ERROR_CALL — then renders the
// response. $body may be Null and $tokenId "" for requests denied early.
Function _finish($config : Object; $result : Object; $body : Object; $tokenId : Text; $t0 : Integer) : 4D.OutgoingMessage
	var $action : Text
	$action:=""
	var $params : Object
	$params:=Null
	if ($body#Null)
		$action:=String($body.action)
		if (Value type($body.params)=Is object)
			$params:=$body.params
		end if
	end if
	var $code : Text
	$code:=""
	if ($result.env.error#Null)
		$code:=String($result.env.error.code)
	end if

	This._logRequest($config; New object(\
		"ts"; Timestamp; "action"; $action; "token_id"; $tokenId; \
		"status"; $result.status; "code"; $code; "ms"; Milliseconds-$t0))

	if ((Bool($config.AUDIT_WRITES)) && ($result.env.ok=True) && (This._isMutation($action)))
		var $audit : Object
		$audit:=New object("ts"; Timestamp; "token_id"; $tokenId; "action"; $action)
		if ($params#Null)
			$audit.dataclass:=$params.dataclass
			$audit.key:=$params.key
			$audit.name:=$params.name
		end if
		// create_entity: the new key is in the result, not the params
		if (($audit.key=Null) && ($result.env.data#Null) && (Value type($result.env.data)=Is object))
			$audit.key:=$result.env.data.key
		end if
		This._appendLog("mcp_audit.jsonl"; $audit)
	end if

	if (($code="INTERNAL") && (Length(String($config.ON_ERROR_CALL))>0))
		var $ignored : Variant
		Try
			EXECUTE METHOD(String($config.ON_ERROR_CALL); $ignored; New object(\
				"ts"; Timestamp; "action"; $action; "code"; $code; \
				"message"; String($result.env.error.message)))
		Catch
		End try
	end if

	return This._respond($result.status; $result.env)

Function _isMutation($action : Text) : Boolean
	return (New collection("create_entity"; "update_entity"; "delete_entity"; "call_method").indexOf($action)>=0)

// _logRequest: LOG_REQUESTS gates the request log; LOG_LEVEL "off" silences
// everything, "error" logs failed requests only, "info"/"debug" log all.
Function _logRequest($config : Object; $entry : Object)
	if (Not(Bool($config.LOG_REQUESTS)))
		return
	end if
	var $level : Text
	$level:=String($config.LOG_LEVEL)
	if ($level="off")
		return
	end if
	if (($level="error") && (Length(String($entry.code))=0))
		return
	end if
	This._appendLog("mcp_requests.jsonl"; $entry)

// _appendLog: JSONL append into the HOST's Logs folder. Logging must never
// break a request — all failures are swallowed.
Function _appendLog($fileName : Text; $entry : Object)
	Try
		var $folder : 4D.Folder
		$folder:=Folder(fk logs folder; *)
		$folder.create()
		var $h : 4D.FileHandle
		$h:=$folder.file($fileName).open("append")
		$h.writeText(JSON Stringify($entry)+Char(Line feed))
		$h:=Null
	Catch
	End try

// =============================================================================
//  Pure gate chain — returns { status: Integer; env: Object }
// =============================================================================
Function handle($token : Text; $body : Object) : Object
	// --- Gate 0: deployment config ---
	var $config : Object
	$config:=This.getConfig()
	if ($config=Null)
		return This._fail(500; "INTERNAL"; "Server configuration unavailable")
	end if
	if (Not(Bool($config.ENABLED)))
		return This._fail(403; "CAP_DENIED"; "MCP component is disabled")
	end if

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
	$pv:=This._validateParams($action; $params; $config)
	if (Length($pv)>0)
		return This._fail(400; "BAD_PARAMS"; $pv)
	end if

	// --- Gate 5: capability (deployment config first, then token) ---
	var $cg : Text
	$cg:=This._checkConfigGate($action; $params; $config)
	if (Length($cg)>0)
		return This._fail(403; "CAP_DENIED"; $cg)
	end if

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

// =============================================================================
//  Config loader
// =============================================================================
// The component ships its default config in Resources/4D-mcp-config.pref
// (Resources stays readable when the component is compiled; Project/Sources
// does not). The live config is the HOST's Project/Sources/4D-mcp-config.pref;
// if the host has none, the default is copied there on first read.
//
// File format is { KEY: {comment, value}, ... } — getConfig() flattens that to
// { KEY: value } so callers never touch .value. Keys starting with "_" are
// documentation entries and are skipped.
//
// Singletons are stateless (see design notes), so the file is read on demand.
// Editing the host file is therefore live on the next request — no reload
// step, no restart. Returns Null when no config can be read or parsed;
// callers must treat Null as fail-closed.

Function getConfig() : Object
	var $file : 4D.File
	$file:=This._configFile()
	if (Not($file.exists))
		var $default : 4D.File
		$default:=This._defaultConfigFile()
		if (Not($default.exists))
			return Null
		end if
		Try
			$default.copyTo($file.parent)
		Catch
			return Null
		End try
	end if

	var $raw : Variant
	$raw:=Try(JSON Parse($file.getText()))
	if ($raw=Null)
		return Null
	end if
	if (Value type($raw)#Is object)
		return Null
	end if

	var $settings : Object
	$settings:=New object
	var $key : Text
	For each ($key; $raw)
		if (Substring($key; 1; 1)="_")
			continue
		end if
		if (Value type($raw[$key])#Is object)
			return Null  // malformed entry — fail closed rather than half-load
		end if
		$settings[$key]:=$raw[$key].value
	End for each
	return $settings

Function _configFile() : 4D.File
	// Host's editable copy. The * resolves to the host when running as a
	// component; standalone (dev) it is this project's own folder.
	return Folder(fk database folder; *).file("Project/Sources/4D-mcp-config.pref")

Function _defaultConfigFile() : 4D.File
	// Component's shipping default (no * = component's own Resources).
	return Folder(fk resources folder).file("4D-mcp-config.pref")

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

Function _validateParams($action : Text; $params : Object; $config : Object) : Text
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
			if (($params.args#Null) && (Value type($params.args)#Is collection))
				return "args must be a collection (positional)"
			end if
			return This._validateCallArgs($config; String($params.name); $params.args)
	End case
	return ""

// _validateCallArgs: arity and type checks against the METHOD_WHITELIST spec.
// Args bind positionally; the spec's `name` is documentation only. Optional
// args are trailing-only (4D method semantics). An action absent from the
// map returns "" here — gate 5 owns that denial (CAP_DENIED, not BAD_PARAMS).
Function _validateCallArgs($config : Object; $name : Text; $args : Collection) : Text
	if (Value type($config.METHOD_WHITELIST)#Is object)
		return ""
	end if
	var $spec : Object
	$spec:=$config.METHOD_WHITELIST[$name]
	if ($spec=Null)
		return ""
	end if
	var $specArgs : Collection
	$specArgs:=New collection
	if (Value type($spec.args)=Is collection)
		$specArgs:=$spec.args
	end if
	var $given : Integer
	$given:=0
	if ($args#Null)
		$given:=$args.length
	end if
	if ($given>$specArgs.length)
		return "Too many args for "+$name+" (expected at most "+String($specArgs.length)+")"
	end if
	var $i : Integer
	For ($i; 0; $specArgs.length-1)
		var $as : Object
		$as:=$specArgs[$i]
		if ($i>=$given)
			if (Bool($as.required))
				return "Missing required arg "+String($i+1)+" ("+String($as.name)+") for "+$name
			end if
		else
			if ($as.type#Null)
				var $t : Text
				$t:=This._jsonTypeOf($args[$i])
				if ($t#String($as.type))
					return "Arg "+String($i+1)+" ("+String($as.name)+") of "+$name+" must be "+String($as.type)+", got "+$t
				end if
			end if
		end if
	End for
	return ""

Function _jsonTypeOf($v : Variant) : Text
	Case of
		: (Value type($v)=Is text)
			return "text"
		: ((Value type($v)=Is real) || (Value type($v)=Is longint))
			return "number"
		: (Value type($v)=Is boolean)
			return "boolean"
		: (Value type($v)=Is object)
			return "object"
		: (Value type($v)=Is collection)
			return "collection"
	End case
	return "null"

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
			if (Not(cs.MCP_Auth.me.grantCovers($cap.read; String($params.dataclass))))
				return "Access denied"  // generic — see _checkExposure
			end if
			return ""
		: ($action="create_entity") | ($action="update_entity") | ($action="delete_entity")
			if (Not(cs.MCP_Auth.me.grantCovers($cap.write; String($params.dataclass))))
				return "Access denied"  // generic — see _checkExposure
			end if
			return ""
		: ($action="call_method")
			// Whitelist membership is the config gate's job (_checkConfigGate);
			// here only the token capability is checked.
			if ($cap.call.indexOf(String($params.name))<0)
				return "Token cannot call action: "+String($params.name)
			end if
			return ""
	End case
	return ""

// _checkConfigGate: the deployment-level verb gates from 4D-mcp-config.pref.
// Checked before the token capability — config bounds what ANY token may do.
// ALLOW_READ  gates get_schema_digest / query_entities / get_entity.
// ALLOW_WRITE gates create_entity / update_entity.
// ALLOW_DELETE gates delete_entity.
// ALLOW_CALL_METHOD gates call_method globally; METHOD_WHITELIST is the
// filtered subset of action names callable when it is true.
// Table exposure (RESPECT_4D_SCHEMA / WHITELIST_TABLES / BLACKLIST_TABLES)
// is a config concern, so it is enforced here too: an entity action on an
// unexposed dataclass is CAP_DENIED regardless of the token. When
// RESPECT_4D_SCHEMA is on, create/update values may not touch unexposed
// fields. get_schema_digest self-filters in MCP_Schema.digest.
Function _checkConfigGate($action : Text; $params : Object; $config : Object) : Text
	Case of
		: ($action="get_schema_digest")
			if (Not(Bool($config.ALLOW_READ)))
				return "Read access is disabled in server config"
			end if
			return ""
		: ($action="query_entities") | ($action="get_entity")
			if (Not(Bool($config.ALLOW_READ)))
				return "Read access is disabled in server config"
			end if
			var $re : Text
			$re:=This._checkExposure($params; $config)
			if (Length($re)>0)
				return $re
			end if
			// filter / orderBy may not reference unexposed or relation fields
			// (value-oracle guard). get_entity carries neither, so this is a
			// no-op there but harmless.
			var $bad : Text
			$bad:=cs.MCP_Schema.me.forbiddenQueryField(String($params.dataclass); $params.filter; $params.orderBy; $config)
			if (Length($bad)>0)
				return "Access denied"
			end if
			return ""
		: ($action="create_entity") | ($action="update_entity")
			if (Not(Bool($config.ALLOW_WRITE)))
				return "Write access is disabled in server config"
			end if
			var $ce : Text
			$ce:=This._checkExposure($params; $config)
			if (Length($ce)>0)
				return $ce
			end if
			return This._checkValuesExposure($params; $config)
		: ($action="delete_entity")
			if (Not(Bool($config.ALLOW_DELETE)))
				return "Delete access is disabled in server config"
			end if
			return This._checkExposure($params; $config)
		: ($action="call_method")
			if (Not(Bool($config.ALLOW_CALL_METHOD)))
				return "Method calls are disabled in server config"
			end if
			if (Value type($config.METHOD_WHITELIST)#Is object)
				return "Method calls are disabled in server config"
			end if
			if ($config.METHOD_WHITELIST[String($params.name)]=Null)
				return "Action not enabled in server config: "+String($params.name)
			end if
			return ""
	End case
	return ""

// _checkExposure: the target dataclass must be in the config's exposed set.
// The denial message is deliberately generic and identical to the token-
// capability denial (see _checkCapability): otherwise a valid token could tell
// "exists but hidden" from "exists and ungranted" and enumerate the schema.
Function _checkExposure($params : Object; $config : Object) : Text
	if (Not(cs.MCP_Schema.me.isExposed($config; String($params.dataclass))))
		return "Access denied"
	end if
	return ""

// _checkValuesExposure: with RESPECT_4D_SCHEMA on, refuse create/update whose
// values name an unexposed storage field (its attribute lacks `exposed`).
// Unknown keys still pass through — fromObject ignores them, as before.
Function _checkValuesExposure($params : Object; $config : Object) : Text
	if (Not(Bool($config.RESPECT_4D_SCHEMA)))
		return ""
	end if
	if (Value type($params.values)#Is object)
		return ""  // missing/malformed values is gate 4's problem, not ours
	end if
	var $dcName : Text
	$dcName:=String($params.dataclass)
	var $key : Text
	For each ($key; $params.values)
		var $attr : Object
		$attr:=ds[$dcName][$key]
		if ($attr=Null)
			continue
		end if
		if ($attr.kind#"storage")
			continue
		end if
		if (Not(Bool($attr.exposed)))
			return "Field is not exposed: "+$dcName+"."+$key
		end if
	End for each
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
		: ($code="RATE_LIMITED")
			return 429
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

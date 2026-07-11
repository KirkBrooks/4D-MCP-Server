// MCP_Test — in-4D self-test of the full gate chain via MCP_Handler.handle().
//
// Exercises every action (happy path) plus the error taxonomy WITHOUT needing
// HTTP, by calling the pure handle($token; $body) seam. Runnable headless with
// tool4d (see the MCP_RunHeadlessTests method). The curl script covers the
// real wire/HTTP path; this covers routing, gating and ORDA behaviour.

shared singleton Class constructor()

// seedFixtures: idempotent. 3 Customers, 3 Orders.
Function seedFixtures()
	if (ds.Customer.all().length=0)
		This._newCustomer("Acme Co"; "a@acme.test"; True)
		This._newCustomer("Globex"; "g@globex.test"; True)
		This._newCustomer("Initech"; "i@initech.test"; False)
	end if
	if (ds.Order.all().length=0)
		var $acme : Object
		$acme:=ds.Customer.query("name = :1"; "Acme Co").first()
		var $globex : Object
		$globex:=ds.Customer.query("name = :1"; "Globex").first()
		var $acmeID : Integer
		$acmeID:=Num($acme.ID)
		This._newOrder($acmeID; 100; "open")
		This._newOrder($acmeID; 250; "shipped")
		This._newOrder(Num($globex.ID); 0; "open")
	end if

Function _newCustomer($name : Text; $email : Text; $active : Boolean)
	var $e : Object
	$e:=ds.Customer.new()
	$e.name:=$name
	$e.email:=$email
	$e.active:=$active
	$e.save()

Function _newOrder($customerID : Integer; $total : Real; $status : Text)
	var $e : Object
	$e:=ds.Order.new()
	$e.customerID:=$customerID
	$e.total:=$total
	$e.status:=$status
	$e.save()

// runAll: returns { total, passed, failed, cases:[{name,pass,detail}] }.
Function runAll() : Object
	This.seedFixtures()
	var $r : Object
	$r:=New object("cases"; New collection)

	var $FULL : Text
	$FULL:="SECRET_FULL"
	var $RO : Text
	$RO:="SECRET_RO"

	var $acmeID : Integer
	$acmeID:=Num(ds.Customer.query("name = :1"; "Acme Co").first().ID)

	var $res : Object

	// 1. schema digest (full) -> both dataclasses
	$res:=This._call($FULL; "get_schema_digest"; New object)
	This._ok($r; "schema_digest_full_200"; ($res.status=200) && ($res.env.ok=True))
	This._ok($r; "schema_digest_full_2_dataclasses"; ($res.env.data.dataclasses.length=2))

	// 2. schema digest (ro) -> Customer only
	$res:=This._call($RO; "get_schema_digest"; New object)
	This._ok($r; "schema_digest_ro_1_dataclass"; ($res.env.data.dataclasses.length=1))
	This._ok($r; "schema_digest_ro_is_customer"; ($res.env.data.dataclasses[0].name="Customer"))
	This._ok($r; "schema_digest_customer_pk"; ($res.env.data.dataclasses[0].primaryKey="ID"))

	// 3. query Customer (full)
	$res:=This._call($FULL; "query_entities"; New object("dataclass"; "Customer"))
	This._ok($r; "query_customer_200"; ($res.status=200) && ($res.env.ok=True))
	This._ok($r; "query_customer_meta_limit80"; ($res.env.meta.limit=80))
	This._ok($r; "query_customer_total3"; ($res.env.meta.total=3))

	// 4. query Order with ro token -> CAP_DENIED
	$res:=This._call($RO; "query_entities"; New object("dataclass"; "Order"))
	This._ok($r; "query_order_ro_capdenied"; ($res.status=403) && ($res.env.error.code="CAP_DENIED"))

	// 5. query with placeholder params
	$res:=This._call($FULL; "query_entities"; New object("dataclass"; "Customer"; \
		"filter"; "name = :1"; "params"; New collection("Acme Co")))
	This._ok($r; "query_filter_bind_count1"; ($res.env.meta.total=1) && ($res.env.data[0].name="Acme Co"))

	// 6. limit clamp
	$res:=This._call($FULL; "query_entities"; New object("dataclass"; "Customer"; "limit"; 500))
	This._ok($r; "query_limit_clamped"; ($res.env.meta.clamped=True) && ($res.env.meta.limit=80))

	// 7. get_entity happy
	$res:=This._call($FULL; "get_entity"; New object("dataclass"; "Customer"; "key"; $acmeID))
	This._ok($r; "get_entity_200"; ($res.status=200) && ($res.env.data.name="Acme Co"))

	// 8. get_entity NOT_FOUND
	$res:=This._call($FULL; "get_entity"; New object("dataclass"; "Customer"; "key"; 999999))
	This._ok($r; "get_entity_not_found"; ($res.status=404) && ($res.env.error.code="NOT_FOUND"))

	// 9. create_entity Order happy
	$res:=This._call($FULL; "create_entity"; New object("dataclass"; "Order"; \
		"values"; New object("customerID"; $acmeID; "total"; 42; "status"; "new")))
	This._ok($r; "create_order_200"; ($res.status=200) && ($res.env.data.created=True) && ($res.env.data.key#Null))
	var $newKey : Integer
	$newKey:=Num($res.env.data.key)

	// 10. create Customer with full token -> CAP_DENIED (write is Order-only)
	$res:=This._call($FULL; "create_entity"; New object("dataclass"; "Customer"; \
		"values"; New object("name"; "Nope")))
	This._ok($r; "create_customer_capdenied"; ($res.status=403) && ($res.env.error.code="CAP_DENIED"))

	// 11. update Order happy
	$res:=This._call($FULL; "update_entity"; New object("dataclass"; "Order"; \
		"key"; $newKey; "values"; New object("total"; 999)))
	This._ok($r; "update_order_200"; ($res.status=200) && ($res.env.data.updated=True))
	$res:=This._call($FULL; "get_entity"; New object("dataclass"; "Order"; "key"; $newKey))
	This._ok($r; "update_order_persisted"; (Num($res.env.data.total)=999))

	// 12. update NOT_FOUND
	$res:=This._call($FULL; "update_entity"; New object("dataclass"; "Order"; \
		"key"; 999999; "values"; New object("total"; 1)))
	This._ok($r; "update_order_not_found"; ($res.status=404) && ($res.env.error.code="NOT_FOUND"))

	// 13. delete Order happy
	$res:=This._call($FULL; "delete_entity"; New object("dataclass"; "Order"; "key"; $newKey))
	This._ok($r; "delete_order_200"; ($res.status=200) && ($res.env.data.deleted=True))
	$res:=This._call($FULL; "get_entity"; New object("dataclass"; "Order"; "key"; $newKey))
	This._ok($r; "delete_order_gone"; ($res.status=404))

	// 14. delete NOT_FOUND
	$res:=This._call($FULL; "delete_entity"; New object("dataclass"; "Order"; "key"; 999999))
	This._ok($r; "delete_order_not_found"; ($res.status=404) && ($res.env.error.code="NOT_FOUND"))

	// 15. call_method ping — args are POSITIONAL (collection)
	$res:=This._call($FULL; "call_method"; New object("name"; "ping"; "args"; New collection("hello")))
	This._ok($r; "call_ping_200"; ($res.status=200) && ($res.env.data.result.pong=True) && ($res.env.data.name="ping"))
	This._ok($r; "call_ping_echo_positional"; ($res.env.data.result.echo="hello"))

	// 16. call_method order_count
	$res:=This._call($FULL; "call_method"; New object("name"; "order_count"))
	This._ok($r; "call_order_count_200"; ($res.status=200) && (Value type($res.env.data.result.count)=Is real))

	// 17. call_method unknown action -> CAP_DENIED
	$res:=This._call($FULL; "call_method"; New object("name"; "no_such_action"))
	This._ok($r; "call_unknown_capdenied"; ($res.status=403) && ($res.env.error.code="CAP_DENIED"))

	// 18. call_method ping with ro token (empty call list) -> CAP_DENIED
	$res:=This._call($RO; "call_method"; New object("name"; "ping"))
	This._ok($r; "call_ping_ro_capdenied"; ($res.status=403) && ($res.env.error.code="CAP_DENIED"))

	// 19. AUTH_DENIED — no token, and bad token
	$res:=New object("status"; 0; "env"; Null)
	$res:=cs.MCP_Handler.me.handle(""; New object("v"; 1; "action"; "get_schema_digest"; "params"; New object))
	This._ok($r; "auth_missing_401"; ($res.status=401) && ($res.env.error.code="AUTH_DENIED"))
	$res:=cs.MCP_Handler.me.handle("bad_token"; New object("v"; 1; "action"; "get_schema_digest"; "params"; New object))
	This._ok($r; "auth_bad_401"; ($res.status=401) && ($res.env.error.code="AUTH_DENIED"))

	// 20. BAD_VERSION
	$res:=cs.MCP_Handler.me.handle($FULL; New object("v"; 2; "action"; "get_schema_digest"; "params"; New object))
	This._ok($r; "bad_version_400"; ($res.status=400) && ($res.env.error.code="BAD_VERSION"))

	// 21. UNKNOWN_ACTION
	$res:=This._call($FULL; "frobnicate"; New object)
	This._ok($r; "unknown_action_400"; ($res.status=400) && ($res.env.error.code="UNKNOWN_ACTION"))

	// 22. BAD_PARAMS — query without dataclass
	$res:=This._call($FULL; "query_entities"; New object)
	This._ok($r; "bad_params_400"; ($res.status=400) && ($res.env.error.code="BAD_PARAMS"))

	// 23. config verb gates — patch the host config between calls (the loader
	// reads on demand, so each patch is live immediately), restore afterwards.
	// Gate 5 runs before execute, so delete-with-bogus-key must be CAP_DENIED,
	// not NOT_FOUND. All checks use $FULL: the token allows everything, so any
	// denial can only come from the config gate.
	var $cfgFile : 4D.File
	$cfgFile:=Folder(fk database folder; *).file("Project/Sources/4D-mcp-config.pref")
	var $cfgOrig : Text
	$cfgOrig:=$cfgFile.getText()

	This._patchConfig($cfgFile; $cfgOrig; "ENABLED"; False)
	$res:=This._call($FULL; "query_entities"; New object("dataclass"; "Customer"))
	This._ok($r; "config_disabled_capdenied"; ($res.status=403) && ($res.env.error.code="CAP_DENIED"))

	This._patchConfig($cfgFile; $cfgOrig; "ALLOW_READ"; False)
	$res:=This._call($FULL; "query_entities"; New object("dataclass"; "Customer"))
	This._ok($r; "config_read_off_capdenied"; ($res.status=403) && ($res.env.error.code="CAP_DENIED"))

	This._patchConfig($cfgFile; $cfgOrig; "ALLOW_WRITE"; False)
	$res:=This._call($FULL; "create_entity"; New object("dataclass"; "Order"; \
		"values"; New object("customerID"; $acmeID; "total"; 1; "status"; "new")))
	This._ok($r; "config_write_off_capdenied"; ($res.status=403) && ($res.env.error.code="CAP_DENIED"))

	This._patchConfig($cfgFile; $cfgOrig; "ALLOW_DELETE"; False)
	$res:=This._call($FULL; "delete_entity"; New object("dataclass"; "Order"; "key"; 999999))
	This._ok($r; "config_delete_off_capdenied"; ($res.status=403) && ($res.env.error.code="CAP_DENIED"))

	This._patchConfig($cfgFile; $cfgOrig; "ALLOW_CALL_METHOD"; False)
	$res:=This._call($FULL; "call_method"; New object("name"; "ping"))
	This._ok($r; "config_call_off_capdenied"; ($res.status=403) && ($res.env.error.code="CAP_DENIED"))

	This._patchConfig($cfgFile; $cfgOrig; "METHOD_WHITELIST"; \
		New object("order_count"; New object("method"; "MCP_Fixture_OrderCount")))
	$res:=This._call($FULL; "call_method"; New object("name"; "ping"))
	This._ok($r; "config_whitelist_subset_capdenied"; ($res.status=403) && ($res.env.error.code="CAP_DENIED"))

	$cfgFile.setText($cfgOrig)
	$res:=This._call($FULL; "query_entities"; New object("dataclass"; "Customer"))
	This._ok($r; "config_restored_200"; ($res.status=200) && ($res.env.ok=True))

	// 24. transport gates + rate limit — pure helpers, testable headless.
	// dispatch() itself needs a real web server; the curl suite covers it.
	var $tcfg : Object
	$tcfg:=New object("REQUIRE_HTTPS"; True; "MAX_BODY_SIZE"; 100)
	$res:=cs.MCP_Handler.me._checkTransport($tcfg; False; 10)
	This._ok($r; "transport_https_required_denied"; ($res#Null) && ($res.status=403) && ($res.env.error.code="CAP_DENIED"))
	$res:=cs.MCP_Handler.me._checkTransport($tcfg; True; 10)
	This._ok($r; "transport_https_ok_passes"; ($res=Null))
	$res:=cs.MCP_Handler.me._checkTransport($tcfg; True; 101)
	This._ok($r; "transport_body_oversize_badparams"; ($res#Null) && ($res.status=400) && ($res.env.error.code="BAD_PARAMS"))

	// Rate limit: fixed one-minute window; can misfire only if the test
	// straddles a minute boundary between these five calls (vanishingly rare).
	var $i : Integer
	var $rateOK : Boolean
	$rateOK:=True
	For ($i; 1; 3)
		$rateOK:=$rateOK && cs.MCP_Handler.me._checkRate("tok_test_rate"; 3)
	End for
	This._ok($r; "rate_under_limit_allowed"; $rateOK)
	This._ok($r; "rate_over_limit_denied"; (Not(cs.MCP_Handler.me._checkRate("tok_test_rate"; 3))))
	This._ok($r; "rate_zero_unlimited"; cs.MCP_Handler.me._checkRate("tok_test_rate"; 0))
	This._ok($r; "rate_other_token_unaffected"; cs.MCP_Handler.me._checkRate("tok_test_other"; 3))

	// 25. call_method arg-spec validation (gate 4) + digest discovery.
	// echo_upper's spec: one REQUIRED text arg.
	$res:=This._call($FULL; "call_method"; New object("name"; "echo_upper"; "args"; New collection("hello")))
	This._ok($r; "call_echo_upper_200"; ($res.status=200) && ($res.env.data.result.upper="HELLO"))

	$res:=This._call($FULL; "call_method"; New object("name"; "echo_upper"))
	This._ok($r; "call_missing_required_badparams"; ($res.status=400) && ($res.env.error.code="BAD_PARAMS"))

	$res:=This._call($FULL; "call_method"; New object("name"; "echo_upper"; "args"; New collection(42)))
	This._ok($r; "call_wrong_type_badparams"; ($res.status=400) && ($res.env.error.code="BAD_PARAMS"))

	$res:=This._call($FULL; "call_method"; New object("name"; "ping"; "args"; New collection("a"; "b")))
	This._ok($r; "call_too_many_args_badparams"; ($res.status=400) && ($res.env.error.code="BAD_PARAMS"))

	// digest: full token sees the 3 fixture actions, spec sans host method name
	$res:=This._call($FULL; "get_schema_digest"; New object)
	This._ok($r; "digest_callable_actions_3"; ($res.env.data.callable_actions.length=3))
	This._ok($r; "digest_callable_no_method_leak"; ($res.env.data.callable_actions[0].method=Null))
	This._ok($r; "digest_callable_has_purpose"; (Length(String($res.env.data.callable_actions[0].purpose))>0))

	// digest: ro token (empty call capability) sees none
	$res:=This._call($RO; "get_schema_digest"; New object)
	This._ok($r; "digest_callable_ro_empty"; ($res.env.data.callable_actions.length=0))

	// tally
	var $passed : Integer
	$passed:=0
	var $c : Object
	For each ($c; $r.cases)
		if ($c.pass)
			$passed:=$passed+1
		end if
	End for each
	$r.total:=$r.cases.length
	$r.passed:=$passed
	$r.failed:=$r.total-$passed
	return $r

// _call: convenience to build a v:1 envelope and invoke handle().
Function _call($token : Text; $action : Text; $params : Object) : Object
	return cs.MCP_Handler.me.handle($token; New object("v"; 1; "action"; $action; "params"; $params))

Function _ok($r : Object; $name : Text; $cond : Boolean)
	$r.cases.push(New object("name"; $name; "pass"; ($cond=True)))

// _patchConfig: rewrite the host config file with ONE setting changed from the
// pristine original (patches never stack). Used by the config-gate cases.
Function _patchConfig($file : 4D.File; $orig : Text; $key : Text; $value : Variant)
	var $cfg : Object
	$cfg:=JSON Parse($orig)
	$cfg[$key].value:=$value
	$file.setText(JSON Stringify($cfg))

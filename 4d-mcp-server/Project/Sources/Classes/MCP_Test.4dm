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

	// 15. call_method ping
	$res:=This._call($FULL; "call_method"; New object("name"; "ping"; "args"; New object("hi"; 1)))
	This._ok($r; "call_ping_200"; ($res.status=200) && ($res.env.data.result.pong=True) && ($res.env.data.name="ping"))

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

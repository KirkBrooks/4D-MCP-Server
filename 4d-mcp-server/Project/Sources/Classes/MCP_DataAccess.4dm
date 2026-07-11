// MCP_DataAccess — executes the ORDA operations behind each data action.
//
// Every public function returns a RESULT DESCRIPTOR object:
//   success -> { data: <obj|collection> }  (query_entities also adds { meta })
//   failure -> { error: { code, message } }  using the fixed taxonomy (4).
// Capability gating and param validation happen in MCP_Handler BEFORE these
// run; these functions own only gate 6 (execution + NOT_FOUND/QUERY_ERROR/
// INTERNAL).
//
// SECURITY: query_entities binds filter values positionally (:1, :2 ...) via
// ORDA placeholders. Values are NEVER string-interpolated into the query.

// limit default AND hard cap are both 80 (matches 4D internal paging).
// Shared singletons in this 4D build must stay stateless (assigning to a
// shared This property is rejected), so config is exposed via functions.

shared singleton Class constructor()

// _HARD_CAP: query_entities limit default AND hard cap.
Function _HARD_CAP() : Integer
	return 80

// =============================================================================
//  query_entities  (3.2)
// =============================================================================
Function query_entities($params : Object) : Object
	var $dc : 4D.DataClass
	$dc:=ds[String($params.dataclass)]
	if ($dc=Null)
		return This._err("QUERY_ERROR"; "Unknown dataclass: "+String($params.dataclass))
	end if

	// offset
	var $offset : Integer
	$offset:=0
	if ($params.offset#Null)
		$offset:=Num($params.offset)
	end if
	if ($offset<0)
		$offset:=0
	end if

	// limit: default = hard cap; clamp anything larger.
	var $cap : Integer
	$cap:=This._HARD_CAP()
	var $limit : Integer
	var $clamped : Boolean
	$clamped:=False
	if ($params.limit=Null)
		$limit:=$cap
	else
		$limit:=Num($params.limit)
		if ($limit>$cap)
			$limit:=$cap
			$clamped:=True
		end if
		if ($limit<0)
			$limit:=0
		end if
	end if

	// build selection (filter + placeholder binding + orderBy)
	var $sel : 4D.EntitySelection
	Try
		$sel:=This._query($dc; String($params.filter); $params.params)
		if ($params.orderBy#Null)
			if (Length(String($params.orderBy))>0)
				$sel:=$sel.orderBy(String($params.orderBy))
			end if
		end if
	Catch
		return This._err("QUERY_ERROR"; This._lastErrorText())
	End try

	var $total : Integer
	$total:=$sel.length

	var $proj : Text
	$proj:=This._projection(String($params.dataclass); $params.attributes)

	var $data : Collection
	$data:=New collection
	Try
		var $page : 4D.EntitySelection
		$page:=$sel.slice($offset; $offset+$limit)
		var $e : 4D.Entity
		For each ($e; $page)
			$data.push($e.toObject($proj))
		End for each
	Catch
		return This._err("QUERY_ERROR"; This._lastErrorText())
	End try

	var $count : Integer
	$count:=$data.length
	var $meta : Object
	$meta:=New object(\
		"count"; $count; \
		"offset"; $offset; \
		"limit"; $limit; \
		"total"; $total; \
		"truncated"; (($offset+$count)<$total); \
		"clamped"; $clamped)
	return New object("data"; $data; "meta"; $meta)

// _query: bind filter values positionally to :1, :2 ... Injection-safe.
// The explicit length branches guarantee correct positional binding regardless
// of 4D version; >6 placeholders fall back to passing the collection (verify on
// first run for that edge case only).
Function _query($dc : 4D.DataClass; $filter : Text; $qp : Variant) : 4D.EntitySelection
	if ($filter=Null)
		return $dc.all()
	end if
	if (Length($filter)=0)
		return $dc.all()
	end if
	var $c : Collection
	$c:=New collection
	if ($qp#Null)
		if (Value type($qp)=Is collection)
			$c:=$qp
		end if
	end if
	Case of
		: ($c.length=0)
			return $dc.query($filter)
		: ($c.length=1)
			return $dc.query($filter; $c[0])
		: ($c.length=2)
			return $dc.query($filter; $c[0]; $c[1])
		: ($c.length=3)
			return $dc.query($filter; $c[0]; $c[1]; $c[2])
		: ($c.length=4)
			return $dc.query($filter; $c[0]; $c[1]; $c[2]; $c[3])
		: ($c.length=5)
			return $dc.query($filter; $c[0]; $c[1]; $c[2]; $c[3]; $c[4])
		: ($c.length=6)
			return $dc.query($filter; $c[0]; $c[1]; $c[2]; $c[3]; $c[4]; $c[5])
		else
			return $dc.query($filter; $c)
	End case

// =============================================================================
//  get_entity  (3.3)
// =============================================================================
Function get_entity($params : Object) : Object
	var $dc : 4D.DataClass
	$dc:=ds[String($params.dataclass)]
	if ($dc=Null)
		return This._err("QUERY_ERROR"; "Unknown dataclass: "+String($params.dataclass))
	end if
	var $e : 4D.Entity
	Try
		$e:=$dc.get($params.key)
	Catch
		return This._err("QUERY_ERROR"; This._lastErrorText())
	End try
	if ($e=Null)
		return This._err("NOT_FOUND"; "No entity with key "+JSON Stringify($params.key))
	end if
	var $proj : Text
	$proj:=This._projection(String($params.dataclass); $params.attributes)
	return New object("data"; $e.toObject($proj))

// =============================================================================
//  create_entity  (3.4)
// =============================================================================
Function create_entity($params : Object) : Object
	var $dc : 4D.DataClass
	$dc:=ds[String($params.dataclass)]
	if ($dc=Null)
		return This._err("QUERY_ERROR"; "Unknown dataclass: "+String($params.dataclass))
	end if
	var $e : 4D.Entity
	$e:=$dc.new()
	$e.fromObject($params.values)
	var $status : Object
	Try
		$status:=$e.save()
	Catch
		return This._err("INTERNAL"; This._lastErrorText())
	End try
	if (Not($status.success))
		return This._err("QUERY_ERROR"; This._statusText($status))
	end if
	return New object("data"; New object("key"; $e.getKey(); "created"; True))

// =============================================================================
//  update_entity  (3.5)
// =============================================================================
Function update_entity($params : Object) : Object
	var $dc : 4D.DataClass
	$dc:=ds[String($params.dataclass)]
	if ($dc=Null)
		return This._err("QUERY_ERROR"; "Unknown dataclass: "+String($params.dataclass))
	end if
	var $e : 4D.Entity
	Try
		$e:=$dc.get($params.key)
	Catch
		return This._err("QUERY_ERROR"; This._lastErrorText())
	End try
	if ($e=Null)
		return This._err("NOT_FOUND"; "No entity with key "+JSON Stringify($params.key))
	end if
	$e.fromObject($params.values)
	var $status : Object
	Try
		$status:=$e.save()
	Catch
		return This._err("INTERNAL"; This._lastErrorText())
	End try
	if (Not($status.success))
		return This._err("QUERY_ERROR"; This._statusText($status))
	end if
	return New object("data"; New object("key"; $e.getKey(); "updated"; True))

// =============================================================================
//  delete_entity  (3.6)
// =============================================================================
Function delete_entity($params : Object) : Object
	var $dc : 4D.DataClass
	$dc:=ds[String($params.dataclass)]
	if ($dc=Null)
		return This._err("QUERY_ERROR"; "Unknown dataclass: "+String($params.dataclass))
	end if
	var $e : 4D.Entity
	Try
		$e:=$dc.get($params.key)
	Catch
		return This._err("QUERY_ERROR"; This._lastErrorText())
	End try
	if ($e=Null)
		return This._err("NOT_FOUND"; "No entity with key "+JSON Stringify($params.key))
	end if
	var $key : Variant
	$key:=$e.getKey()
	var $status : Object
	Try
		$status:=$e.drop()
	Catch
		return This._err("INTERNAL"; This._lastErrorText())
	End try
	if (Not($status.success))
		return This._err("QUERY_ERROR"; This._statusText($status))
	end if
	return New object("data"; New object("key"; $key; "deleted"; True))

// =============================================================================
//  call_method  (3.7)
// =============================================================================
// The action map lives in the deployment config (METHOD_WHITELIST): action
// name -> {method, args:[{name,type,required,purpose}], return, purpose}.
// `method` is a HOST project method invoked via EXECUTE METHOD with the
// request's args bound POSITIONALLY (4D method params are positional; the
// spec's arg names are documentation for the client). Anything not in the
// map is unreachable. Arity/type validation happens in MCP_Handler gate 4;
// this function owns only execution.
Function call_method($params : Object) : Object
	var $name : Text
	$name:=String($params.name)
	var $spec : Object
	$spec:=Null
	var $config : Object
	$config:=cs.MCP_Handler.me.getConfig()
	if ($config#Null)
		if (Value type($config.METHOD_WHITELIST)=Is object)
			$spec:=$config.METHOD_WHITELIST[$name]
		end if
	end if
	if ($spec=Null)
		return This._err("CAP_DENIED"; "Action not enabled in server config: "+$name)
	end if
	var $method : Text
	$method:=String($spec.method)
	var $args : Collection
	$args:=New collection
	if (Value type($params.args)=Is collection)
		$args:=$params.args
	end if
	var $result : Variant
	Try
		Case of
			: ($args.length=0)
				EXECUTE METHOD($method; $result)
			: ($args.length=1)
				EXECUTE METHOD($method; $result; $args[0])
			: ($args.length=2)
				EXECUTE METHOD($method; $result; $args[0]; $args[1])
			: ($args.length=3)
				EXECUTE METHOD($method; $result; $args[0]; $args[1]; $args[2])
			: ($args.length=4)
				EXECUTE METHOD($method; $result; $args[0]; $args[1]; $args[2]; $args[3])
			: ($args.length=5)
				EXECUTE METHOD($method; $result; $args[0]; $args[1]; $args[2]; $args[3]; $args[4])
			: ($args.length=6)
				EXECUTE METHOD($method; $result; $args[0]; $args[1]; $args[2]; $args[3]; $args[4]; $args[5])
			else
				return This._err("BAD_PARAMS"; "Too many args (max 6)")
		End case
	Catch
		return This._err("INTERNAL"; This._lastErrorText())
	End try
	return New object("data"; New object("name"; $name; "result"; $result))

// --- Helpers ----------------------------------------------------------------

Function _projection($dcName : Text; $attributes : Variant) : Text
	if ($attributes#Null)
		if (Value type($attributes)=Is collection)
			if ($attributes.length>0)
				return $attributes.join(",")
			end if
		end if
	end if
	// default: all scalar (storage) attributes, no relations.
	// Attribute objects via datastore double-bracket ds[$name][$key]; direct
	// bracket on a DataClass throws in this 4D build.
	var $names : Collection
	$names:=New collection
	var $key : Text
	For each ($key; OB Keys(ds[$dcName]))
		var $a : Object
		$a:=ds[$dcName][$key]
		if ($a#Null)
			if ($a.kind="storage")
				$names.push($a.name)
			end if
		end if
	End for each
	return $names.join(",")

Function _err($code : Text; $message : Text) : Object
	return New object("error"; New object("code"; $code; "message"; $message))

Function _statusText($status : Object) : Text
	if ($status.statusText#Null)
		if (Length(String($status.statusText))>0)
			return String($status.statusText)
		end if
	end if
	if ($status.errors#Null)
		if ($status.errors.length>0)
			var $msgs : Collection
			$msgs:=New collection
			var $er : Object
			For each ($er; $status.errors)
				$msgs.push(String($er.message))
			End for each
			return $msgs.join("; ")
		end if
	end if
	return "Operation rejected by 4D"

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

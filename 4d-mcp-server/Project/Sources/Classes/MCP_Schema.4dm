// MCP_Schema — builds the schema digest for get_schema_digest.
//
// Sources the digest from ORDA runtime introspection (ds + DataClass +
// DataClassAttribute), filtered to the dataclasses the token may read.
// Output matches wire contract 3.1:
//   { dataclasses: [ { name, primaryKey, fields:[{name,type,key?}],
//                      relations:[{name,target,kind}] } ] }

shared singleton Class constructor()

// digest: the dataclasses the server config exposes, narrowed to the token's
// read grant ("*" = all exposed; a list intersects). callable_actions lists
// the METHOD_WHITELIST entries the token may call — the spec minus the host
// `method` name, which never crosses the wire.
Function digest($cap : Object) : Object
	var $result : Object
	$result:=New object("dataclasses"; New collection)
	var $config : Object
	$config:=cs.MCP_Handler.me.getConfig()
	var $exposed : Collection
	$exposed:=This.exposedDataclasses($config)
	var $respect : Boolean
	$respect:=($config#Null) && Bool($config.RESPECT_4D_SCHEMA)
	var $name : Text
	For each ($name; $exposed)
		if (Not(cs.MCP_Auth.me.grantCovers($cap.read; $name)))
			continue
		end if
		$result.dataclasses.push(This._dataclassDigest($name; $respect; $exposed))
	End for each
	$result.callable_actions:=This._callableActions($cap)
	return $result

// exposedDataclasses: the set of dataclass names the server config exposes.
// Precedence (config comments in 4D-mcp-config.pref are the spec):
//   - Null config -> nothing (fail closed, like every other gate)
//   - WHITELIST_TABLES non-empty -> exactly those (that exist), overriding
//     BLACKLIST_TABLES and RESPECT_4D_SCHEMA
//   - else all datastore dataclasses, minus getInfo().exposed=false ones when
//     RESPECT_4D_SCHEMA is true, minus BLACKLIST_TABLES
Function exposedDataclasses($config : Object) : Collection
	var $out : Collection
	$out:=New collection
	if ($config=Null)
		return $out
	end if
	var $name : Text
	var $wl : Variant
	$wl:=$config.WHITELIST_TABLES
	if (Value type($wl)=Is collection)
		if ($wl.length>0)
			For each ($name; $wl)
				if (ds[String($name)]#Null)
					$out.push(String($name))
				end if
			End for each
			return $out
		end if
	end if
	var $bl : Collection
	$bl:=New collection
	if (Value type($config.BLACKLIST_TABLES)=Is collection)
		$bl:=$config.BLACKLIST_TABLES
	end if
	var $respect : Boolean
	$respect:=Bool($config.RESPECT_4D_SCHEMA)
	For each ($name; OB Keys(ds))
		if ($respect) && (Not(Bool(ds[$name].getInfo().exposed)))
			continue
		end if
		if ($bl.indexOf($name)>=0)
			continue
		end if
		$out.push($name)
	End for each
	return $out

// isExposed: config-gate helper — is this dataclass in the exposed set?
Function isExposed($config : Object; $name : Text) : Boolean
	return (This.exposedDataclasses($config).indexOf($name)>=0)

// _callableActions: the intersection of the config METHOD_WHITELIST and the
// token's call capability, as client-facing specs {name, args, return, purpose}.
Function _callableActions($cap : Object) : Collection
	var $out : Collection
	$out:=New collection
	var $config : Object
	$config:=cs.MCP_Handler.me.getConfig()
	if ($config=Null)
		return $out
	end if
	if (Not(Bool($config.ALLOW_CALL_METHOD)))
		return $out
	end if
	if (Value type($config.METHOD_WHITELIST)#Is object)
		return $out
	end if
	var $callable : Collection
	$callable:=$cap.call
	if ($callable=Null)
		return $out
	end if
	var $name : Text
	For each ($name; $config.METHOD_WHITELIST)
		if ($callable.indexOf($name)<0)
			continue
		end if
		var $spec : Object
		$spec:=$config.METHOD_WHITELIST[$name]
		var $entry : Object
		$entry:=New object("name"; $name)
		$entry.args:=$spec.args
		$entry.return:=$spec.return
		$entry.purpose:=$spec.purpose
		$out.push($entry)
	End for each
	return $out

// $name is the dataclass name. Attribute objects are accessed dynamically via
// ds[$name][$key] — bracket access directly on a DataClass (ds.X[$key]) throws
// in this 4D build, but datastore double-bracket works.
// $respect: when true, storage fields whose attribute is not exposed
// (hide_in_REST in the catalog — the `exposed` property is then absent) are
// omitted. Relations are always omitted when their target dataclass is not in
// $exposed, and additionally when the relation attribute itself is unexposed
// while $respect is on — never advertise a path the client cannot follow.
Function _dataclassDigest($name : Text; $respect : Boolean; $exposed : Collection) : Object
	var $dc : 4D.DataClass
	$dc:=ds[$name]
	var $info : Object
	$info:=$dc.getInfo()
	var $pk : Text
	$pk:=String($info.primaryKey)
	var $out : Object
	$out:=New object
	$out.name:=$info.name
	$out.primaryKey:=$info.primaryKey
	$out.fields:=New collection
	$out.relations:=New collection

	// OB Keys on a DataClass returns only its attribute names. Access each
	// attribute object via ds[$name][$key] and branch on .kind. (OB Instance of
	// with 4D.DataClassAttribute is avoided: that class ref does not resolve in
	// this 4D build.)
	var $key : Text
	For each ($key; OB Keys($dc))
		var $attr : Object
		$attr:=ds[$name][$key]
		if ($attr=Null)
			continue
		end if
		if ($respect) && (Not(Bool($attr.exposed)))
			continue
		end if
		Case of
			: ($attr.kind="storage")
				var $f : Object
				$f:=New object("name"; $attr.name; "type"; $attr.type)
				if ($attr.name=$pk)
					$f.key:=True
				end if
				$out.fields.push($f)
			: ($attr.kind="relatedEntity")
				if ($exposed.indexOf(String($attr.relatedDataClass))<0)
					continue
				end if
				$out.relations.push(New object(\
					"name"; $attr.name; "target"; $attr.relatedDataClass; "kind"; "many-to-one"))
			: ($attr.kind="relatedEntities")
				if ($exposed.indexOf(String($attr.relatedDataClass))<0)
					continue
				end if
				$out.relations.push(New object(\
					"name"; $attr.name; "target"; $attr.relatedDataClass; "kind"; "one-to-many"))
		End case
	End for each
	return $out

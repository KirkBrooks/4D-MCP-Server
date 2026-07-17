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

// exposedDataclasses: the set of dataclass names the server config exposes,
// returned in the datastore's canonical casing. Precedence (config comments in
// 4D-mcp-config.pref are the spec):
//   - Null config -> nothing (fail closed, like every other gate)
//   - WHITELIST_TABLES present but malformed (not a list or string) -> nothing
//   - WHITELIST_TABLES non-empty -> exactly those (that resolve), overriding
//     BLACKLIST_TABLES and RESPECT_4D_SCHEMA
//   - else all datastore dataclasses, minus getInfo().exposed=false ones when
//     RESPECT_4D_SCHEMA is true, minus BLACKLIST_TABLES
// Config table names are matched case-INSENSITIVELY (ds[...] resolution is), so
// a blacklist/whitelist typo of the wrong case cannot silently fail open.
Function exposedDataclasses($config : Object) : Collection
	var $out : Collection
	$out:=New collection
	if ($config=Null)
		return $out
	end if
	// lowercase -> canonical name map of every dataclass
	var $canon : Object
	$canon:=New object
	var $k : Text
	For each ($k; OB Keys(ds))
		$canon[Lowercase($k)]:=$k
	End for each

	var $wl : Collection
	$wl:=This._nameList($config.WHITELIST_TABLES)
	if ($wl=Null)
		return $out  // present but malformed -> expose nothing (fail closed)
	end if
	if ($wl.length>0)
		var $wn : Text
		For each ($wn; $wl)
			var $realW : Text
			$realW:=String($canon[Lowercase(String($wn))])
			if ($realW#"") && ($out.indexOf($realW)<0)
				$out.push($realW)
			end if
		End for each
		return $out
	end if

	var $bl : Collection
	$bl:=This._nameList($config.BLACKLIST_TABLES)
	if ($bl=Null)
		return $out  // malformed blacklist -> expose nothing (fail closed)
	end if
	var $blLower : Collection
	$blLower:=New collection
	var $b : Text
	For each ($b; $bl)
		$blLower.push(Lowercase(String($b)))
	End for each

	var $respect : Boolean
	$respect:=Bool($config.RESPECT_4D_SCHEMA)
	var $name : Text
	For each ($name; OB Keys(ds))
		if ($respect) && (Not(Bool(ds[$name].getInfo().exposed)))
			continue
		end if
		if ($blLower.indexOf(Lowercase($name))>=0)
			continue
		end if
		$out.push($name)
	End for each
	return $out

// _nameList: coerce a config table-list value to a collection of names.
//   Null/absent or "" -> empty collection (setting not in use)
//   collection        -> as-is
//   non-empty text    -> single-element collection (common admin error)
//   any other type    -> Null (malformed; callers fail closed)
Function _nameList($v : Variant) : Collection
	if ($v=Null)
		return New collection
	end if
	Case of
		: (Value type($v)=Is collection)
			return $v
		: (Value type($v)=Is text)
			if (Length($v)=0)
				return New collection
			end if
			return New collection($v)
	End case
	return Null

// isExposed: config-gate helper — is this dataclass in the exposed set?
// Case-insensitive, matching ds[...] resolution.
Function isExposed($config : Object; $name : Text) : Boolean
	var $exposed : Collection
	$exposed:=This.exposedDataclasses($config)
	var $e : Text
	For each ($e; $exposed)
		if (Lowercase($e)=Lowercase($name))
			return True
		end if
	End for each
	return False

// forbiddenQueryField: with RESPECT_4D_SCHEMA on, a query may not reference an
// unexposed field or a relation/dotted path in its `filter` or `orderBy` — else
// the query engine reads a hidden field the projection would strip, turning it
// into a value oracle (meta.total leaks equality/range results). Returns the
// offending identifier, or "" when the query is clean (or respect is off).
// Identifiers are matched against the dataclass's own storage attributes;
// unknown tokens (operators, functions, keywords) are left alone.
Function forbiddenQueryField($dcName : Text; $filter : Variant; $orderBy : Variant; $config : Object) : Text
	if ($config=Null) || (Not(Bool($config.RESPECT_4D_SCHEMA)))
		return ""
	end if
	// lowercase attribute map for the dataclass: name -> {kind, exposed}. Built
	// once, so field checks are case-insensitive (matching ds[...] resolution).
	var $attrs : Object
	$attrs:=New object
	var $key : Text
	For each ($key; OB Keys(ds[$dcName]))
		var $a : Object
		$a:=ds[$dcName][$key]
		if ($a#Null)
			$attrs[Lowercase(String($a.name))]:=$a
		end if
	End for each

	var $tok : Text
	For each ($tok; This._identifiers(String($filter)))
		var $bad : Text
		$bad:=This._fieldForbidden($attrs; $tok)
		if (Length($bad)>0)
			return $bad
		end if
	End for each
	// orderBy: comma list of "field [asc|desc]"; asc/desc are keywords, not
	// fields. Everything else runs through the same field check.
	For each ($tok; This._identifiers(String($orderBy)))
		if ($tok="asc") | ($tok="desc")
			continue
		end if
		var $badO : Text
		$badO:=This._fieldForbidden($attrs; $tok)
		if (Length($badO)>0)
			return $badO
		end if
	End for each
	return ""

// _fieldForbidden: "" if $tok (already lowercased) is safe to reference, else
// the offending name. A dotted path (relation traversal) is always forbidden;
// a bare name is forbidden when it resolves to a relation attribute or an
// UNEXPOSED storage attribute. Names that aren't attributes at all
// (keywords/functions/unquoted values) are safe.
Function _fieldForbidden($attrs : Object; $tok : Text) : Text
	if (Position("."; $tok)>0)
		return $tok  // relation/dotted path — no field-level traversal
	end if
	var $a : Object
	$a:=$attrs[$tok]
	if ($a=Null)
		return ""
	end if
	if ($a.kind#"storage")
		return $tok  // a relation attribute referenced by name
	end if
	if (Not(Bool($a.exposed)))
		return $tok
	end if
	return ""

// _identifiers: identifier-like tokens in an ORDA query string, with quoted
// string literals removed first (so a quoted value can't be mistaken for a
// field) and numeric tokens skipped. Tokens keep interior dots so relation
// paths ("orders.total") survive as one identifier for _fieldForbidden.
Function _identifiers($s : Text) : Collection
	var $out : Collection
	$out:=New collection
	if (Length($s)=0)
		return $out
	end if
	// strip quoted literals (single and double), tracking quote state
	var $clean : Text
	$clean:=""
	var $q : Text
	$q:=""  // current open quote char, "" when outside a literal
	var $i : Integer
	For ($i; 1; Length($s))
		var $c : Text
		$c:=Substring($s; $i; 1)
		if ($q#"")
			if ($c=$q)
				$q:=""
			end if
		else
			if ($c="'") | ($c=Char(Double quote))
				$q:=$c
			else
				$clean:=$clean+$c
			end if
		end if
	End for
	// split on any char that can't be part of an identifier-or-path
	var $cur : Text
	$cur:=""
	For ($i; 1; Length($clean)+1)
		var $ch : Text
		$ch:=""
		if ($i<=Length($clean))
			$ch:=Substring($clean; $i; 1)
		end if
		if (This._isIdentChar($ch))
			$cur:=$cur+$ch
		else
			if (Length($cur)>0)
				// skip pure numbers (e.g. 3.14, placeholders already gone)
				if (Not(This._isNumeric($cur)))
					$out.push(Lowercase($cur))
				end if
				$cur:=""
			end if
		end if
	End for
	return $out

Function _isIdentChar($c : Text) : Boolean
	if (Length($c)=0)
		return False
	end if
	var $n : Integer
	$n:=Character code($c)
	Case of
		: ($n>=65) & ($n<=90)  // A-Z
			return True
		: ($n>=97) & ($n<=122)  // a-z
			return True
		: ($n>=48) & ($n<=57)  // 0-9
			return True
		: ($c="_") | ($c=".")
			return True
	End case
	return False

Function _isNumeric($t : Text) : Boolean
	var $i : Integer
	For ($i; 1; Length($t))
		var $n : Integer
		$n:=Character code(Substring($t; $i; 1))
		if (($n<48) | ($n>57)) & (Substring($t; $i; 1)#".")
			return False
		end if
	End for
	return True

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

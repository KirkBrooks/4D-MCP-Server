// MCP_Config — read / merge / validate / write the deployment config document,
// 4D-mcp-config.pref. This is the *editing* half of the config story; the
// serving half is MCP_Handler.getConfig(), which flattens {comment, value} to
// {value} and fails closed. Nothing here is ever called on the request path.
//
// The document format is the file's contract:  { KEY: {comment, value}, ... }
// with keys starting "_" reserved for documentation. Editing must preserve
// BOTH halves — an admin who improved a comment, or a newer build that added a
// key this UI doesn't know about, must not lose it on save. So every function
// here works on the RAW document (comments intact) and only ever assigns to
// .value.
//
// Where the file lives: the live config is the HOST's Project/Sources copy; the
// component's Resources copy is only the shipping template that getConfig()
// clones on first read. Both paths come from MCP_Handler so the editor and the
// loader can never disagree about which file is authoritative.

shared singleton Class constructor()

// =============================================================================
//  File locations
// =============================================================================

Function hostFile() : 4D.File
	return cs.MCP_Handler.me._configFile()

Function componentFile() : 4D.File
	return cs.MCP_Handler.me._defaultConfigFile()

// fileFor: "component" = the shipping template inside the component's
// Resources (read-only once the component is compiled into a .4dz);
// anything else = the host's live copy.
Function fileFor($target : Text) : 4D.File
	if (This.isComponentTarget($target))
		return This.componentFile()
	end if
	return This.hostFile()

Function isComponentTarget($target : Text) : Boolean
	// Compared by length + exact content: 4D's text "=" treats @ as a wildcard.
	return (Length(String($target))=9) && (Lowercase(String($target))="component")

// =============================================================================
//  Read / write
// =============================================================================

// readDoc: the raw {KEY:{comment,value}} document, or Null when the file is
// absent, unreadable or not a JSON object. Callers decide what to do about it —
// unlike getConfig(), this half of the system does not fail closed silently.
Function readDoc($file : 4D.File) : Object
	if ($file=Null)
		return Null
	end if
	if (Not($file.exists))
		return Null
	end if
	var $raw : Variant
	$raw:=Try(JSON Parse($file.getText()))
	if ($raw=Null)
		return Null
	end if
	if (Value type($raw)#Is object)
		return Null
	end if
	return $raw

Function defaultDoc() : Object
	return This.readDoc(This.componentFile())

// writeDoc: pretty-printed JSON, parent folder created if needed. Returns ""
// on success, else the error text (a compiled component's own Resources are
// read-only, so "save to component" legitimately fails).
Function writeDoc($file : 4D.File; $doc : Object) : Text
	if ($file=Null)
		return "No file to write to."
	end if
	if ($doc=Null)
		return "Nothing to write."
	end if
	Try
		$file.parent.create()
		$file.setText(JSON Stringify($doc; *))
	Catch
		return This._lastErrorText()
	End try
	return ""

// =============================================================================
//  Document shape
// =============================================================================

// valueOf: the .value for a key, or $fallback when the key is absent or its
// entry is malformed.
Function valueOf($doc : Object; $key : Text; $fallback : Variant) : Variant
	if ($doc=Null)
		return $fallback
	end if
	var $entry : Variant
	$entry:=$doc[$key]
	if ($entry=Null)
		return $fallback
	end if
	if (Value type($entry)#Is object)
		return $fallback
	end if
	if ($entry.value=Null)
		return $fallback
	end if
	return $entry.value

// setValue: assign .value, keeping the existing comment. A key that isn't in
// the document yet is created with the comment the component ships for it, so
// a config rebuilt from a partial file still documents itself.
Function setValue($doc : Object; $key : Text; $value : Variant)
	if ($doc=Null)
		return
	end if
	if (Value type($doc[$key])=Is object)
		$doc[$key].value:=$value
		return
	end if
	var $comment : Text
	$comment:=""
	var $def : Object
	$def:=This.defaultDoc()
	if ($def#Null) && (Value type($def[$key])=Is object)
		$comment:=String($def[$key].comment)
	end if
	$doc[$key]:=New object("comment"; $comment; "value"; $value)

// flatten: the { KEY: value } view MCP_Handler.getConfig() serves, built from
// an in-memory document. Used for validation and for the "effective settings"
// the UI previews — it does NOT fail closed on a malformed entry (validate()
// reports those instead); the entry is simply skipped.
Function flatten($doc : Object) : Object
	var $out : Object
	$out:=New object
	if ($doc=Null)
		return $out
	end if
	var $key : Text
	For each ($key; $doc)
		if (Substring($key; 1; 1)="_")
			continue
		end if
		if (Value type($doc[$key])#Is object)
			continue
		end if
		$out[$key]:=$doc[$key].value
	End for each
	return $out

// mergeMissing: bring the document up to the component's shipping key set and
// re-order it to match, so a file written by an older build gains the newer
// settings (at their default values) instead of silently running without them.
// Existing entries are carried over BY REFERENCE — edited comments survive.
// Unknown keys are kept, after the known ones. Returns the names added.
Function mergeMissing($doc : Object) : Collection
	var $added : Collection
	$added:=New collection
	if ($doc=Null)
		return $added
	end if
	var $def : Object
	$def:=This.defaultDoc()
	if ($def=Null)
		return $added  // no template to merge from — leave the document alone
	end if

	var $out : Object
	$out:=New object
	var $key : Text
	For each ($key; $def)
		if ($doc[$key]#Null)
			$out[$key]:=$doc[$key]
		else
			$out[$key]:=$def[$key]
			if (Substring($key; 1; 1)#"_")
				$added.push($key)
			end if
		end if
	End for each
	For each ($key; $doc)
		if ($out[$key]=Null)
			$out[$key]:=$doc[$key]
		end if
	End for each

	// Rewrite $doc in place: the form holds this reference, so replacing the
	// object would strand the UI on the old one.
	var $existing : Collection
	$existing:=OB Keys($doc)
	For each ($key; $existing)
		OB REMOVE($doc; $key)
	End for each
	For each ($key; $out)
		$doc[$key]:=$out[$key]
	End for each
	return $added

// =============================================================================
//  Vocabularies (the values the UI offers; the comments in the .pref are spec)
// =============================================================================

Function argTypes() : Collection
	return New collection("text"; "number"; "boolean"; "object"; "collection")

Function logLevels() : Collection
	return New collection("off"; "error"; "info"; "debug")

Function tokenStores() : Collection
	return New collection("inline"; "table")

// wireMaxLimit: the page-size ceiling fixed by wire contract v1. MAX_LIMIT may
// be set lower than this, never higher.
Function wireMaxLimit() : Integer
	return 80

// dataclassNames: the host datastore's dataclasses, or an empty collection when
// there is no datastore to look at (never throws — the settings window has to
// open even on a host with no structure).
Function dataclassNames() : Collection
	var $out : Collection
	$out:=New collection
	Try
		var $name : Text
		For each ($name; OB Keys(ds))
			$out.push($name)
		End for each
	Catch
	End try
	return $out

// =============================================================================
//  Validation
// =============================================================================
// Returns a collection of { severity: "error"|"warning"; key; message }.
// Errors block a save (they would make getConfig fail closed, or hand the
// gates a value they can't honour); warnings are surfaced but never block —
// "ALLOW_WRITE is on" is a deliberate choice, not a mistake.

Function validate($doc : Object) : Collection
	var $out : Collection
	$out:=New collection
	if ($doc=Null)
		$out.push(This._issue("error"; ""; "The config document could not be read."))
		return $out
	end if

	// --- structure: every non-"_" entry must be {comment, value} -------------
	var $key : Text
	For each ($key; $doc)
		if (Substring($key; 1; 1)="_")
			continue
		end if
		if (Value type($doc[$key])#Is object)
			$out.push(This._issue("error"; $key; \
				$key+" is not a {comment, value} entry — getConfig() refuses to load the whole file when any entry is malformed."))
		end if
	End for each

	var $c : Object
	$c:=This.flatten($doc)

	// --- unknown keys --------------------------------------------------------
	var $def : Object
	$def:=This.defaultDoc()
	if ($def#Null)
		For each ($key; $doc)
			if (Substring($key; 1; 1)="_")
				continue
			end if
			if ($def[$key]=Null)
				$out.push(This._issue("warning"; $key; \
					$key+" is not a setting this build recognises. It is kept in the file, but nothing reads it."))
			end if
		End for each
	end if

	// --- server --------------------------------------------------------------
	if (Not(Bool($c.ENABLED)))
		$out.push(This._issue("warning"; "ENABLED"; \
			"ENABLED is off — the component loads but answers every request with 403 CAP_DENIED."))
	end if
	var $port : Real
	$port:=Num($c.HTTP_PORT)
	if (($port<0) || ($port>65535) || ($port#Int($port)))
		$out.push(This._issue("error"; "HTTP_PORT"; "HTTP_PORT must be a whole number between 0 and 65535."))
	end if
	if (Num($c.MAX_BODY_SIZE)<0)
		$out.push(This._issue("error"; "MAX_BODY_SIZE"; "MAX_BODY_SIZE cannot be negative (0 = unlimited)."))
	end if
	if (Not(Bool($c.REQUIRE_HTTPS)))
		$out.push(This._issue("warning"; "REQUIRE_HTTPS"; \
			"REQUIRE_HTTPS is off — tokens will cross the wire in clear text. Local development only."))
	end if

	// --- verb gates ----------------------------------------------------------
	if (Bool($c.ALLOW_WRITE))
		$out.push(This._issue("warning"; "ALLOW_WRITE"; "ALLOW_WRITE is on — clients can create and update entities."))
	end if
	if (Bool($c.ALLOW_DELETE))
		$out.push(This._issue("warning"; "ALLOW_DELETE"; "ALLOW_DELETE is on — clients can delete entities."))
	end if

	// --- paging --------------------------------------------------------------
	var $maxLimit : Real
	$maxLimit:=Num($c.MAX_LIMIT)
	if ($maxLimit<1)
		$out.push(This._issue("error"; "MAX_LIMIT"; "MAX_LIMIT must be at least 1."))
	end if
	if ($maxLimit>This.wireMaxLimit())
		$out.push(This._issue("error"; "MAX_LIMIT"; \
			"MAX_LIMIT may not exceed "+String(This.wireMaxLimit())+" — wire contract v1 fixes the ceiling."))
	end if
	var $defLimit : Real
	$defLimit:=Num($c.DEFAULT_LIMIT)
	if ($defLimit<1)
		$out.push(This._issue("error"; "DEFAULT_LIMIT"; "DEFAULT_LIMIT must be at least 1."))
	end if
	if ($defLimit>$maxLimit)
		$out.push(This._issue("error"; "DEFAULT_LIMIT"; "DEFAULT_LIMIT cannot be larger than MAX_LIMIT."))
	end if

	// --- table exposure ------------------------------------------------------
	$out:=$out.combine(This._validateTableList($c; "WHITELIST_TABLES"))
	$out:=$out.combine(This._validateTableList($c; "BLACKLIST_TABLES"))
	if ((Value type($c.WHITELIST_TABLES)=Is collection) && ($c.WHITELIST_TABLES.length>0))
		if ((Value type($c.BLACKLIST_TABLES)=Is collection) && ($c.BLACKLIST_TABLES.length>0))
			$out.push(This._issue("warning"; "BLACKLIST_TABLES"; \
				"BLACKLIST_TABLES is ignored while WHITELIST_TABLES is non-empty."))
		end if
		if (Bool($c.RESPECT_4D_SCHEMA))
			$out.push(This._issue("warning"; "WHITELIST_TABLES"; \
				"A non-empty WHITELIST_TABLES also overrides RESPECT_4D_SCHEMA — listed dataclasses are exposed even if the structure hides them."))
		end if
	else
		if (Not(Bool($c.RESPECT_4D_SCHEMA)))
			$out.push(This._issue("warning"; "RESPECT_4D_SCHEMA"; \
				"RESPECT_4D_SCHEMA is off and no whitelist is set — every table and field in the host is exposed."))
		end if
	end if

	// --- tokens & rate -------------------------------------------------------
	var $store : Text
	$store:=String($c.TOKEN_STORE)
	if (This.tokenStores().indexOf($store)<0)
		$out.push(This._issue("error"; "TOKEN_STORE"; "TOKEN_STORE must be one of: "+This.tokenStores().join(", ")+"."))
	end if
	if ($store="table")
		if (Length(String($c.TOKEN_TABLE))=0)
			$out.push(This._issue("error"; "TOKEN_TABLE"; "TOKEN_STORE is \"table\" but TOKEN_TABLE names no dataclass."))
		else
			if (Not(This._dataclassExists(String($c.TOKEN_TABLE))))
				$out.push(This._issue("warning"; "TOKEN_TABLE"; \
					"No dataclass named "+String($c.TOKEN_TABLE)+" in the host datastore."))
			end if
		end if
	end if
	if (Num($c.RATE_LIMIT)<0)
		$out.push(This._issue("error"; "RATE_LIMIT"; "RATE_LIMIT cannot be negative (0 = unlimited)."))
	end if

	// --- logging -------------------------------------------------------------
	if (This.logLevels().indexOf(String($c.LOG_LEVEL))<0)
		$out.push(This._issue("error"; "LOG_LEVEL"; "LOG_LEVEL must be one of: "+This.logLevels().join(", ")+"."))
	end if

	// --- callable methods ----------------------------------------------------
	$out:=$out.combine(This._validateWhitelist($c))
	return $out

// _validateTableList: WHITELIST_TABLES / BLACKLIST_TABLES must be a collection
// of dataclass names. MCP_Schema fails CLOSED on a malformed list (it exposes
// nothing at all), so a wrong type here is an error, not a warning.
Function _validateTableList($c : Object; $key : Text) : Collection
	var $out : Collection
	$out:=New collection
	var $v : Variant
	$v:=$c[$key]
	if ($v=Null)
		return $out
	end if
	if (Value type($v)#Is collection)
		$out.push(This._issue("error"; $key; $key+" must be a list of dataclass names — anything else exposes nothing at all."))
		return $out
	end if
	var $name : Variant
	For each ($name; $v)
		if (Value type($name)#Is text)
			$out.push(This._issue("error"; $key; $key+" contains an entry that is not a dataclass name."))
			continue
		end if
		if (Length(String($name))=0)
			$out.push(This._issue("error"; $key; $key+" contains an empty name."))
			continue
		end if
		if (Not(This._dataclassExists(String($name))))
			$out.push(This._issue("warning"; $key; \
				$key+": no dataclass named "+String($name)+" in the host datastore."))
		end if
	End for each
	return $out

// _validateWhitelist: METHOD_WHITELIST is the highest-risk setting in the file —
// each entry is a door into host code — so it gets the strictest check.
Function _validateWhitelist($c : Object) : Collection
	var $out : Collection
	$out:=New collection
	var $wl : Variant
	$wl:=$c.METHOD_WHITELIST
	if ($wl=Null)
		return $out
	end if
	if (Value type($wl)#Is object)
		$out.push(This._issue("error"; "METHOD_WHITELIST"; "METHOD_WHITELIST must be an object mapping action name to spec."))
		return $out
	end if

	var $names : Collection
	$names:=OB Keys($wl)
	if (Bool($c.ALLOW_CALL_METHOD))
		if ($names.length=0)
			$out.push(This._issue("warning"; "METHOD_WHITELIST"; \
				"ALLOW_CALL_METHOD is on but no actions are listed — call_method has nothing to reach."))
		else
			$out.push(This._issue("warning"; "METHOD_WHITELIST"; \
				String($names.length)+" host method(s) are callable by clients holding a matching token."))
		end if
	else
		if ($names.length>0)
			$out.push(This._issue("warning"; "METHOD_WHITELIST"; \
				"ALLOW_CALL_METHOD is off, so these "+String($names.length)+" action(s) are ignored entirely."))
		end if
	end if

	var $types : Collection
	$types:=This.argTypes()
	var $name : Text
	For each ($name; $names)
		if (Length($name)=0)
			$out.push(This._issue("error"; "METHOD_WHITELIST"; "An action has an empty name."))
			continue
		end if
		var $spec : Variant
		$spec:=$wl[$name]
		if (Value type($spec)#Is object)
			$out.push(This._issue("error"; "METHOD_WHITELIST"; $name+": the spec must be an object."))
			continue
		end if
		if (Length(String($spec.method))=0)
			$out.push(This._issue("error"; "METHOD_WHITELIST"; $name+": no host method named — call_method would have nothing to execute."))
		end if
		if ($spec.args=Null)
			continue
		end if
		if (Value type($spec.args)#Is collection)
			$out.push(This._issue("error"; "METHOD_WHITELIST"; $name+": args must be an ordered list."))
			continue
		end if
		var $seenOptional : Boolean
		$seenOptional:=False
		var $i : Integer
		$i:=0
		var $arg : Variant
		For each ($arg; $spec.args)
			$i:=$i+1
			if (Value type($arg)#Is object)
				$out.push(This._issue("error"; "METHOD_WHITELIST"; $name+": argument "+String($i)+" is not an object."))
				continue
			end if
			if (Length(String($arg.name))=0)
				$out.push(This._issue("warning"; "METHOD_WHITELIST"; \
					$name+": argument "+String($i)+" has no name (documentation only, but clients see it)."))
			end if
			if ($types.indexOf(String($arg.type))<0)
				$out.push(This._issue("error"; "METHOD_WHITELIST"; \
					$name+": argument "+String($i)+" has type \""+String($arg.type)+"\" — must be one of "+$types.join(", ")+"."))
			end if
			if (Bool($arg.required))
				if ($seenOptional)
					$out.push(This._issue("error"; "METHOD_WHITELIST"; \
						$name+": required argument "+String($i)+" follows an optional one. 4D binds args positionally, so optional args must be trailing."))
				end if
			else
				$seenOptional:=True
			end if
		End for each
	End for each
	return $out

// =============================================================================
//  Helpers
// =============================================================================

Function _issue($severity : Text; $key : Text; $message : Text) : Object
	return New object("severity"; $severity; "key"; $key; "message"; $message)

// _dataclassExists: case-insensitive, matching ds[...] resolution — the same
// leniency MCP_Schema applies when it resolves config table names.
Function _dataclassExists($name : Text) : Boolean
	var $all : Collection
	$all:=This.dataclassNames()
	if ($all.length=0)
		return True  // no datastore to check against: don't cry wolf
	end if
	var $n : Text
	For each ($n; $all)
		if (Lowercase($n)=Lowercase($name))
			return True
		end if
	End for each
	return False

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

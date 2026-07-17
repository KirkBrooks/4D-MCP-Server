// MCP_Auth — resolves a Bearer token to a capability object.
//
// v1 backs the token store with an in-memory config object (see _loadTokens).
// To make storage swappable, replace ONLY _loadTokens() with a table lookup
// (e.g. ds.MCP_Token.query(...)) returning the same capability shape.
//
// Capability shape (wire contract 2):
//   { token_id: Text; read: []Text | "*"; write: []Text | "*"; call: []Text }
// read/write may be the wildcard "*" — every dataclass the server config
// exposes (RESPECT_4D_SCHEMA / WHITELIST_TABLES / BLACKLIST_TABLES). Exposure
// is enforced upstream by the config gate; the wildcard never widens it.
// Absent verb entry is normalized to an empty collection (no access).

shared singleton Class constructor()

// validate: returns the normalized capability object, or Null if the token
// is missing / unknown. Never throws.
Function validate($token : Text) : Object
	if ($token=Null)
		return Null
	end if
	if (Length(String($token))=0)
		return Null
	end if
	var $tokens : Object
	$tokens:=This._loadTokens()
	var $cap : Object
	$cap:=$tokens[$token]
	if ($cap=Null)
		return Null
	end if
	return This._normalize($cap)

// _loadTokens: the ONLY function to replace when moving to a table-backed
// store. Keys are the raw bearer strings; values are capability objects.
Function _loadTokens() : Object
	var $t : Object
	$t:=New object
	// Full access: read both dataclasses, write Order, call two actions.
	$t["SECRET_FULL"]:=New object(\
		"token_id"; "tok_full"; \
		"read"; New collection("Customer"; "Order"); \
		"write"; New collection("Order"); \
		"call"; New collection("ping"; "order_count"; "echo_upper"))
	// Read-only, Customer only: no write, no call.
	$t["SECRET_RO"]:=New object(\
		"token_id"; "tok_ro"; \
		"read"; New collection("Customer"); \
		"write"; New collection; \
		"call"; New collection)
	// HPC4d trial: read-only on core business tables. Deliberately excludes
	// payroll, passwords, W2 and other sensitive dataclasses.
	$t["SECRET_HPC_RO"]:=New object(\
		"token_id"; "tok_hpc_ro"; \
		"read"; New collection("customers"; "workOrder"; "lineItem"; "header"); \
		"write"; New collection; \
		"call"; New collection)
	// Wildcard: read/write everything the server config exposes. Exposure
	// (RESPECT_4D_SCHEMA / WHITELIST / BLACKLIST) is the only table filter.
	$t["SECRET_STAR"]:=New object(\
		"token_id"; "tok_star"; \
		"read"; "*"; \
		"write"; "*"; \
		"call"; New collection("ping"; "order_count"; "echo_upper"))
	return $t

Function _normalize($cap : Object) : Object
	var $out : Object
	$out:=New object
	$out.token_id:=String($cap.token_id)
	$out.read:=This._asGrant($cap.read)
	$out.write:=This._asGrant($cap.write)
	$out.call:=This._asCollection($cap.call)
	return $out

// _asGrant: a read/write grant is either the wildcard "*" or a collection of
// dataclass names. Anything else (absent, wrong type, other strings) normalizes
// to an empty collection — no access.
Function _asGrant($v : Variant) : Variant
	if (Value type($v)=Is text)
		if (This._isStar($v))
			return "*"
		end if
		return New collection
	end if
	return This._asCollection($v)

// _isStar: exact match for "*" — 4D's text `=` treats @ as a wildcard, so a
// literal comparison could be fooled by "@"; compare by length + char code.
Function _isStar($v : Text) : Boolean
	return (Length($v)=1) && (Character code($v)=42)

// grantCovers: does a normalized read/write grant cover this dataclass name?
// Exposure is NOT checked here — the config gate owns that; a wildcard grant
// covers every name and relies on the exposure gate to bound it.
Function grantCovers($grant : Variant; $name : Text) : Boolean
	if (Value type($grant)=Is text)
		return This._isStar($grant)
	end if
	if (Value type($grant)#Is collection)
		return False
	end if
	return ($grant.indexOf($name)>=0)

Function _asCollection($v : Variant) : Collection
	if ($v=Null)
		return New collection
	end if
	if (Value type($v)#Is collection)
		return New collection
	end if
	return $v

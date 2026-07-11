// MCP_Schema — builds the schema digest for get_schema_digest.
//
// Sources the digest from ORDA runtime introspection (ds + DataClass +
// DataClassAttribute), filtered to the dataclasses the token may read.
// Output matches wire contract 3.1:
//   { dataclasses: [ { name, primaryKey, fields:[{name,type,key?}],
//                      relations:[{name,target,kind}] } ] }

shared singleton Class constructor()

// digest: filtered to $cap.read. A dataclass in the read list that no longer
// exists in the datastore is silently skipped.
Function digest($cap : Object) : Object
	var $result : Object
	$result:=New object("dataclasses"; New collection)
	var $readable : Collection
	$readable:=$cap.read
	if ($readable=Null)
		return $result
	end if
	var $name : Text
	For each ($name; $readable)
		var $dc : 4D.DataClass
		$dc:=ds[$name]
		if ($dc=Null)
			continue
		end if
		$result.dataclasses.push(This._dataclassDigest($name))
	End for each
	return $result

// $name is the dataclass name. Attribute objects are accessed dynamically via
// ds[$name][$key] — bracket access directly on a DataClass (ds.X[$key]) throws
// in this 4D build, but datastore double-bracket works.
Function _dataclassDigest($name : Text) : Object
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
		Case of
			: ($attr.kind="storage")
				var $f : Object
				$f:=New object("name"; $attr.name; "type"; $attr.type)
				if ($attr.name=$pk)
					$f.key:=True
				end if
				$out.fields.push($f)
			: ($attr.kind="relatedEntity")
				$out.relations.push(New object(\
					"name"; $attr.name; "target"; $attr.relatedDataClass; "kind"; "many-to-one"))
			: ($attr.kind="relatedEntities")
				$out.relations.push(New object(\
					"name"; $attr.name; "target"; $attr.relatedDataClass; "kind"; "one-to-many"))
		End case
	End for each
	return $out

// MCP_Settings — per-window controller for the MCP_Settings dialog. One
// instance per open sheet, attached to Form.settings by MCP_Open_Settings; the
// form method delegates every event to handleEvent(). Mirrors the AIDSettings
// pattern used elsewhere in this codebase.
//
// The controller owns ONE authoritative object: `doc`, the raw
// {KEY:{comment,value}} document read from disk. The form-side fields (Form.*)
// are a flattened, typed *projection* of it, rebuilt by _pushToForm() whenever
// doc changes and read back into doc by _pullFromForm() before validate / save.
// Working this way (not editing Form.* directly against the file) is what lets
// the JSON tab, the table matrix and the method editor all stay in step, and
// what preserves comments and unknown keys across a save.
//
// Save targets: the host's live copy by default; the component's Resources
// template only when the admin explicitly picks it (and only in dev — a
// compiled component's Resources are read-only, which writeDoc() reports).

property config : cs.MCP_Config
property doc : Object  // raw {KEY:{comment,value}} — the authoritative state
property target : Text  // "host" | "component"
property dirty : Boolean

Class constructor()
	This.config:=cs.MCP_Config.me
	This.target:="host"
	This.dirty:=False
	This.doc:=New object

	// =============================================================================
	//  Form-data build
	// =============================================================================

// buildFormData: the object passed to DIALOG. Reads the chosen file into `doc`,
// then projects it onto the Form.* fields the form binds to.
Function buildFormData() : Object
	This._loadTarget(This.target)

	var $fd : Object
	$fd:=New object("settings"; This)
	$fd.currentTab:=0
	$fd.targetDD:=This._targetDD()
	This._writeInto($fd)
	return $fd

// _loadTarget: (re)read the file for a target into `doc`. A file that doesn't
// exist yet (host with no config saved) starts from the component's shipping
// template so the admin edits a fully-populated document, not a blank one.
Function _loadTarget($target : Text)
	This.target:=$target
	var $file : 4D.File
	$file:=This.config.fileFor($target)
	var $loaded : Object
	$loaded:=This.config.readDoc($file)
	if ($loaded=Null)
		$loaded:=This.config.defaultDoc()
		if ($loaded=Null)
			$loaded:=New object
		end if
	end if
	This.doc:=$loaded
	This.dirty:=False

	// =============================================================================
	//  Projection: doc -> Form.*  and  Form.* -> doc
	// =============================================================================

// _pushToForm: refresh every Form.* field from `doc`. Called after any change
// that edits doc structurally (target switch, reload, rule change, method edit).
Function _pushToForm()
	if (Form=Null)
		return
	end if
	This._writeInto(Form)

// _writeInto: the single place that knows the doc-key -> form-field mapping.
// Used both for the initial DIALOG data ($fd) and for later refreshes (Form).
Function _writeInto($f : Object)
	var $c : Object
	$c:=This.config.flatten(This.doc)

	// -- Server ---------------------------------------------------------------
	$f.enabled:=Bool($c.ENABLED)
	$f.httpPort:=Num($c.HTTP_PORT)
	$f.requireHttps:=Bool($c.REQUIRE_HTTPS)
	$f.maxBodySize:=Num($c.MAX_BODY_SIZE)
	$f.runtimeStatus:=This._runtimeStatusText()

	// -- Access ---------------------------------------------------------------
	$f.allowRead:=Bool($c.ALLOW_READ)
	$f.allowWrite:=Bool($c.ALLOW_WRITE)
	$f.allowDelete:=Bool($c.ALLOW_DELETE)
	$f.allowCall:=Bool($c.ALLOW_CALL_METHOD)
	$f.defaultLimit:=Num($c.DEFAULT_LIMIT)
	$f.maxLimit:=Num($c.MAX_LIMIT)

	// -- Tables ---------------------------------------------------------------
	$f.respectSchema:=Bool($c.RESPECT_4D_SCHEMA)
	$f.tables:=This._buildTableRows($c)
	$f.currentTable:=Null
	$f.currentTableIndex:=-1

	// -- Methods --------------------------------------------------------------
	$f.methods:=This._buildMethodRows($c)
	$f.currentAction:=Null
	$f.currentActionIndex:=-1
	$f.args:=New collection
	$f.currentArg:=Null
	$f.currentArgIndex:=-1
	$f.hasAction:=False

	// -- Tokens & rate --------------------------------------------------------
	$f.tokenStoreDD:=This._dd(This.config.tokenStores(); String($c.TOKEN_STORE))
	$f.tokenTable:=String($c.TOKEN_TABLE)
	$f.showTokenTable:=(String($c.TOKEN_STORE)="table")
	$f.rateLimit:=Num($c.RATE_LIMIT)

	// -- Logging & hooks ------------------------------------------------------
	$f.logLevelDD:=This._dd(This.config.logLevels(); String($c.LOG_LEVEL))
	$f.logRequests:=Bool($c.LOG_REQUESTS)
	$f.auditWrites:=Bool($c.AUDIT_WRITES)
	$f.onErrorCall:=String($c.ON_ERROR_CALL)
	$f.onRequestCall:=String($c.ON_REQUEST_CALL)

	// -- JSON preview & footer ------------------------------------------------
	$f.jsonPreview:=This._jsonPreview()
	$f.statusText:=This._headerStatus()
	$f.dirtyText:=""

// _pullFromForm: fold the scalar Form.* fields back into `doc`. The list-shaped
// settings (tables, method whitelist) are written into doc at the moment they
// change, so they are not repeated here. Called before validate / preview / save.
Function _pullFromForm()
	if (Form=Null)
		return
	end if
	var $d : Object
	$d:=This.doc

	This.config.setValue($d; "ENABLED"; Bool(Form.enabled))
	This.config.setValue($d; "HTTP_PORT"; This._int(Form.httpPort))
	This.config.setValue($d; "REQUIRE_HTTPS"; Bool(Form.requireHttps))
	This.config.setValue($d; "MAX_BODY_SIZE"; This._int(Form.maxBodySize))

	This.config.setValue($d; "ALLOW_READ"; Bool(Form.allowRead))
	This.config.setValue($d; "ALLOW_WRITE"; Bool(Form.allowWrite))
	This.config.setValue($d; "ALLOW_DELETE"; Bool(Form.allowDelete))
	This.config.setValue($d; "ALLOW_CALL_METHOD"; Bool(Form.allowCall))
	This.config.setValue($d; "DEFAULT_LIMIT"; This._int(Form.defaultLimit))
	This.config.setValue($d; "MAX_LIMIT"; This._int(Form.maxLimit))

	This.config.setValue($d; "RESPECT_4D_SCHEMA"; Bool(Form.respectSchema))

	This.config.setValue($d; "TOKEN_STORE"; String(Form.tokenStoreDD.currentValue))
	This.config.setValue($d; "TOKEN_TABLE"; String(Form.tokenTable))
	This.config.setValue($d; "RATE_LIMIT"; This._int(Form.rateLimit))

	This.config.setValue($d; "LOG_LEVEL"; String(Form.logLevelDD.currentValue))
	This.config.setValue($d; "LOG_REQUESTS"; Bool(Form.logRequests))
	This.config.setValue($d; "AUDIT_WRITES"; Bool(Form.auditWrites))
	This.config.setValue($d; "ON_ERROR_CALL"; String(Form.onErrorCall))
	This.config.setValue($d; "ON_REQUEST_CALL"; String(Form.onRequestCall))

	// =============================================================================
	//  Event dispatch
	// =============================================================================

Function handleEvent($event : Object)
	if ($event=Null)
		return
	end if
	var $code : Integer
	$code:=Num($event.code)
	var $name : Text
	$name:=OB Is defined($event; "objectName") ? String($event.objectName) : "form"

	Case of
		: ($name="form") && ($code=On Load)
			// Land on the Server tab. Form.currentTab was seeded to 0.

		// -- header ------------------------------------------------------------
		: ($name="ddTarget") && ($code=On Data Change)
			This._onTargetChange()
		: ($name="btnReveal") && ($code=On Clicked)
			This._revealFile()
		: ($name="btnReload") && ($code=On Clicked)
			This._reload()

		// -- Server tab --------------------------------------------------------
		: ($name="cbEnabled") && ($code=On Data Change)
			This._touch()
		: ($name="cbRequireHttps") && ($code=On Data Change)
			This._touch()
		: ($name="inputPort") && ($code=On After Edit)
			This._touch()
		: ($name="inputMaxBody") && ($code=On After Edit)
			This._touch()

		// -- Access tab --------------------------------------------------------
		: ($name="cbAllowRead") && ($code=On Data Change)
			This._touch()
		: ($name="cbAllowWrite") && ($code=On Data Change)
			This._touch()
		: ($name="cbAllowDelete") && ($code=On Data Change)
			This._touch()
		: ($name="cbAllowCall") && ($code=On Data Change)
			This._touch()
		: ($name="inputDefaultLimit") && ($code=On After Edit)
			This._touch()
		: ($name="inputMaxLimit") && ($code=On After Edit)
			This._touch()

		// -- Tables tab --------------------------------------------------------
		: ($name="cbRespect") && ($code=On Data Change)
			This.config.setValue(This.doc; "RESPECT_4D_SCHEMA"; Bool(Form.respectSchema))
			This._refreshTables()
			This._touch()
		: ($name="lbTables") && ($code=On Double Clicked)
			This._cycleTableRule()
		: ($name="btnRuleDefault") && ($code=On Clicked)
			This._setTableRule("default")
		: ($name="btnRuleWhitelist") && ($code=On Clicked)
			This._setTableRule("whitelist")
		: ($name="btnRuleBlacklist") && ($code=On Clicked)
			This._setTableRule("blacklist")
		: ($name="btnTablesClear") && ($code=On Clicked)
			This._clearTableRules()
		: ($name="btnTablesRefresh") && ($code=On Clicked)
			This._refreshTables()

		// -- Methods tab -------------------------------------------------------
		: ($name="lbActions") && ($code=On Selection Change)
			This._onActionSelected()
		: ($name="btnAddAction") && ($code=On Clicked)
			This._addAction()
		: ($name="btnRemoveAction") && ($code=On Clicked)
			This._removeAction()
		: ($name="btnDupAction") && ($code=On Clicked)
			This._duplicateAction()
		: ($name="inputActionName") && ($code=On After Edit)
			This._onActionFieldEdited()
		: ($name="inputHostMethod") && ($code=On After Edit)
			This._commitActionScalars()
		: ($name="inputReturns") && ($code=On After Edit)
			This._commitActionScalars()
		: ($name="inputPurpose") && ($code=On After Edit)
			This._commitActionScalars()
		: ($name="lbArgs") && ($code=On Data Change)
			This._commitArgs()
		: ($name="btnAddArg") && ($code=On Clicked)
			This._addArg()
		: ($name="btnRemoveArg") && ($code=On Clicked)
			This._removeArg()
		: ($name="btnArgUp") && ($code=On Clicked)
			This._moveArg(-1)
		: ($name="btnArgDown") && ($code=On Clicked)
			This._moveArg(1)

		// -- Tokens tab --------------------------------------------------------
		: ($name="ddTokenStore") && ($code=On Data Change)
			Form.showTokenTable:=(String(Form.tokenStoreDD.currentValue)="table")
			This._touch()
		: ($name="inputTokenTable") && ($code=On After Edit)
			This._touch()
		: ($name="inputRate") && ($code=On After Edit)
			This._touch()

		// -- Logging tab -------------------------------------------------------
		: ($name="ddLogLevel") && ($code=On Data Change)
			This._touch()
		: ($name="cbLogRequests") && ($code=On Data Change)
			This._touch()
		: ($name="cbAuditWrites") && ($code=On Data Change)
			This._touch()
		: ($name="btnOpenLogs") && ($code=On Clicked)
			This._openLogsFolder()
		: ($name="inputOnError") && ($code=On After Edit)
			This._touch()
		: ($name="inputOnRequest") && ($code=On After Edit)
			This._touch()

		// -- JSON tab ----------------------------------------------------------
		: ($name="btnJsonRefresh") && ($code=On Clicked)
			This._refreshJson()
		: ($name="btnValidate") && ($code=On Clicked)
			This._runValidation()
		: ($name="btnAddMissing") && ($code=On Clicked)
			This._addMissing()
		: ($name="btnResetDefaults") && ($code=On Clicked)
			This._resetToDefaults()

		// -- footer ------------------------------------------------------------
		: ($name="btnSave") && ($code=On Clicked)
			This._save(True)
		: ($name="btnApply") && ($code=On Clicked)
			This._save(False)
		: ($name="btnCancel") && ($code=On Clicked)
			This._cancel()
	End case

	// =============================================================================
	//  Header — target file, reveal, reload
	// =============================================================================

Function _onTargetChange()
	if (This.dirty)
		if (Not(This._confirmDiscard("Switching file")))
			// Restore the dropdown to the current target and bail.
			Form.targetDD:=This._targetDD()
			return
		end if
	end if
	This._loadTarget(String(Form.targetDD.currentValue))
	This._pushToForm()

Function _reload()
	if (This.dirty)
		if (Not(This._confirmDiscard("Reloading")))
			return
		end if
	end if
	This._loadTarget(This.target)
	This._pushToForm()
	Form.statusText:="Reloaded from disk."

Function _revealFile()
	var $file : 4D.File
	$file:=This.config.fileFor(This.target)
	if (Not($file.exists))
		Form.statusText:="File does not exist yet — it will be created on Save: "+$file.platformPath
		return
	end if
	Try
		SHOW ON DISK($file.platformPath)
	Catch
		Form.statusText:=$file.platformPath
	End try

	// =============================================================================
	//  Tables tab — the whitelist / blacklist matrix
	// =============================================================================
	// Each row shows how a dataclass is currently treated and lets the admin flip
	// its rule. The three settings the rows drive (RESPECT_4D_SCHEMA,
	// WHITELIST_TABLES, BLACKLIST_TABLES) interact, so the "Effective" column is
	// computed exactly the way MCP_Schema.exposedDataclasses would resolve it.

Function _buildTableRows($c : Object) : Collection
	var $rows : Collection
	$rows:=New collection
	var $names : Collection
	$names:=This.config.dataclassNames()
	var $wl : Collection
	$wl:=This._lowerSet($c.WHITELIST_TABLES)
	var $bl : Collection
	$bl:=This._lowerSet($c.BLACKLIST_TABLES)
	var $respect : Boolean
	$respect:=Bool($c.RESPECT_4D_SCHEMA)
	var $wlActive : Boolean
	$wlActive:=($wl.length>0)

	var $name : Text
	For each ($name; $names)
		var $low : Text
		$low:=Lowercase($name)
		var $rule : Text
		Case of
			: ($wl.indexOf($low)>=0)
				$rule:="whitelist"
			: ($bl.indexOf($low)>=0)
				$rule:="blacklist"
		Else
			$rule:="default"
		End case

		var $schemaExposed : Boolean
		$schemaExposed:=This._schemaExposed($name)

		var $effective : Boolean
		Case of
			: ($wlActive)
				$effective:=($rule="whitelist")
			: ($rule="blacklist")
				$effective:=False
			: ($respect)
				$effective:=$schemaExposed
		Else
			$effective:=True
		End case

		$rows.push(New object(\
			"name"; $name; \
			"rule"; $rule; \
			"schemaExposed"; $schemaExposed; \
			"exposedText"; ($schemaExposed ? "yes" : "no"); \
			"effective"; ($effective ? "Exposed" : "Hidden"); \
			"note"; This._tableNote($rule; $wlActive; $respect; $schemaExposed)))
	End for each
	return $rows

Function _tableNote($rule : Text; $wlActive : Boolean; $respect : Boolean; $schemaExposed : Boolean) : Text
	Case of
		: ($rule="whitelist")
			return "In whitelist"
		: ($rule="blacklist")
			return $wlActive ? "Blacklist ignored (whitelist active)" : "In blacklist"
		: ($wlActive)
			return "Not in whitelist"
		: ($respect)
			return $schemaExposed ? "By 4D schema" : "Hidden by 4D schema"
	Else
		return "All tables exposed"
	End case

// _cycleTableRule: double-click cycles default -> whitelist -> blacklist ->
// default, the quick path; the three buttons set a rule outright.
Function _cycleTableRule()
	var $row : Object
	$row:=Form.currentTable
	if ($row=Null)
		return
	end if
	var $next : Text
	Case of
		: (String($row.rule)="default")
			$next:="whitelist"
		: (String($row.rule)="whitelist")
			$next:="blacklist"
	Else
		$next:="default"
	End case
	This._applyRuleTo(String($row.name); $next)

Function _setTableRule($rule : Text)
	var $row : Object
	$row:=Form.currentTable
	if ($row=Null)
		Form.statusText:="Select a dataclass first."
		return
	end if
	This._applyRuleTo(String($row.name); $rule)

// _applyRuleTo: rewrite WHITELIST_TABLES / BLACKLIST_TABLES so $name carries
// exactly $rule, then re-derive the rows so the Effective column updates.
Function _applyRuleTo($name : Text; $rule : Text)
	var $wl : Collection
	$wl:=This._nameCollection(This.config.valueOf(This.doc; "WHITELIST_TABLES"; New collection))
	var $bl : Collection
	$bl:=This._nameCollection(This.config.valueOf(This.doc; "BLACKLIST_TABLES"; New collection))
	$wl:=This._removeName($wl; $name)
	$bl:=This._removeName($bl; $name)
	Case of
		: ($rule="whitelist")
			$wl.push($name)
		: ($rule="blacklist")
			$bl.push($name)
	End case
	This.config.setValue(This.doc; "WHITELIST_TABLES"; $wl)
	This.config.setValue(This.doc; "BLACKLIST_TABLES"; $bl)
	This._refreshTables()
	This._touch()

Function _clearTableRules()
	This.config.setValue(This.doc; "WHITELIST_TABLES"; New collection)
	This.config.setValue(This.doc; "BLACKLIST_TABLES"; New collection)
	This._refreshTables()
	This._touch()

Function _refreshTables()
	var $c : Object
	$c:=This.config.flatten(This.doc)
	Form.respectSchema:=Bool($c.RESPECT_4D_SCHEMA)
	Form.tables:=This._buildTableRows($c)
	Form.currentTable:=Null
	Form.currentTableIndex:=-1
	This._refreshJson()

	// =============================================================================
	//  Methods tab — the METHOD_WHITELIST editor
	// =============================================================================
	// The whitelist is an object (action name -> spec). The listbox works from an
	// ordered *rows* collection so the admin can rename freely without object-key
	// churn; _commitMethods() folds the rows back into an object at each change.

Function _buildMethodRows($c : Object) : Collection
	var $rows : Collection
	$rows:=New collection
	var $wl : Variant
	$wl:=$c.METHOD_WHITELIST
	if (Value type($wl)#Is object)
		return $rows
	end if
	var $name : Text
	For each ($name; $wl)
		var $spec : Object
		$spec:=$wl[$name]
		if (Value type($spec)#Is object)
			$spec:=New object
		end if
		$rows.push(New object(\
			"name"; $name; \
			"method"; String($spec.method); \
			"return"; String($spec.return); \
			"purpose"; String($spec.purpose); \
			"args"; This._argRows($spec.args)))
	End for each
	return $rows

Function _argRows($args : Variant) : Collection
	var $out : Collection
	$out:=New collection
	if (Value type($args)#Is collection)
		return $out
	end if
	var $a : Variant
	For each ($a; $args)
		if (Value type($a)#Is object)
			continue
		end if
		$out.push(New object(\
			"name"; String($a.name); \
			"type"; String($a.type); \
			"required"; Bool($a.required); \
			"purpose"; String($a.purpose)))
	End for each
	return $out

// _commitMethods: rebuild METHOD_WHITELIST in doc from Form.methods. A blank
// action name is skipped (the admin is mid-type); a duplicate name keeps the
// last one — validate() flags neither as fatal, and the row list is the truth
// the admin sees.
Function _commitMethods()
	var $wl : Object
	$wl:=New object
	var $row : Variant
	For each ($row; Form.methods)
		if (Value type($row)#Is object)
			continue
		end if
		var $name : Text
		$name:=String($row.name)
		if (Length($name)=0)
			continue
		end if
		var $spec : Object
		$spec:=New object(\
			"method"; String($row.method); \
			"args"; This._argSpecs($row.args); \
			"return"; String($row.return); \
			"purpose"; String($row.purpose))
		$wl[$name]:=$spec
	End for each
	This.config.setValue(This.doc; "METHOD_WHITELIST"; $wl)
	This._touch()

Function _argSpecs($args : Variant) : Collection
	var $out : Collection
	$out:=New collection
	if (Value type($args)#Is collection)
		return $out
	end if
	var $a : Variant
	For each ($a; $args)
		if (Value type($a)#Is object)
			continue
		end if
		$out.push(New object(\
			"name"; String($a.name); \
			"type"; This._normArgType(String($a.type)); \
			"required"; Bool($a.required); \
			"purpose"; String($a.purpose)))
	End for each
	return $out

Function _onActionSelected()
	var $row : Object
	$row:=Form.currentAction
	if ($row=Null)
		Form.hasAction:=False
		Form.args:=New collection
		Form.currentArg:=Null
		Form.currentArgIndex:=-1
		return
	end if
	Form.hasAction:=True
	// The detail inputs bind to Form.currentAction.* directly (the same object
	// held in Form.methods), so only the args listbox needs its own binding.
	Form.args:=$row.args
	Form.currentArg:=Null
	Form.currentArgIndex:=-1

Function _addAction()
	if (Value type(Form.methods)#Is collection)
		Form.methods:=New collection
	end if
	var $row : Object
	$row:=New object("name"; This._uniqueActionName("new_action"); "method"; ""; "return"; ""; "purpose"; ""; "args"; New collection)
	Form.methods.push($row)
	Form.currentAction:=$row
	Form.currentActionIndex:=Form.methods.length-1
	This._onActionSelected()
	This._commitMethods()

Function _removeAction()
	var $i : Integer
	$i:=Num(Form.currentActionIndex)
	if ($i<0) || ($i>=Form.methods.length)
		return
	end if
	Form.methods.remove($i)
	Form.currentAction:=Null
	Form.currentActionIndex:=-1
	This._onActionSelected()
	This._commitMethods()

Function _duplicateAction()
	var $row : Object
	$row:=Form.currentAction
	if ($row=Null)
		return
	end if
	var $copy : Object
	$copy:=OB Copy($row)
	$copy.name:=This._uniqueActionName(String($row.name)+"_copy")
	Form.methods.push($copy)
	Form.currentAction:=$copy
	Form.currentActionIndex:=Form.methods.length-1
	This._onActionSelected()
	This._commitMethods()

// _onActionFieldEdited: the action name changed. The listbox column binds to
// the same row object, so it already shows the new text; we only need to fold
// the rows back into the whitelist object.
Function _onActionFieldEdited()
	This._commitMethods()

Function _commitActionScalars()
	This._commitMethods()

Function _commitArgs()
	// An arg cell was edited in place; normalise its type and re-commit.
	var $row : Object
	$row:=Form.currentAction
	if ($row#Null) && (Value type($row.args)=Is collection)
		var $a : Variant
		For each ($a; $row.args)
			if (Value type($a)=Is object)
				$a.type:=This._normArgType(String($a.type))
				$a.required:=Bool($a.required)
			end if
		End for each
	end if
	This._commitMethods()

Function _addArg()
	var $row : Object
	$row:=Form.currentAction
	if ($row=Null)
		return
	end if
	if (Value type($row.args)#Is collection)
		$row.args:=New collection
	end if
	$row.args.push(New object("name"; "arg"+String($row.args.length+1); "type"; "text"; "required"; True; "purpose"; ""))
	Form.args:=$row.args
	Form.currentArgIndex:=$row.args.length-1
	This._commitMethods()

Function _removeArg()
	var $row : Object
	$row:=Form.currentAction
	if ($row=Null)
		return
	end if
	var $i : Integer
	$i:=Num(Form.currentArgIndex)
	if ($i<0) || ($i>=$row.args.length)
		return
	end if
	$row.args.remove($i)
	Form.args:=$row.args
	Form.currentArg:=Null
	Form.currentArgIndex:=-1
	This._commitMethods()

Function _moveArg($delta : Integer)
	var $row : Object
	$row:=Form.currentAction
	if ($row=Null)
		return
	end if
	var $i : Integer
	$i:=Num(Form.currentArgIndex)
	var $j : Integer
	$j:=$i+$delta
	if ($i<0) || ($j<0) || ($i>=$row.args.length) || ($j>=$row.args.length)
		return
	end if
	var $tmp : Object
	$tmp:=$row.args[$i]
	$row.args[$i]:=$row.args[$j]
	$row.args[$j]:=$tmp
	Form.args:=$row.args
	Form.currentArgIndex:=$j
	This._commitMethods()

	// =============================================================================
	//  JSON tab
	// =============================================================================

Function _refreshJson()
	This._pullFromForm()
	Form.jsonPreview:=This._jsonPreview()

Function _jsonPreview() : Text
	return JSON Stringify(This.doc; *)

Function _runValidation()
	This._pullFromForm()
	var $issues : Collection
	$issues:=This.config.validate(This.doc)
	Form.statusText:=This._formatIssues($issues)
	Form.jsonPreview:=This._jsonPreview()

Function _addMissing()
	This._pullFromForm()
	var $added : Collection
	$added:=This.config.mergeMissing(This.doc)
	This._pushToForm()
	if ($added.length=0)
		Form.statusText:="Nothing to add — every setting this build ships is already present."
	else
		Form.statusText:="Added "+String($added.length)+" missing setting(s): "+$added.join(", ")
		This._touch()
	end if

Function _resetToDefaults()
	if (Not(This._confirm("Reset to component defaults"; \
		"Replace every value with the component's shipping default? Your edits in this window will be lost. The file on disk is not touched until you Save.")))
		return
	end if
	var $def : Object
	$def:=This.config.defaultDoc()
	if ($def=Null)
		Form.statusText:="The component's default config could not be read."
		return
	end if
	This.doc:=$def
	This._pushToForm()
	This._touch()
	Form.statusText:="Loaded component defaults. Review, then Save to write them."

	// =============================================================================
	//  Save / apply / cancel
	// =============================================================================

// _save: pull the form into doc, validate, and (if clean) write the file.
// $close = true closes the window (Save) after writing; false keeps it open
// (Apply). Errors always block and keep the window open.
Function _save($close : Boolean)
	This._pullFromForm()
	var $issues : Collection
	$issues:=This.config.validate(This.doc)
	var $errors : Collection
	$errors:=$issues.query("severity = :1"; "error")
	if ($errors.length>0)
		Form.jsonPreview:=This._jsonPreview()
		Form.statusText:="Cannot save — fix these first:"+Char(Line feed)+This._formatIssues($errors)
		BEEP
		return
	end if

	if (This.target="component")
		if (Not(This._confirm("Write component template"; \
			"You are editing the component's *shipping default*, not the host's live config. In a compiled component this file is read-only and the save will fail. Continue?")))
			return
		end if
	end if

	var $file : 4D.File
	$file:=This.config.fileFor(This.target)
	var $err : Text
	$err:=This.config.writeDoc($file; This.doc)
	if (Length($err)>0)
		Form.statusText:="Save failed: "+$err
		BEEP
		return
	end if

	This.dirty:=False
	Form.dirtyText:=""

	var $warnings : Collection
	$warnings:=$issues.query("severity = :1"; "warning")
	var $msg : Text
	$msg:="Saved to "+$file.platformPath+"."
	if ($warnings.length>0)
		$msg:=$msg+Char(Line feed)+"Warnings:"+Char(Line feed)+This._formatIssues($warnings)
	end if
	$msg:=$msg+Char(Line feed)+"Changes are live on the next request — no restart needed (HTTP_PORT excepted)."
	Form.statusText:=$msg

	if ($close)
		ACCEPT
	end if

Function _cancel()
	if (This.dirty)
		if (Not(This._confirmDiscard("Closing")))
			return
		end if
	end if
	CANCEL

	// =============================================================================
	//  Small helpers
	// =============================================================================

Function _touch()
	This.dirty:=True
	if (Form#Null)
		Form.dirtyText:="● unsaved changes"
		This._refreshJson()
	end if

Function _dd($values : Collection; $current : Text) : Object
	var $idx : Integer
	$idx:=$values.indexOf($current)
	return New object(\
		"values"; $values; \
		"currentValue"; (Length($current)>0) ? $current : (($values.length>0) ? String($values[0]) : ""); \
		"index"; ($idx>=0) ? $idx : 0)

Function _targetDD() : Object
	// Labels the two files by role. "host" is always first (the default).
	var $dd : Object
	$dd:=This._dd(New collection("host"; "component"); This.target)
	return $dd

Function _headerStatus() : Text
	var $file : 4D.File
	$file:=This.config.fileFor(This.target)
	var $where : Text
	$where:=(This.target="component") ? "Component template (Resources)" : "Host live config"
	var $exists : Text
	$exists:=$file.exists ? "" : "  (not created yet — Save will create it)"
	return $where+":  "+$file.platformPath+$exists

Function _runtimeStatusText() : Text
	var $lines : Collection
	$lines:=New collection
	$lines.push("Application type: "+String(Application type))
	$lines.push("Running as component: "+(I_am_a_component ? "yes" : "no (standalone / dev)"))
	Try
		var $srv : 4D.WebServer
		$srv:=WEB Server
		$lines.push("Component web server running: "+(Bool($srv.isRunning) ? "yes" : "no"))
	Catch
	End try
	$lines.push("")
	$lines.push("The loader reads the host's 4D-mcp-config.pref on every request, so saved changes take effect immediately — except HTTP_PORT, which is read only at startup.")
	return $lines.join(Char(Line feed))

Function _formatIssues($issues : Collection) : Text
	if ($issues.length=0)
		return "No problems found."
	end if
	var $lines : Collection
	$lines:=New collection
	var $it : Object
	For each ($it; $issues)
		var $tag : Text
		$tag:=(String($it.severity)="error") ? "✗" : "⚠"
		var $prefix : Text
		$prefix:=(Length(String($it.key))>0) ? (String($it.key)+": ") : ""
		$lines.push($tag+" "+$prefix+String($it.message))
	End for each
	return $lines.join(Char(Line feed))

Function _schemaExposed($name : Text) : Boolean
	// The structure editor's "Expose as REST resource" flag for a dataclass.
	var $exposed : Boolean
	$exposed:=True
	Try
		$exposed:=Bool(ds[$name].getInfo().exposed)
	Catch
		$exposed:=True
	End try
	return $exposed

Function _openLogsFolder()
	Try
		var $folder : 4D.Folder
		$folder:=Folder(fk logs folder; *)
		$folder.create()
		SHOW ON DISK($folder.platformPath)
	Catch
		Form.statusText:="Could not open the host Logs folder."
	End try

Function _int($v : Variant) : Integer
	return Round(Num($v); 0)

// _normArgType: normalise case/whitespace only. A value that isn't a valid
// type is kept as-is (not forced to "text") so validate() can flag it as a
// blocking error rather than silently changing the admin's intent.
Function _normArgType($t : Text) : Text
	var $trimmed : Text
	$trimmed:=This._trim($t)
	var $types : Collection
	$types:=This.config.argTypes()
	if ($types.indexOf(Lowercase($trimmed))>=0)
		return Lowercase($trimmed)
	end if
	return $trimmed

Function _trim($t : Text) : Text
	var $s : Text
	$s:=String($t)
	While (Length($s)>0) && (Substring($s; 1; 1)=" ")
		$s:=Substring($s; 2)
	End while
	While (Length($s)>0) && (Substring($s; Length($s); 1)=" ")
		$s:=Substring($s; 1; Length($s)-1)
	End while
	return $s

Function _lowerSet($v : Variant) : Collection
	var $out : Collection
	$out:=New collection
	if (Value type($v)#Is collection)
		return $out
	end if
	var $n : Variant
	For each ($n; $v)
		if (Value type($n)=Is text)
			$out.push(Lowercase($n))
		end if
	End for each
	return $out

Function _nameCollection($v : Variant) : Collection
	var $out : Collection
	$out:=New collection
	if (Value type($v)#Is collection)
		return $out
	end if
	var $n : Variant
	For each ($n; $v)
		if (Value type($n)=Is text) && (Length($n)>0)
			$out.push(String($n))
		end if
	End for each
	return $out

Function _removeName($coll : Collection; $name : Text) : Collection
	var $out : Collection
	$out:=New collection
	var $n : Text
	For each ($n; $coll)
		if (Lowercase($n)#Lowercase($name))
			$out.push($n)
		end if
	End for each
	return $out

Function _uniqueActionName($base : Text) : Text
	var $existing : Collection
	$existing:=New collection
	if (Value type(Form.methods)=Is collection)
		var $r : Variant
		For each ($r; Form.methods)
			if (Value type($r)=Is object)
				$existing.push(Lowercase(String($r.name)))
			end if
		End for each
	end if
	if ($existing.indexOf(Lowercase($base))<0)
		return $base
	end if
	var $i : Integer
	$i:=2
	While ($existing.indexOf(Lowercase($base+String($i)))>=0)
		$i:=$i+1
	End while
	return $base+String($i)

Function _confirm($title : Text; $message : Text) : Boolean
	CONFIRM($message)
	return (OK=1)

Function _confirmDiscard($actionLabel : Text) : Boolean
	return This._confirm($actionLabel; $actionLabel+" will discard the unsaved changes in this window. Continue?")

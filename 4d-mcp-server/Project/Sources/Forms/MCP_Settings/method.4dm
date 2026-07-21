// Form method for MCP_Settings. Every event is delegated to Form.settings —
// the cs.MCP_Settings instance attached by MCP_Open_Settings before DIALOG —
// so the form itself holds no logic and the controller stays unit-testable.

If (OB Is defined(Form; "settings"))
	Form.settings.handleEvent(FORM Event)
End if

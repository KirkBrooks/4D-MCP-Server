//%attributes = {"shared":true}
// MCP_Open_Settings — open the deployment-config editor (MCP_Settings dialog).
//
// Call this from the HOST database (a menu item, a button, or the method
// runner) to manage 4D-mcp-config.pref through a UI instead of hand-editing the
// JSON. The dialog edits the HOST's live copy by default; the loader
// (MCP_Handler.getConfig) re-reads that file on every request, so a Save takes
// effect immediately — no restart, except HTTP_PORT, which is read at startup.
//
//   MCP_Open_Settings()   // modal; returns when the window is dismissed
//
// The window is only meaningful with a UI process (a headless server has none).
// Forms live in the component, so this must be called from host *interpreted*
// or client code, not a compiled standalone server.

#DECLARE

If (Application type=4D Server)
	ALERT("The MCP settings window needs a client — open it from a 4D remote or single-user session, not the server process.")
	return
End if

var $settings : cs.MCP_Settings
$settings:=cs.MCP_Settings.new()

var $formData : Object
$formData:=$settings.buildFormData()

var $win : Integer
$win:=Open form window("MCP_Settings"; Movable form dialog box; Horizontally centered; Vertically centered)
SET WINDOW TITLE("4D MCP Server — Settings"; $win)

DIALOG("MCP_Settings"; $formData)

CLOSE WINDOW($win)

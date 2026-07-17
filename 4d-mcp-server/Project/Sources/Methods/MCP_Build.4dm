//%attributes = {}
// MCP_Build — headless CI compile entry point. Run with:
//   tool4d --project Project/4d-mcp-server.4DProject --opening-mode interpreted \
//     --startup-method MCP_Build --data test/_serverdata/data.4DD
// Compiles the project from disk (BUILD APPLICATION is a no-op under tool4d,
// so packaging into the component .4dbase is done outside 4D — the compiled
// code lands in Libraries/ and Project/DerivedData/CompiledCode/).
// Progress goes to test/_serverdata/build_probe.txt. Quits when done.

var $log : 4D.File
$log:=Folder(fk database folder).file("test/_serverdata/build_probe.txt")
$log.setText("start\n")

var $compile : Object
$compile:=Compile project
$log.setText($log.getText()+"compile success="+String(Bool($compile.success))+"\n")

If (Not(Bool($compile.success)))
	$log.setText($log.getText()+JSON Stringify($compile.errors)+"\n")
End if

$log.setText($log.getText()+"done\n")
QUIT 4D

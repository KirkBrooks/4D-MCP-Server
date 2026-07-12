//%attributes = {}
// MCP_RunHeadlessTests — headless self-test entry point.
// Run with:  tool4d --project <..> --opening-mode interpreted \
//              --startup-method MCP_RunHeadlessTests --create-data --data <path>
// Writes /PACKAGE/test_report.json and prints a one-line summary to stdout.

var $report : Object

Try
	$report:=cs.MCP_Test.me.runAll()
Catch
	$report:=New object("crashed"; True; "errors"; Last errors)
End try

var $file : 4D.File
$file:=File("/PACKAGE/test_report.json")
$file.setText(JSON Stringify($report; *))

LOG EVENT(Into system standard outputs; "MCP_TEST "+String($report.passed)+"/"+String($report.total)+" passed, "+String($report.failed)+" failed"+Char(Line feed))

QUIT 4D

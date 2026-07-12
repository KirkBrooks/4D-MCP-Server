//%attributes = {}
/* Purpose: establish a worker for writing log messages
 ------------------
log_worker ()
 Created by: Kirk Brooks as Designer, Created: 07/11/26, 18:22:30
*/

#DECLARE($message : Text)

If ($message="")
	return 
End if 

If (Current process name#"log_worker")
	CALL WORKER("log_worker"; Current method name; $message)
	return 
End if 

//mark:  --- this code runs in the worker
// log errors in JSONL format

// use process vars for the logFile and handler
// they will persist for the duration of the worker
var logFile : 4D.File
var fileHandle : 4D.FileHandle

If (logFile=Null) || (logFile.size>1024*1024*30)
	var $fileName:="4d_mcp_server_log_"+String(Year of(Current date))+String(Month of(Current date); "00")+String(Day of(Current date); "00")
	logFile:=Folder(fk logs folder; *).file($fileName)
	fileHandle:=logFile.open("append")
End if 

var $line:={timestamp: Timestamp; message: $message}
fileHandle.writeLine(JSON Stringify($line))

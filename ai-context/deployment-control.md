# Deployment Control

 I have been thinking about how this will actually be deployed and used. Because 4D deployments are so varied in both purpose and
  scale it's going to be necessary to provide a way to manage access that the developer can control.

## 4D-mcp-config

I propose we use a JSON doc in the `Project/Sources/` folder named `4D-mcp-config.pref`.

We're deploying this as a 4D component. The component should have this doc as the default settings. When the component starts up it checks the Host for this document and copies its own if none is available.

The user/developer/administrator can configure it there. I've started the document to show what I'm thinking of.

There should be an exposed method that reads this document and configures the local settings. This will allow, for instance, some settings to be changed and the clients, if any, updated without having to take down the server.

4D has multiple deployment modes. You can read this inside 4D using `Application type` which returns an integer.
 `https://developer.4d.com/docs/commands/application-type`

## notes about scope and file locations for components

4D loads components on startup.

Each component has its own namespace and memory. This include `Storage`.

Code running in the component can access the folder structure of the Host using the standard 4D file handling commands and adding a `*` to the parameter string. Here are some examples of the same command called in component code:

```4d
$path:=Get 4d folder(Current resources folder) // returns the component resources folder path
$path:=Get 4d folder(Current resources folder; *) // returns the host resouces folder path

$folder:=Folder(fk resources folder)
$folder:=Folder(fk resources folder; *)
```

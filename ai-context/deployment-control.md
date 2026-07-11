# Deployment Control

 I have been thinking about how this will actually be deployed and used. Because 4D deployments are so varied in both purpose and
  scale it's going to be necessary to provide a way to manage access that the developer can control.

## 4D-mcp-config

I propose we use a JSON doc in the `Project/Sources/` folder named `4D-mcp-config.json`.

We're deploying this as a 4D component. The component should have this doc as the default settings. When the component starts up it checks the Host for this document and copies its own if none is available.

The user/developer/administrator can configure it there.

  4D has multiple deployment modes. You can read this inside 4D using `Application type` which returns an integer.
  `https://developer.4d.com/docs/commands/application-type`

   One should not support the MCP server at all (4 - 4D remote mode) which is a client on a client server deployment.

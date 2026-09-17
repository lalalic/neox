# Neox Tour Mac

Native macOS counterpart of Neox's iPhone Capture Tour Runner.

It intentionally uses the same version-1 manifest and MCP tool names:

- `tour.start`
- `tour.status`
- `tour.cancel`

The app listens on `http://127.0.0.1:9224/mcp` and advertises `_mcp._tcp` as
`neox-tour-mac`. Accepted takes are served from `/files/<name>` by the same
HTTP server.

## Build

```bash
cd mac/NeoxTourMac
xcodegen generate
xcodebuild -project NeoxTourMac.xcodeproj -scheme NeoxTourMac -configuration Debug build
```

Run the built `Neox Tour.app` from Xcode or Finder so macOS can present camera
and microphone permission prompts.

## Example

```bash
curl -s http://127.0.0.1:9224/ | jq
curl -s -X POST http://127.0.0.1:9224/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | jq
```

A Director can send the same manifest it sends to the iPhone. Camera/lens and
orientation requests that do not apply to the Mac are advisory and appear in
`quality_warnings`; they never block capture or acceptance.

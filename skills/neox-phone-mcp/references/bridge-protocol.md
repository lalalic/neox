# NeoY handoff protocol

NeoY is the native desktop implementation of the stable phone-facing handoff contract.

- Advertise Bonjour `_neoy._tcp` on TCP port `8686`.
- Accept `POST /agent` with `Content-Type: text/plain`.
- The request body is the complete handoff message, including the user instruction and phone MCP URL.
- Return HTTP 200 only after the message is queued under `~/.neoy/inbox`.
- TXT records may include `path=/agent`, `host=`, `port=8686`, and `ip=`.
- `GET /agent/peek` returns the oldest queued handoff without consuming it.
- `GET /agent/next?timeout=0..30` consumes FIFO, returning HTTP 204 when the timeout expires empty.

The standalone Python bridge is retired. Do not run a second bridge or bind port 8686 outside NeoY.

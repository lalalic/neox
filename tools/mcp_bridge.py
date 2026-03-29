#!/usr/bin/env python3
"""
MCP Bridge Server — reverse proxy for iOS MCP server.

The iOS app connects OUTWARD via WebSocket to this bridge.
curl sends MCP requests to the HTTP endpoint, which forwards
them over WebSocket to the app and returns the response.

Usage:
    python3 mcp_bridge.py [--http-port 9224] [--ws-port 9225]

curl example:
    curl http://localhost:9224/mcp -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
"""

import asyncio
import json
import argparse
from aiohttp import web

# Global state
app_ws = None
pending_request = asyncio.Queue()
pending_response = asyncio.Queue()


async def ws_handler(request):
    """Handle WebSocket connection from the iOS app."""
    global app_ws
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    app_ws = ws
    print("[bridge] App connected via WebSocket")

    try:
        while True:
            # Wait for an MCP request to forward
            mcp_request = await pending_request.get()
            await ws.send_json(mcp_request)

            # Wait for the app's response
            msg = await ws.receive()
            if msg.type == web.WSMsgType.TEXT:
                response = json.loads(msg.data)
                await pending_response.put(response)
            elif msg.type in (web.WSMsgType.CLOSE, web.WSMsgType.ERROR):
                break
    except Exception as e:
        print(f"[bridge] WebSocket error: {e}")
    finally:
        app_ws = None
        print("[bridge] App disconnected")

    return ws


async def mcp_handler(request):
    """Handle MCP HTTP requests from curl and forward to app."""
    print(f"[bridge] MCP request received")
    if app_ws is None:
        return web.json_response(
            {"error": "App not connected. Open the app and ensure reverse MCP is enabled."},
            status=503
        )

    try:
        body = await request.json()
        print(f"[bridge] Forwarding: {body.get('method', 'unknown')}")
    except Exception as e:
        print(f"[bridge] Parse error: {e}")
        return web.json_response(
            {"jsonrpc": "2.0", "error": {"code": -32700, "message": "Parse error"}, "id": None},
            status=400
        )

    # Forward to app via WebSocket
    await pending_request.put(body)
    print(f"[bridge] Request queued, waiting for response...")

    try:
        response = await asyncio.wait_for(pending_response.get(), timeout=30)
        print(f"[bridge] Response received")
        return web.json_response(response, headers={
            "Access-Control-Allow-Origin": "*",
        })
    except asyncio.TimeoutError:
        print(f"[bridge] Response timeout!")
        return web.json_response(
            {"jsonrpc": "2.0", "error": {"code": -32000, "message": "App response timeout"}, "id": body.get("id")},
            status=504
        )


async def options_handler(request):
    """CORS preflight."""
    return web.Response(status=204, headers={
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
    })


async def status_handler(request):
    """Health check."""
    return web.json_response({
        "connected": app_ws is not None,
        "status": "app connected" if app_ws else "waiting for app",
    })


def main():
    parser = argparse.ArgumentParser(description="MCP Bridge Server")
    parser.add_argument("--http-port", type=int, default=9224, help="HTTP port for curl MCP requests")
    parser.add_argument("--ws-port", type=int, default=None, help="Unused — WebSocket is on same port at /ws")
    args = parser.parse_args()

    app = web.Application()
    app.router.add_get("/ws", ws_handler)
    app.router.add_post("/mcp", mcp_handler)
    app.router.add_options("/mcp", options_handler)
    app.router.add_get("/status", status_handler)

    print(f"[bridge] MCP Bridge starting on port {args.http_port}")
    print(f"[bridge]   HTTP endpoint: http://0.0.0.0:{args.http_port}/mcp")
    print(f"[bridge]   WebSocket:     ws://0.0.0.0:{args.http_port}/ws")
    print(f"[bridge]   Status:        http://0.0.0.0:{args.http_port}/status")
    print(f"[bridge] Waiting for app to connect...")
    web.run_app(app, port=args.http_port, print=None)


if __name__ == "__main__":
    main()

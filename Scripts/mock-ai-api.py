#!/usr/bin/env python3
"""A mock Anthropic/Gemini endpoint, for verifying the cloud providers.

The Anthropic and Gemini providers cannot be exercised without paid API keys,
so their request shape would otherwise be entirely unverified — and a wrong
field name fails identically to a wrong key. Both providers honour a `baseUrl`
override, so pointing them here checks the parts that are ours: the auth header,
the schema placement, and that the response decodes.

    python3 Scripts/mock-ai-api.py &
    ./build/TermAInal.app/Contents/MacOS/TermAInal --check-cloud

The provider is identified by which auth header it sends, which is itself part
of what is being checked. Responses are shaped to catch two specific mistakes:
the Anthropic reply leads with a `thinking` block, so a provider that indexes
`content[0]` instead of searching for the text block reads the wrong thing; the
Gemini reply splits its JSON across two `parts`, so one that takes `parts[0]`
gets truncated JSON.
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8788


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")

        if self.headers.get("x-api-key"):
            flavour = "anthropic"
        elif self.headers.get("x-goog-api-key"):
            flavour = "gemini"
        else:
            flavour = None

        print(f"\n--- {flavour or 'UNRECOGNISED AUTH'}  {self.path}")
        print(json.dumps(body, indent=2)[:1200])

        payload = json.dumps({"command": "ls -lhS", "explanation": "List files by size"})
        if flavour == "anthropic":
            reply = {
                "content": [
                    {"type": "thinking", "thinking": ""},
                    {"type": "text", "text": payload},
                ],
                "stop_reason": "end_turn",
            }
        elif flavour == "gemini":
            reply = {
                "candidates": [{
                    "content": {"parts": [{"text": payload[:20]}, {"text": payload[20:]}]},
                    "finishReason": "STOP",
                }]
            }
        else:
            reply = {"error": {"message": "no recognised auth header"}}

        out = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


if __name__ == "__main__":
    print(f"mock AI API on http://127.0.0.1:{PORT} — Ctrl+C to stop")
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

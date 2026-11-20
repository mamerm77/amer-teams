"""A stand-in for the AI provider in tests: speaks the Anthropic Messages API and answers deterministically, so
the agents' real pipeline (plan, delegate in parallel, propose actions, merge, approve) runs end to end without a
key. It does not pretend to be clever: it echoes what it was given in the shapes the agents expect."""
import json, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
CALLS = []
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        system, user = body.get("system", ""), body["messages"][0]["content"]
        CALLS.append(system[:40])
        rooms = re.findall(r"room_id: (![^\s]+)", user)
        if "Reply ONLY as JSON" in system:
            text = json.dumps({"plan": "Project Manager builds the plan; Facilitator lists the action items.",
                               "assignments": [{"agent": "pm", "title": "Plan and status", "brief": "Make the plan and status report from the chat."},
                                               {"agent": "facilitator", "title": "Action items", "brief": "List decisions and action items with owners."}]})
        elif "ACTIONS:" in system and rooms:
            text = (f"Status: 2 tasks open, 1 at risk.\nACTIONS: " + json.dumps([
                {"type": "task", "room": rooms[0], "title": "Send the vendor comparison", "assignee": None, "due": "2026-11-27"},
                {"type": "post", "room": rooms[0], "text": "Plan agreed: comparison by Thursday, decision on Monday."}]))
        else:
            text = "Merged answer from the team. Ziad (Project Manager) made the plan; Faris (Facilitator) listed the actions."
        out = json.dumps({"content": [{"type": "text", "text": text}]}).encode()
        self.send_response(200); self.send_header("content-type", "application/json"); self.send_header("content-length", str(len(out))); self.end_headers(); self.wfile.write(out)
if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8099), H).serve_forever()

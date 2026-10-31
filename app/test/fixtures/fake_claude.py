#!/usr/bin/env python3
# Speaks Claude Code's stream-json host protocol (as verified against CLI 2.1.316).
import json, sys
def out(j): print(json.dumps(j), flush=True)
lines = iter(sys.stdin)
init = json.loads(next(lines)); assert init["request"]["subtype"] == "initialize"
out({"type": "control_response", "response": {"subtype": "success", "request_id": init["request_id"], "response": {}}})
for line in lines:
    j = json.loads(line)
    if j.get("type") != "user": continue
    out({"type": "system", "subtype": "init", "session_id": "sess-123", "cwd": "."})
    out({"type": "assistant", "session_id": "sess-123", "message": {"content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "mkdir x"}}]}})
    out({"type": "control_request", "request_id": "r1", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "mkdir x"}}})
    ans = json.loads(next(lines))
    allowed = ans["response"]["response"]["behavior"] == "allow"
    out({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": "ok" if allowed else "denied", "is_error": not allowed}]}})
    out({"type": "assistant", "message": {"content": [{"type": "text", "text": "made it" if allowed else "was denied"}]}})
    out({"type": "result", "subtype": "success", "duration_ms": 1200, "total_cost_usd": 0.001})

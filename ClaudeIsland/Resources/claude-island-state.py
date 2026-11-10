#!/usr/bin/env python3
"""
Claude Island Hook
- Sends session state to ClaudeIsland.app via Unix socket
- For PermissionRequest: waits for user decision from the app
"""
import json
import os
import socket
import sys
import time

SOCKET_PATH = "/tmp/claude-island.sock"
TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions
IO_TIMEOUT_SECONDS = 1  # fire-and-forget events must not block Claude Code

# Claude Code keeps adding hook events (InstructionsLoaded, MessageDisplay,
# ConfigChange, ...). None of them change the session lifecycle. Reporting them
# would create or refresh a session for a turn that may already be over, which
# is one of the ways the notch ends up showing a finished session as active.
IGNORED_EVENTS = {
    "InstructionsLoaded",
    "MessageDisplay",
    "ConfigChange",
    "PreModelSwitch",
    "PostModelSwitch",
    "CwdChanged",
    "DirectoryAdded",
    "FileChanged",
    "WorktreeCreate",
    "WorktreeRemove",
    "Setup",
    "TeammateIdle",
    "TaskCreated",
    "TaskCompleted",
    "Elicitation",
    "ElicitationResult",
    "PostToolBatch",
    "UserPromptExpansion",
}


def get_tty():
    """Get the TTY of the Claude process (parent)"""
    import subprocess

    # Get parent PID (Claude process)
    ppid = os.getppid()

    # Try to get TTY from ps command for the parent process
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=1
        )
        tty = result.stdout.strip()
        if tty and tty != "??" and tty != "-":
            # ps returns just "ttys001", we need "/dev/ttys001"
            if not tty.startswith("/dev/"):
                tty = "/dev/" + tty
            return tty
    except Exception:
        pass

    # Fallback: try current process stdin/stdout
    try:
        return os.ttyname(sys.stdin.fileno())
    except (OSError, AttributeError):
        pass
    try:
        return os.ttyname(sys.stdout.fileno())
    except (OSError, AttributeError):
        pass
    return None


def send_event(state, retries=0):
    """Send event to app, return response if any.

    `retries` is used for the final SessionEnd event. Claude Code tears the
    process down as soon as hooks return and gives SessionEnd a shared 1.5s
    budget; a single dropped frame would leave the notch showing a dead
    session as active.
    """
    for attempt in range(retries + 1):
        sock = None
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(IO_TIMEOUT_SECONDS)
            sock.connect(SOCKET_PATH)
            sock.sendall(json.dumps(state).encode())

            # For permission requests, wait for response
            if state.get("status") == "waiting_for_approval":
                sock.settimeout(TIMEOUT_SECONDS)
                response = sock.recv(4096)
                sock.close()
                if response:
                    return json.loads(response.decode())
            else:
                sock.close()

            return None
        except (socket.error, OSError, json.JSONDecodeError, ValueError):
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
            if attempt < retries:
                time.sleep(0.15)
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")
    tool_input = data.get("tool_input", {})

    if event in IGNORED_EVENTS:
        sys.exit(0)

    # Get process info. SessionEnd hooks share a 1.5s budget, so skip the ps
    # subprocess for them — the app only needs the session id at that point.
    claude_pid = os.getppid()
    tty = None if event == "SessionEnd" else get_tty()

    # Build state object
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": claude_pid,
        "tty": tty,
    }

    # Map events to status
    if event == "UserPromptSubmit":
        # User just sent a message - Claude is now processing
        state["status"] = "processing"

    elif event == "PreToolUse":
        state["status"] = "running_tool"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id to Swift for caching
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id so Swift can cancel the specific pending permission
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PostToolUseFailure":
        # Tool errored or was interrupted — main session continues processing
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        state["tool_error"] = data.get("error") or data.get("message")
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PermissionDenied":
        # Auto-mode classifier denied a tool call — surface to the app so the
        # user can see what was blocked instead of a silent skip
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        state["denial_reason"] = data.get("reason") or data.get("message")

    elif event == "PermissionRequest":
        # This is where we can control the permission
        state["status"] = "waiting_for_approval"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # tool_use_id lookup handled by Swift-side cache from PreToolUse

        # Send to app and wait for decision
        response = send_event(state)

        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")

            if decision == "allow":
                # Output JSON to approve
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow"},
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "deny":
                # Output JSON to deny
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via ClaudeIsland",
                        },
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

        # No response or "ask" - let Claude Code show its normal UI
        sys.exit(0)

    elif event == "Notification":
        notification_type = data.get("notification_type")
        # Skip permission_prompt - PermissionRequest hook handles this with better info
        if notification_type == "permission_prompt":
            sys.exit(0)
        elif notification_type == "idle_prompt":
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"
        state["notification_type"] = notification_type
        state["message"] = data.get("message")

    elif event == "Stop":
        state["status"] = "waiting_for_input"

    elif event == "StopFailure":
        # Turn ended via API error (rate limit, auth, billing). Mark waiting
        # so the user sees it's done (not stuck), with the error surfaced
        state["status"] = "waiting_for_input"
        state["stop_error"] = data.get("error") or data.get("message")

    elif event == "SubagentStart":
        # A subagent task is beginning — main session is still processing
        state["status"] = "processing"

    elif event == "SubagentStop":
        # SubagentStop fires when a subagent completes - main session continues processing
        state["status"] = "processing"

    elif event == "SessionStart":
        # New session starts waiting for user input
        state["status"] = "waiting_for_input"

    elif event == "SessionEnd":
        state["status"] = "ended"
        state["reason"] = data.get("reason")

    elif event == "PreCompact":
        # Context is being compacted (manual or auto)
        state["status"] = "compacting"

    elif event == "PostCompact":
        # Compaction finished — return to processing so UI exits .compacting phase
        state["status"] = "processing"

    else:
        # Unknown future events carry no reliable lifecycle meaning. Do NOT
        # report them as "unknown" — that resurrects finished sessions and
        # can flip a settled phase back to idle/processing.
        sys.exit(0)

    # Send to socket (fire and forget for non-permission events)
    if state.get("status") == "ended":
        send_event(state, retries=2)
    else:
        send_event(state)


if __name__ == "__main__":
    main()

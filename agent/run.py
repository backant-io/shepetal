"""Run shepetal's builder as a Claude Managed Agent whose tools execute on this Mac.

    ANTHROPIC_API_KEY=... agent/.venv/bin/python agent/run.py setup          # once: environment + agent -> agent/ids.json
    agent/.venv/bin/python agent/run.py worker                                # prompts for the environment key, keep running: executes the agent's tools here
    ANTHROPIC_API_KEY=... agent/.venv/bin/python agent/run.py start [cents]   # new budgeted session, kicked off with the outcome
"""
import asyncio
import contextlib
import getpass
import json
import os
import signal
import sys
from pathlib import Path

import anthropic
from anthropic.lib.environments import EnvironmentWorker

HERE = Path(__file__).parent
IDS = HERE / "ids.json"
WORKDIR = Path.home() / "shepetal-agent"


def ids():
    return json.loads(IDS.read_text())


def setup():
    if IDS.exists():
        sys.exit(f"{IDS} exists, delete it to recreate the agent and environment")
    client = anthropic.Anthropic()
    env = client.beta.environments.create(name="shepetal-mac", config={"type": "self_hosted"})
    agent = client.beta.agents.create(
        name="shepetal-builder",
        model={"id": "claude-opus-5-5", "effort": "high"},
        system=(HERE / "system.md").read_text(),
        tools=[{
            "type": "agent_toolset_20260401",
            "default_config": {"enabled": True, "permission_policy": {"type": "auto"}},
            # web tools run on Anthropic's servers; needed to research current on-device speech models
            "configs": [{"name": "web_search", "enabled": True}, {"name": "web_fetch", "enabled": True}],
        }],
    )
    IDS.write_text(json.dumps({"environment_id": env.id, "agent_id": agent.id}, indent=2) + "\n")
    print(f"environment {env.id}\nagent       {agent.id}\nNext: generate an environment key for {env.id} in the Console.")


async def worker():
    # The agent's bash runs as this user and can read this process's launch environment
    # (ps -E), so the key is typed in rather than passed as an env var.
    os.environ.pop("ANTHROPIC_API_KEY", None)
    key = getpass.getpass("environment key (sk-ant-oat01-...): ")
    WORKDIR.mkdir(exist_ok=True)
    async with anthropic.AsyncAnthropic(auth_token=key) as client:
        w = EnvironmentWorker(client, environment_id=ids()["environment_id"], environment_key=key,
                              workdir=WORKDIR, max_idle=None)
        task = asyncio.create_task(w.run())
        loop = asyncio.get_running_loop()
        for signum in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(signum, task.cancel)
        print(f"worker polling, tools run in {WORKDIR}. Ctrl-C to stop.")
        with contextlib.suppress(asyncio.CancelledError):
            await task


def start(cents="20000"):
    if not cents.isdigit() or cents.startswith("0"):
        sys.exit("budget is in US cents, e.g. 20000 for $200")
    client = anthropic.Anthropic()
    i = ids()
    session = client.beta.sessions.create(
        agent=i["agent_id"],
        environment_id=i["environment_id"],
        budget={"type": "limit", "max_list_cost": {"amount": cents, "currency": "USD"}},
    )
    client.beta.sessions.events.send(session_id=session.id, events=[{
        "type": "user.define_outcome",
        "description": "Build shepetal v1 and land it as a pull request on backant-io/shepetal",
        "rubric": {"type": "text", "content": (HERE / "rubric.md").read_text()},
        "max_iterations": 5,
    }])
    print(f"session {session.id} started with a ${int(cents) / 100:.2f} cap. Watch it in the Console under Managed Agents > Sessions.")


if __name__ == "__main__":
    cmd, *args = sys.argv[1:] or ["help"]
    if cmd == "setup":
        setup()
    elif cmd == "worker":
        asyncio.run(worker())
    elif cmd == "start":
        start(*args)
    else:
        sys.exit(__doc__)

"""Run shepetal's builder as a Claude Managed Agent whose tools execute on this Mac.

    agent/.venv/bin/python agent/run.py setup [cents]  # once: environment + agent + first session
    agent/.venv/bin/python agent/run.py install [n]    # run n workers permanently (login item via launchd); reinstalling restarts them
    agent/.venv/bin/python agent/run.py worker [n]     # or run them in the foreground; executes the agent's tools here
    agent/.venv/bin/python agent/run.py start [cents]  # another budgeted session, kicked off with the outcome
    agent/.venv/bin/python agent/run.py configure      # push system.md, tools and parallel workflows to the agent
    agent/.venv/bin/python agent/run.py status [sesn]  # status and spend of the last (or given) session
    agent/.venv/bin/python agent/run.py interrupt sesn # stop a session's current work (nothing is deleted)

Keys are asked for once and kept in the login Keychain (services shepetal-api-key, shepetal-environment-key).
"""
import asyncio
import contextlib
import getpass
import json
import os
import plistlib
import signal
import subprocess
import sys
from pathlib import Path

import anthropic
from anthropic.lib.environments import EnvironmentWorker

HERE = Path(__file__).parent
IDS = HERE / "ids.json"
WORKDIR = Path.home() / "shepetal-agent"
LABEL = "io.backant.shepetal-worker"
PLIST = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"
LOG = Path.home() / "Library/Logs/shepetal-worker.log"
ENV_KEY_PROMPT = "environment key for shepetal-mac (sk-ant-oat01-...): "


def secret(name, prompt, confirm=False):
    """Read a key from the login Keychain; the first time, ask for it and save it there.

    confirm=True trusts no app (-T ""), so every read shows a macOS Allow dialog: a silent read by the
    agent's bash is then impossible. The worker's key can't use it because launchd has nobody to click.
    """
    service = f"shepetal-{name}"
    found = subprocess.run(["security", "find-generic-password", "-s", service, "-w"], capture_output=True, text=True)
    if found.returncode == 0:
        return found.stdout.strip()
    value = getpass.getpass(prompt).strip()
    if not value:
        sys.exit(f"no {name} entered")
    subprocess.run(["security", "add-generic-password", "-U", "-s", service, "-a", "shepetal", *(["-T", ""] if confirm else []), "-w", value], check=True)
    print(f"saved to the login Keychain as {service} (remove with: security delete-generic-password -s {service})")
    return value


def workspace():
    # Keys not scoped to a workspace must name one on every request.
    if os.environ.get("ANTHROPIC_WORKSPACE_ID"):
        return os.environ["ANTHROPIC_WORKSPACE_ID"]
    if IDS.exists():
        return ids().get("workspace_id", "")
    return input("Workspace ID (wrkspc_..., blank if the key is workspace-scoped): ").strip()


def api(ws):
    key = os.environ.get("ANTHROPIC_API_KEY") or secret("api-key", "Anthropic API key: ", confirm=True)
    return anthropic.Anthropic(api_key=key, default_headers={"anthropic-workspace-id": ws} if ws else None)


def ids():
    return json.loads(IDS.read_text())


def agent_config():
    return dict(
        model={"id": "claude-opus-5-5", "effort": "high"},
        system=(HERE / "system.md").read_text(),
        tools=[{
            "type": "agent_toolset_20260401",
            "default_config": {"enabled": True, "permission_policy": {"type": "auto"}},
            # web tools run on Anthropic's servers; needed to research current on-device speech models
            "configs": [{"name": "web_search", "enabled": True}, {"name": "web_fetch", "enabled": True}],
        }],
        # workflow runs fan independent items out to parallel agents; the session budget caps their spend
        multiagent={"type": "multiagent_20261001", "workflows": {"type": "enabled"}},
    )


def setup(cents="20000"):
    if IDS.exists():
        sys.exit(f"{IDS} exists, delete it to recreate the agent and environment")
    check_cents(cents)
    ws = workspace()
    client = api(ws)
    # reuse the environment if an earlier setup got that far before failing
    env = next((e for e in client.beta.environments.list() if e.name == "shepetal-mac" and e.config.type == "self_hosted"), None) \
        or client.beta.environments.create(name="shepetal-mac", config={"type": "self_hosted"})
    agent = client.beta.agents.create(name="shepetal-builder", **agent_config())
    IDS.write_text(json.dumps({"environment_id": env.id, "agent_id": agent.id, "workspace_id": ws}, indent=2) + "\n")
    print(f"environment {env.id}\nagent       {agent.id}")
    # Start the first session now so the API key is only needed once; it waits until a worker polls.
    start(cents, client)
    print(f"Next: generate an environment key for {env.id} (shepetal-mac) in the Console, then run install.")


async def worker(n="1"):
    # The agent's bash runs as this user and can read this process's launch environment
    # (ps -E), so the key comes from the Keychain rather than an env var.
    os.environ.pop("ANTHROPIC_API_KEY", None)
    key = secret("environment-key", ENV_KEY_PROMPT)
    WORKDIR.mkdir(exist_ok=True)
    async with anthropic.AsyncAnthropic(auth_token=key) as client:
        # one EnvironmentWorker serves one session at a time, so n of them serve n sessions in parallel
        task = asyncio.ensure_future(asyncio.gather(*(
            EnvironmentWorker(client, environment_id=ids()["environment_id"], environment_key=key,
                              workdir=WORKDIR, max_idle=None).run() for _ in range(int(n)))))
        loop = asyncio.get_running_loop()
        for signum in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(signum, task.cancel)
        print(f"{n} worker(s) polling, tools run in {WORKDIR}. Ctrl-C to stop.", flush=True)
        with contextlib.suppress(asyncio.CancelledError):
            await task


def install(n="1"):
    secret("environment-key", ENV_KEY_PROMPT)  # launchd has no terminal to ask in
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    with PLIST.open("wb") as f:
        plistlib.dump({
            "Label": LABEL,
            # caffeinate -i keeps the Mac from idle-sleeping while the worker runs
            "ProgramArguments": ["/usr/bin/caffeinate", "-i", sys.executable, str(Path(__file__).resolve()), "worker", n],
            "RunAtLoad": True,
            "KeepAlive": True,
            "StandardOutPath": str(LOG),
            "StandardErrorPath": str(LOG),
        }, f)
    domain = f"gui/{os.getuid()}"
    subprocess.run(["launchctl", "bootout", f"{domain}/{LABEL}"], capture_output=True)  # reload if already installed
    subprocess.run(["launchctl", "bootstrap", domain, str(PLIST)], check=True)
    print(f"{n} worker(s) installed and running, start at every login. Log: {LOG}\n"
          f"Stop for good: launchctl bootout {domain}/{LABEL} && rm {PLIST}")


def check_cents(cents):
    if not cents.isdigit() or cents.startswith("0"):
        sys.exit("budget is in US cents, e.g. 20000 for $200")


def start(cents="20000", client=None):
    check_cents(cents)
    client = client or api(workspace())
    i = ids()
    session = client.beta.sessions.create(
        agent=i["agent_id"],
        environment_id=i["environment_id"],
        budget={"type": "limit", "max_list_cost": {"amount": cents, "currency": "USD"}},
    )
    client.beta.sessions.events.send(session_id=session.id, events=[{
        "type": "user.define_outcome",
        "description": "Work toward the goal in agent/goal.md on origin/main, iteration by iteration: "
                       "100% of Wispr Flow's features on Mac, iPhone and Linux with local models, "
                       "each one verified and merged to main.",
        "rubric": {"type": "text", "content": (HERE / "rubric.md").read_text()},
        "max_iterations": 20,
    }])
    IDS.write_text(json.dumps({**i, "session_id": session.id}, indent=2) + "\n")
    print(f"session {session.id} started with a ${int(cents) / 100:.2f} cap. Watch it in the Console under Managed Agents > Sessions.")


def configure():
    agent = api(workspace()).beta.agents.update(ids()["agent_id"], **agent_config())
    print(f"agent {agent.id} is now version {agent.version}; new sessions use it")


def status(session_id=None):
    s = api(workspace()).beta.sessions.retrieve(session_id or ids()["session_id"])
    dollars = lambda m: f"${int(m.amount) / 100:.2f}"  # amounts are in cents
    spent = dollars(s.usage.list_cost) if s.usage.list_cost else "n/a"
    print(f"{s.id} {s.status}, spent {spent}" + (f" of {dollars(s.budget.max_list_cost)}" if s.budget else ""))


def interrupt(session_id):
    api(workspace()).beta.sessions.events.send(session_id=session_id, events=[{"type": "user.interrupt"}])
    print(f"interrupt sent to {session_id}; it goes idle and keeps its history")


if __name__ == "__main__":
    cmd, *args = sys.argv[1:] or ["help"]
    if cmd == "setup":
        setup(*args)
    elif cmd == "install":
        install(*args)
    elif cmd == "worker":
        asyncio.run(worker(*args))
    elif cmd == "start":
        start(*args)
    elif cmd == "configure":
        configure()
    elif cmd == "status":
        status(*args)
    elif cmd == "interrupt" and args:
        interrupt(args[0])
    else:
        sys.exit(__doc__)

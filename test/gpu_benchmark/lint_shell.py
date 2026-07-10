#!/usr/bin/env python3
"""Lint the gpu-benchmark role's shell commands for two failure classes proven
on the lab:

1. Unbalanced quotes/jinja in the raw command text — Ansible's argument
   splitter runs on the PRE-templating string and aborts the task
   ("failed at splitting arguments"). A comment with an apostrophe inside an
   inline script is enough to trigger it.

2. Internal newlines in ssh one-liners — a YAML folded scalar (>) KEEPS the
   newlines of continuation lines indented deeper than the first line; the
   remote bash then executes each line separately (redirects/& silently lost,
   task hangs on the held ssh pipes). ssh one-liners must fold to one line.
   Heredoc scripts (<<'REMOTE_EOF') are exempt: they are intentionally
   multi-line via a literal block.

3. pkill/pgrep -f patterns that match their own command line — the remote
   shell (bash -c "<the whole compound>") has the full compound as its own
   cmdline, so `pkill -f 'vllm serve'` matches and KILLS the very shell running
   it (ssh dies with rc 255; observed on the lab). The pattern must be written
   so its regex cannot match the command text itself — the classic bracket
   trick `[v]llm serve` — and the plain string must not appear elsewhere in
   the same compound (e.g. no pkill in the same command as `exec vllm serve`).

Run: python3 test/gpu_benchmark/lint_shell.py   (needs ansible in the env)
"""
import glob
import re
import sys

import yaml
from ansible.parsing.splitter import split_args

PKILL_RE = re.compile(r"""p(?:kill|grep)\s+(?:-\S+\s+)*-f\s+(?:'([^']*)'|"([^"]*)")""")

fails = 0
for path in sorted(glob.glob('roles/gpu-benchmark/tasks/**/*.yml', recursive=True)):
    docs = yaml.safe_load(open(path)) or []

    def walk(tasks):
        global fails
        for task in tasks:
            if not isinstance(task, dict):
                continue
            for key in ('ansible.builtin.shell', 'shell'):
                if key not in task:
                    continue
                cmd = task[key] if isinstance(task[key], str) else task[key].get('cmd', '')
                name = str(task.get('name', '?'))[:60]
                try:
                    split_args(cmd)
                except Exception as exc:  # noqa: BLE001
                    fails += 1
                    print(f"SPLIT-FAIL   {path} :: {name} -> {exc}")
                if ('REMOTE_EOF' not in cmd
                        and cmd.lstrip().startswith('ssh ')
                        and '\n' in cmd.rstrip('\n')):
                    fails += 1
                    n = cmd.rstrip('\n').count('\n')
                    print(f"NEWLINE-FAIL {path} :: {name} ({n} internal newlines)")
                for pm in PKILL_RE.finditer(cmd):
                    pat = pm.group(1) if pm.group(1) is not None else pm.group(2)
                    try:
                        selfmatch = re.search(pat, cmd)
                    except re.error:
                        continue
                    if selfmatch:
                        fails += 1
                        print(f"SELFKILL-FAIL {path} :: {name} -> pkill/pgrep -f pattern "
                              f"{pat!r} matches its own command line (remote shell suicide); "
                              f"bracket it ([v]...) and keep the plain string out of the compound")
            for block in ('block', 'rescue', 'always'):
                if block in task:
                    walk(task[block])

    walk(docs)

print('lint_shell:', 'OK' if fails == 0 else f'{fails} FAIL(s)')
sys.exit(1 if fails else 0)

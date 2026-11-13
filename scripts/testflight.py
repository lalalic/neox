#!/usr/bin/env python3
"""App wrapper for Neo's one shared apple-delivery Skill and release engine."""
import json
import os
import subprocess
import sys
from pathlib import Path


def main():
    project = Path(__file__).resolve().parent.parent
    proc = subprocess.run(['neo', 'skill', 'list', '--project', str(project)],capture_output=True,text=True)
    if proc.returncode:
        raise SystemExit('Cannot discover Neo skills: '+proc.stderr.strip())
    try:
        skills = json.loads(proc.stdout)
        skill = next(s for s in skills if s['name'] == 'apple-delivery')
        engine = Path(skill['path']).parent/'apple_delivery.py'
    except (ValueError, KeyError, StopIteration, TypeError) as exc:
        raise SystemExit('Shared apple-delivery Skill is not installed: '+str(exc))
    if not engine.is_file():
        raise SystemExit('Shared apple-delivery engine unavailable: '+str(engine))
    os.execv(sys.executable,[sys.executable,str(engine),'--project',str(project)]+sys.argv[1:])


if __name__=='__main__':
    main()

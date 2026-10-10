#!/usr/bin/env python3
"""Create/update GitHub repository and environment variables/secrets from JSON.

Usage:
  python github-env-setup.py [github-env-config.json] [--dry-run]
Requires: Python 3.8+; GitHub CLI (gh) for real changes. No jq required.
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys
from urllib.parse import quote


def run_gh(*args, data=None):
    result = subprocess.run(
        ['gh', *args], input=data, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=False,
    )
    if result.returncode:
        # Do not echo potentially sensitive stdin or CLI stderr on secret writes.
        if data is not None:
            raise RuntimeError(f"gh {args[0]} {args[1]} failed (exit {result.returncode}); check access and inputs")
        detail = result.stderr.decode('utf-8', errors='replace').strip()
        raise RuntimeError(f"gh {' '.join(args)} failed (exit {result.returncode}): {detail}")


def mapping(value, label):
    if not isinstance(value, dict):
        raise ValueError(f'{label} must be a JSON object')
    return value


def collect_entries(scope, label, config_dir):
    collected = []
    for plural, singular in [('variables', 'variable'), ('secrets', 'secret')]:
        items = mapping(scope.get(plural, {}), f'{label}.{plural}')
        for key, value in items.items():
            if not isinstance(key, str) or not key:
                raise ValueError(f'Invalid name in {label}.{plural}')
            if isinstance(value, str):
                content = value.encode('utf-8')  # Includes actual newlines from JSON \\n.
                from_file = False
            elif isinstance(value, dict) and set(value) == {'file'} and isinstance(value['file'], str) and value['file']:
                path = pathlib.Path(value['file'])
                if not path.is_absolute():
                    path = config_dir / path
                try:
                    content = path.read_bytes()  # Preserve blank lines and final newline.
                except OSError as e:
                    raise ValueError(f'Cannot read file for {label}.{plural}.{key}: {path}: {e}') from e
                from_file = True
            else:
                raise ValueError(f'{label}.{plural}.{key} must be a string or {{"file": "path"}}')
            collected.append((singular, key, content, from_file))
    return collected


def apply_entries(repo, env, entries, dry_run):
    for kind, key, content, from_file in entries:
        target = f'{repo}/{env}' if env else repo
        print(f'  [{target}] {kind}: {key}' + (' (file)' if from_file else ''), flush=True)
        if not dry_run:
            command = [kind, 'set', key, '--repo', repo]
            if env:
                command += ['--env', env]
            # gh reads value from stdin when --body is not provided.
            run_gh(*command, data=content)


def main():
    parser = argparse.ArgumentParser(description='Sync GitHub repo/environment variables and secrets from JSON')
    parser.add_argument('config', nargs='?', default=str(pathlib.Path(__file__).with_name('github-env-config.json')))
    parser.add_argument('--dry-run', action='store_true', help='Validate and print operations; do not call gh')
    args = parser.parse_args()
    config_path = pathlib.Path(args.config).resolve()
    with config_path.open('r', encoding='utf-8') as f:
        cfg = mapping(json.load(f), 'config')
    org = cfg.get('org')
    repos = cfg.get('repositories')
    if not isinstance(org, str) or not org.strip() or '/' in org:
        raise ValueError('org must be a nonempty GitHub owner/organization name')
    if not isinstance(repos, list):
        raise ValueError('repositories must be an array')

    # Validate config and referenced files before making any remote changes.
    plan = []
    for i, item in enumerate(repos):
        item = mapping(item, f'repositories[{i}]')
        name = item.get('repo')
        if not isinstance(name, str) or not name.strip() or '/' in name:
            raise ValueError(f'repositories[{i}].repo must be a repository name')
        repo = f'{org}/{name}'
        root_entries = collect_entries(item, repo, config_path.parent)
        envs = mapping(item.get('environments', {}), f'{repo}.environments')
        env_plan = []
        for env, settings in envs.items():
            if not isinstance(env, str) or not env.strip():
                raise ValueError(f'Invalid environment name in {repo}')
            env_plan.append((env, collect_entries(mapping(settings, f'{repo}/{env}'), f'{repo}/{env}', config_path.parent)))
        plan.append((repo, name, root_entries, env_plan))

    if not args.dry_run:
        if not shutil.which('gh'):
            raise RuntimeError('Missing dependency: GitHub CLI (gh)')
        run_gh('auth', 'status')

    for repo, name, root_entries, env_plan in plan:
        print(f'Repository: {repo}', flush=True)
        if not args.dry_run:
            run_gh('repo', 'view', repo, '--json', 'name')
        apply_entries(repo, None, root_entries, args.dry_run)
        for env, env_entries in env_plan:
            print(f'  Environment: {env}', flush=True)
            if not args.dry_run:
                run_gh('api', '--method', 'PUT', f'repos/{org}/{name}/environments/{quote(env, safe="")}')
            apply_entries(repo, env, env_entries, args.dry_run)

    print('Dry-run completed (no changes).' if args.dry_run else 'GitHub configuration applied.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError, json.JSONDecodeError) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)

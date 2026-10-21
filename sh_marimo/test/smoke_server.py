#!/usr/bin/env python3
"""Exercise rendered OOD hooks against the marimo installed in this Python."""
import html
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlencode, urljoin, urlsplit

from websockets.sync.client import connect
from websockets.exceptions import InvalidStatus
import marimo

ROOT = Path(__file__).resolve().parents[1]
RUBY_RENDER = """
require 'erb'; require 'ostruct'; require 'json'
data = OpenStruct.new(JSON.parse(STDIN.read)); data.context = data
path = ARGV.fetch(0); erb = ERB.new(File.read(path), trim_mode: '-')
erb.filename = path; print erb.result(data.instance_eval { binding })
"""


def render(name, values):
    return subprocess.check_output(
        ['ruby', '-e', RUBY_RENDER, str(ROOT / name)],
        input=json.dumps(values).encode(),
    ).decode()


def main():
    with tempfile.TemporaryDirectory(prefix='marimo-real-') as temp:
        # macOS /var aliases /private/var; use the server's canonical cwd path.
        staging = Path(temp).resolve()
        workspace = staging / 'notebooks with spaces'
        workspace.mkdir()
        home = staging / 'home'
        home.mkdir()
        notebook = workspace / 'smoke.py'
        notebook.write_text('import marimo\napp = marimo.App()\n@app.cell\ndef _():\n    answer = 42\n    return (answer,)\n')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        password = secrets.token_hex(24)
        base = f'/node/localhost/{port}'
        values = dict(marimo_python=sys.executable, sh_workspace=str(workspace), sh_modules='',
                      host='localhost', port=str(port), password=password)
        for name in ('before.sh.erb', 'script.sh.erb', 'after.sh.erb'):
            target = staging / name.removesuffix('.erb')
            target.write_text(render('template/' + name, values))
            target.chmod(0o700)
        wrapper = staging / 'wrapper.sh'
        wrapper.write_text(f'''#!/usr/bin/env bash
host=localhost
find_port() {{ printf '%s' {port}; }}
create_passwd() {{ printf '%s' "$TEST_PASSWORD"; }}
source ./before.sh
exec ./script.sh
''')
        log_path = staging / 'server.log'
        env = dict(os.environ, HOME=str(home), TEST_PASSWORD=password)
        env.pop('MARIMO_SESSION_SECRET', None)
        env.pop('MARIMO_ENABLE_HOST', None)
        with log_path.open('wb') as log:
            process = subprocess.Popen(['bash', str(wrapper)], cwd=staging, env=env,
                                       stdout=log, stderr=log, start_new_session=True)
        try:
            def request(method, path, body=None, headers=None):
                conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                conn.request(method, path, body, headers or {})
                response = conn.getresponse()
                result = response.status, dict(response.getheaders()), response.read()
                conn.close()
                return result

            for _ in range(100):
                if process.poll() is not None:
                    raise AssertionError(log_path.read_text())
                try:
                    status, headers, body = request('GET', base + '/')
                    break
                except (ConnectionError, OSError):
                    time.sleep(0.1)
            else:
                raise AssertionError('Server did not start')
            assert status in (302, 303, 307), (status, body)
            assert '/auth/login' in headers['location'], headers
            assert request('GET', base + '/api/files/roots')[0] in (401, 403)
            print('PASS unauthenticated editor and file API are protected')

            view = render('view.html.erb', values)
            action = html.unescape(re.search(r'action="([^"]+)"', view)[1])
            assert action == base + '/auth/login'
            status, headers, body = request('POST', action, urlencode({'password': 'wrong'}),
                                             {'Content-Type': 'application/x-www-form-urlencoded'})
            assert 'set-cookie' not in headers
            assert b'Invalid password' in body
            status, headers, body = request('POST', action, urlencode({'password': password}),
                                             {'Content-Type': 'application/x-www-form-urlencoded'})
            assert status == 302, (status, body)
            assert headers['location'] == base + '/', headers
            cookie = headers['set-cookie'].split(';', 1)[0]
            assert 'httponly' in headers['set-cookie'].lower()
            assert 'secure' in headers['set-cookie'].lower()
            assert f'path={base}' in headers['set-cookie'].lower()
            auth_headers = {'Cookie': cookie}
            status, headers, body = request('GET', base + '/', headers=auth_headers)
            assert status == 200, body
            page = body.decode()
            asset = re.search(r'<script[^>]+src="([^"]+)"', page)[1]
            asset_path = urlsplit(urljoin('http://localhost' + base + '/', asset)).path
            assert asset_path.startswith(base + '/'), asset_path
            assert request('GET', asset_path, headers=auth_headers)[0] == 200
            status, _, body = request('GET', base + '/api/files/roots', headers=auth_headers)
            assert status == 200, body
            assert str(workspace) in body.decode(), body
            print('PASS connection POST, secure cookie, home page, prefixed assets, and workspace')

            status, _, body = request('GET', base + '/?' + urlencode({'file': str(notebook)}), headers=auth_headers)
            assert status == 200, (status, body)
            ws_url = f'ws://127.0.0.1:{port}{base}/ws?' + urlencode({'session_id': 'smoke-session', 'file': str(notebook)})
            try:
                with connect(ws_url, open_timeout=5):
                    raise AssertionError('Unauthenticated WebSocket accepted')
            except InvalidStatus as exc:
                assert exc.response.status_code == 403, exc
            with connect(ws_url, additional_headers=auth_headers,
                         origin='https://login.sherlock.stanford.edu', open_timeout=5) as ws:
                message = ws.recv(timeout=20)
                assert 'kernel-ready' in message, message[:500]
            print('PASS authenticated notebook WebSocket and rejected anonymous WebSocket')

            # Same-origin requests work without enabling wildcard CORS.
            _, headers, _ = request('GET', base + '/', headers=dict(auth_headers, Origin='https://untrusted.example'))
            assert headers.get('access-control-allow-origin') != '*'
            assert password not in log_path.read_text()
            assert password not in render('template/script.sh.erb', values)
            print('PASS no wildcard CORS and no password in server logs or launch arguments')
            print(f'marimo {marimo.__version__}: all rendered-server smoke checks passed')
        except Exception:
            print(log_path.read_text().replace(password, '[redacted]'), file=sys.stderr)
            raise
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()


if __name__ == '__main__':
    main()

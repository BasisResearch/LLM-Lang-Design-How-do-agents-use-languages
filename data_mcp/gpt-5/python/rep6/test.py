import json
import os
import socket
import subprocess
import sys
import time
from urllib import request, parse, error
import http.cookiejar as cookiejar


def ensure_flask():
    try:
        import flask  # noqa: F401
    except Exception:
        subprocess.run([sys.executable, '-m', 'pip', 'install', '--quiet', 'flask'], check=True)


def wait_for_server(base_url, timeout=5.0):
    start = time.time()
    while time.time() - start < timeout:
        try:
            req = request.Request(base_url + '/unknown')
            with request.urlopen(req, timeout=0.5):
                return True
        except error.HTTPError as e:
            # If we got a valid HTTP response like 404, server is up
            if e.code in (404, 405):
                return True
            time.sleep(0.1)
        except Exception:
            time.sleep(0.1)
    return False


def http_json(opener, method, url, data=None, expect_status=200, headers=None):
    headers = headers or {}
    if data is not None:
        body = json.dumps(data).encode('utf-8')
        headers['Content-Type'] = 'application/json'
    else:
        body = None
    req = request.Request(url, data=body, method=method)
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        resp = opener.open(req)
        status = resp.getcode()
        ct = resp.headers.get('Content-Type', '')
        if expect_status == 204:
            assert status == 204, f"Expected {expect_status}, got {status}"
            # For 204 we expect empty body
            content = resp.read()
            assert content == b'' or content is None, 'Expected empty body for 204'
            return None, resp.headers
        else:
            assert status == expect_status, f"Expected {expect_status}, got {status}"
            assert 'application/json' in ct, f"Expected application/json, got {ct}"
            text = resp.read().decode('utf-8')
            return json.loads(text), resp.headers
    except error.HTTPError as e:
        status = e.code
        ct = e.headers.get('Content-Type', '') if e.headers else ''
        text = e.read().decode('utf-8') if e.fp else ''
        if expect_status and status == expect_status:
            if expect_status == 204:
                return None, e.headers
            assert 'application/json' in ct, f"Expected application/json, got {ct}"
            return json.loads(text), e.headers
        else:
            raise AssertionError(f"HTTP {method} {url} failed: {status} {text}")


def find_free_port():
    with socket.socket() as s:
        s.bind(('', 0))
        return s.getsockname()[1]


def main():
    ensure_flask()

    port = find_free_port()
    base = f'http://127.0.0.1:{port}'

    # Start server
    env = os.environ.copy()
    server = subprocess.Popen([sys.executable, 'server.py', '--port', str(port)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)

    try:
        assert wait_for_server(base), 'Server did not start in time'

        cj = cookiejar.CookieJar()
        opener = request.build_opener(request.HTTPCookieProcessor(cj))

        # 1) Register
        data, headers = http_json(opener, 'POST', base + '/register', {"username": "user_one", "password": "password123"}, 201)
        assert data['username'] == 'user_one' and isinstance(data['id'], int)

        # 2) Duplicate register -> 409
        data, headers = http_json(opener, 'POST', base + '/register', {"username": "user_one", "password": "password123"}, 409)
        assert data['error'] == 'Username already exists'

        # 3) Login
        data, headers = http_json(opener, 'POST', base + '/login', {"username": "user_one", "password": "password123"}, 200)
        assert data['username'] == 'user_one'
        # Cookie should be stored
        assert any(c.name == 'session_id' for c in cj), 'session_id cookie not set'

        # 4) /me should work
        data, headers = http_json(opener, 'GET', base + '/me', None, 200)
        assert data['username'] == 'user_one'

        # 5) Create todos
        t1, _ = http_json(opener, 'POST', base + '/todos', {"title": "Task 1", "description": "Desc 1"}, 201)
        t2, _ = http_json(opener, 'POST', base + '/todos', {"title": "Task 2"}, 201)
        id1 = t1['id']
        id2 = t2['id']

        # 6) List todos returns 2 and ordered
        lst, _ = http_json(opener, 'GET', base + '/todos', None, 200)
        assert len(lst) == 2
        assert [x['id'] for x in lst] == sorted([id1, id2])

        # 7) Get todo by id
        gt, _ = http_json(opener, 'GET', f'{base}/todos/{id1}', None, 200)
        assert gt['title'] == 'Task 1'

        # 8) Update todo partially
        ut, _ = http_json(opener, 'PUT', f'{base}/todos/{id1}', {"completed": True, "description": "New D"}, 200)
        assert ut['completed'] is True and ut['description'] == 'New D'

        # 9) Delete other todo
        _, _ = http_json(opener, 'DELETE', f'{base}/todos/{id2}', None, 204)

        # 10) Change password invalid old
        err, _ = http_json(opener, 'PUT', base + '/password', {"old_password": "wrongpass", "new_password": "newpassword1"}, 401)
        assert err['error'] == 'Invalid credentials'

        # 11) Change password valid
        ok, _ = http_json(opener, 'PUT', base + '/password', {"old_password": "password123", "new_password": "newpassword1"}, 200)
        assert ok == {}

        # 12) Logout
        out, _ = http_json(opener, 'POST', base + '/logout', None, 200)
        assert out == {}

        # 13) Access after logout should be 401
        err, _ = http_json(opener, 'GET', base + '/me', None, 401)
        assert err['error'] == 'Authentication required'

        # 14) Other user register and access 404 for other's todo
        opener2 = request.build_opener(request.HTTPCookieProcessor(cookiejar.CookieJar()))
        http_json(opener2, 'POST', base + '/register', {"username": "user_two", "password": "password123"}, 201)
        http_json(opener2, 'POST', base + '/login', {"username": "user_two", "password": "password123"}, 200)
        # user_two tries to GET user_one's todo id1 -> 404
        err, _ = http_json(opener2, 'GET', f'{base}/todos/{id1}', None, 404)
        assert err['error'] == 'Todo not found'

        print('All tests passed.')
    finally:
        server.terminate()
        try:
            server.wait(timeout=3)
        except Exception:
            server.kill()


if __name__ == '__main__':
    main()

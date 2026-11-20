#!/usr/bin/env python3
"""把多个本地文件一次性提交成一个 commit（Git Data API）

    GH_TOK=xxx python3 tools/pushmany.py "提交说明" 本地路径:仓库路径 ...

为什么要这样：Contents API 一次只能提交一个文件，而这个仓库每 push 一次
就会触发一次 21 分钟的 5.10 内核构建。分两次 push = 白烧一次 CI。
用 Git Data API 拼一个 tree，一次提交只触发一次构建。
"""
import base64
import json
import os
import sys
import urllib.error
import urllib.request

TOK = os.environ['GH_TOK']
API = 'https://api.github.com'
REPO = 'hzh21/s5p6818_linux-xiaoY_king6818'
BRANCH = 'ci/5.10-king6818'


def call(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header('Authorization', 'Bearer ' + TOK)
    req.add_header('Accept', 'application/vnd.github+json')
    req.add_header('User-Agent', 'wb-push')
    if data:
        req.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            body = r.read().decode()
            return r.status, (json.loads(body) if body.strip() else {})
    except urllib.error.HTTPError as e:
        body = e.read().decode() or '{}'
        try:
            return e.code, json.loads(body)
        except Exception:
            return e.code, {'raw': body[:400]}


def main():
    # 参数从 JSON 文件读：Windows 的 Git Bash 会把 "a:b" 这类参数改写成
    # "a\\b;..."（MSYS 路径转换），命令行传路径不可靠。
    #   spec.json: {"message": "...", "files": [["本地", "仓库路径"], ...]}
    spec = json.load(open(sys.argv[1], encoding='utf-8'))
    message = spec['message']
    pairs = [(loc, dst) for loc, dst in spec['files']]

    st, d = call('GET', f'/repos/{REPO}/git/ref/heads/{BRANCH}')
    if st != 200:
        print('get ref failed', st, d)
        return 1
    head_sha = d['object']['sha']
    st, d = call('GET', f'/repos/{REPO}/git/commits/{head_sha}')
    if st != 200:
        print('get commit failed', st, d)
        return 1
    base_tree = d['tree']['sha']
    print('head', head_sha[:8], 'tree', base_tree[:8])

    entries = []
    for local, repo_path in pairs:
        raw = open(local, 'rb').read()
        st, d = call('POST', f'/repos/{REPO}/git/blobs',
                     {'content': base64.b64encode(raw).decode(),
                      'encoding': 'base64'})
        if st not in (200, 201):
            print('blob failed', local, st, d)
            return 1
        entries.append({'path': repo_path, 'mode': '100644',
                        'type': 'blob', 'sha': d['sha']})
        print('blob', repo_path, len(raw), 'bytes ->', d['sha'][:8])

    st, d = call('POST', f'/repos/{REPO}/git/trees',
                 {'base_tree': base_tree, 'tree': entries})
    if st not in (200, 201):
        print('tree failed', st, d)
        return 1
    tree_sha = d['sha']

    st, d = call('POST', f'/repos/{REPO}/git/commits',
                 {'message': message, 'tree': tree_sha,
                  'parents': [head_sha]})
    if st not in (200, 201):
        print('commit failed', st, d)
        return 1
    new_sha = d['sha']

    st, d = call('PATCH', f'/repos/{REPO}/git/refs/heads/{BRANCH}',
                 {'sha': new_sha, 'force': False})
    if st not in (200, 201):
        print('update ref failed', st, d)
        return 1
    print('pushed', new_sha)
    return 0


if __name__ == '__main__':
    sys.exit(main())

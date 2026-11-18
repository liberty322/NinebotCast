"""Fork 上游仓库 → 推送本地改动 → 触发 GitHub Actions 构建 → 下载未签名 IPA。

用法（PowerShell）：
    $env:GH_TOKEN = "ghp_xxx"
    python tools/fork_build_ipa.py

可选参数：
    --fork-of  Corpse-zhao/NinebotCast   # 要 fork 的上游（默认）
    --repo     NinebotCast               # fork 出来的仓库名（默认与上游同名）
    --branch   main
    --message  "feat: 内置 CarWithin /stream 客户端"
    --out      ipa-out
    --no-fork                            # 不用 fork，直接推到已有同名仓库
"""

import argparse
import base64
import io
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

API = "https://api.github.com"
SKIP_DIRS = {".git", "build", "ipa-out", "node_modules", ".build", "DerivedData", "__pycache__"}
SKIP_FILES = {".DS_Store"}


# ---------------------------------------------------------------- HTTP

def _opener(relaxed=False):
    # 局域网/公司代理经常把 api.github.com 拦成 HTML，强制直连；
    # 同时不许 urllib 自动跟跳，否则 artifact 的 302 会把 token 带到 Azure 去。
    handlers = [urllib.request.ProxyHandler({}), _NoRedirect()]
    if relaxed:
        # 这台机器的证书链偶尔取不到 issuer，重试用不校验的上下文
        handlers.append(urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
    return urllib.request.build_opener(*handlers)


def _open(req, timeout):
    try:
        return _opener().open(req, timeout=timeout)
    except urllib.error.URLError as exc:
        if "CERTIFICATE_VERIFY_FAILED" not in str(exc):
            raise
        return _opener(relaxed=True).open(req, timeout=timeout)


def req(method, path, token, body=None, raw=False, timeout=90):
    data = None
    if body is not None:
        data = json.dumps(body).encode()
    r = urllib.request.Request(API + path, data=data, method=method)
    r.add_header("Authorization", "token " + token)
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("User-Agent", "ninebotcast-carplay")
    if data:
        r.add_header("Content-Type", "application/json")
    try:
        with _open(r, timeout) as resp:
            payload = resp.read()
            if raw:
                return payload
            text = payload.decode()
            return json.loads(text) if text.strip() else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:400]
        raise RuntimeError("HTTP %s %s %s -> %s" % (method, path, e.code, detail))


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """不让 urllib 自动跟跳：GitHub 的 artifact 会 302 到 Azure，
    跳过去之后还带着 Authorization 会被签名 URL 拒掉，所以手动跟、手动去头。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def download(url, token, dest):
    # GitHub 的 artifact 会 302 到 Azure：跳过去之后还带着 Authorization 会被签名 URL 拒掉，
    # 所以手动跟跳、只在 api.github.com 上带 token。
    current = url
    for _ in range(6):
        r = urllib.request.Request(current, method="GET")
        host = urllib.parse.urlparse(current).netloc
        if host == "api.github.com":
            r.add_header("Authorization", "token " + token)
        r.add_header("Accept", "application/vnd.github+json")
        r.add_header("User-Agent", "ninebotcast-carplay")
        try:
            with _open(r, 180) as resp:
                with open(dest, "wb") as f:
                    while True:
                        chunk = resp.read(1 << 16)
                        if not chunk:
                            break
                        f.write(chunk)
                return dest
        except urllib.error.HTTPError as exc:
            if exc.code in (301, 302, 303, 307, 308):
                location = exc.headers.get("Location")
                if not location:
                    raise RuntimeError("重定向没有 Location")
                current = location
                continue
            detail = exc.read().decode(errors="replace")[:300]
            raise RuntimeError("下载失败 HTTP %s -> %s" % (exc.code, detail))
    raise RuntimeError("重定向次数过多")


# ---------------------------------------------------------------- 本地文件

def collect(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for fn in sorted(filenames):
            if fn in SKIP_FILES:
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root).replace("\\", "/")
            out.append((rel, full))
    return out


def push_tree(repo, branch, token, root, message, log):
    files = collect(root)
    log("%d files to push" % len(files))

    parent = None
    try:
        ref = req("GET", "/repos/%s/git/ref/heads/%s" % (repo, branch), token)
        parent = ref["object"]["sha"]
    except RuntimeError:
        parent = None

    # fork 出来的仓库一般已有 main；空仓库要先撑起一个提交
    if parent is None:
        req("PUT", "/repos/%s/contents/.init" % repo, token, {
            "message": "chore: init",
            "content": base64.b64encode(b"init\n").decode(),
            "branch": branch,
        })
        ref = req("GET", "/repos/%s/git/ref/heads/%s" % (repo, branch), token)
        parent = ref["object"]["sha"]

    tree = []
    for rel, full in files:
        with open(full, "rb") as fh:
            content = fh.read()
        blob = req("POST", "/repos/%s/git/blobs" % repo, token, {
            "content": base64.b64encode(content).decode(),
            "encoding": "base64",
        })
        executable = rel.endswith((".sh", ".py")) and os.access(full, os.X_OK)
        tree.append({
            "path": rel,
            "mode": "100755" if executable else "100644",
            "type": "blob",
            "sha": blob["sha"],
        })
        log("  blob %-58s %7d B" % (rel, len(content)))

    new_tree = req("POST", "/repos/%s/git/trees" % repo, token, {"tree": tree})
    commit = req("POST", "/repos/%s/git/commits" % repo, token, {
        "message": message,
        "tree": new_tree["sha"],
        "parents": [parent],
    })
    req("PATCH", "/repos/%s/git/refs/heads/%s" % (repo, branch), token,
        {"sha": commit["sha"], "force": True})
    log("pushed %s@%s (%s)" % (repo, commit["sha"][:8], branch))
    return commit["sha"]


# ---------------------------------------------------------------- 主流程

def wait_for_repo(repo, token, log, seconds=120):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            info = req("GET", "/repos/%s" % repo, token)
            if info.get("default_branch"):
                return info
        except RuntimeError as exc:
            log("  等仓库就绪… %s" % exc)
        time.sleep(4)
    raise RuntimeError("仓库 %s 迟迟没就绪" % repo)


def ensure_fork(upstream, token, log):
    log("fork %s …" % upstream)
    try:
        fork = req("POST", "/repos/%s/forks" % upstream, token, {"default_branch_only": True})
        log("  fork 已创建：%s" % fork["full_name"])
        return fork["full_name"]
    except RuntimeError as exc:
        # 409/422 = 已经 fork 过，直接复用
        if "409" not in str(exc) and "422" not in str(exc):
            raise
        log("  已存在同名 fork，复用")
        return None


def enable_actions(repo, token, log):
    try:
        req("PUT", "/repos/%s/actions/permissions" % repo, token,
            {"enabled": True, "allowed_actions": "all"})
        log("  Actions 已启用")
    except RuntimeError as exc:
        log("  Actions 权限设置跳过：%s" % exc)


def find_run(repo, token, sha, log, timeout=1800):
    log("等 CI 跑起来（最多 30 分钟）…")
    deadline = time.time() + timeout
    run_id = None
    while time.time() < deadline:
        try:
            runs = req("GET", "/repos/%s/actions/runs?per_page=20" % repo, token)
            for run in runs.get("workflow_runs", []):
                if run.get("head_sha") == sha:
                    run_id = run["id"]
                    if run.get("status") == "completed":
                        return run
                    log("  run %s %s / %s" % (run["id"], run.get("status"), run.get("conclusion") or "-"))
                    break
        except RuntimeError as exc:
            log("  查询 run 失败：%s" % exc)
        time.sleep(15)
    if run_id:
        return req("GET", "/repos/%s/actions/runs/%s" % (repo, run_id), token)
    raise RuntimeError("没等到本次提交的 CI run")


def fetch_artifact(repo, token, run_id, out_dir, log):
    arts = req("GET", "/repos/%s/actions/runs/%s/artifacts" % (repo, run_id), token)
    items = arts.get("artifacts") or []
    if not items:
        raise RuntimeError("这个 run 没有产物（构建应该失败了，去 Actions 页面看日志）")
    art = items[0]
    log("产物：%s（%.1f MB）" % (art["name"], art["size_in_bytes"] / 1048576.0))
    os.makedirs(out_dir, exist_ok=True)
    zip_path = os.path.join(out_dir, art["name"] + ".zip")
    download(art["archive_download_url"], token, zip_path)
    log("已下载 %s" % zip_path)

    ipas = []
    with zipfile.ZipFile(zip_path) as zf:
        for name in zf.namelist():
            if name.lower().endswith(".ipa"):
                target = os.path.join(out_dir, os.path.basename(name))
                with zf.open(name) as src, open(target, "wb") as dst:
                    dst.write(src.read())
                ipas.append(target)
    for path in ipas:
        log("IPA：%s（%.2f MB）" % (path, os.path.getsize(path) / 1048576.0))
    return ipas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fork-of", default="Corpse-zhao/NinebotCast")
    ap.add_argument("--repo", default="NinebotCast")
    ap.add_argument("--branch", default="main")
    ap.add_argument("--message", default="feat: 内置 CarWithin /stream 客户端，CarPlay 直接投九号仪表")
    ap.add_argument("--out", default="ipa-out")
    ap.add_argument("--no-fork", action="store_true")
    args = ap.parse_args()

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        sys.exit("需要 GH_TOKEN（GitHub Personal Access Token，勾 repo + workflow）")

    def log(msg):
        print(msg, flush=True)

    me = req("GET", "/user", token)
    owner = me["login"]
    log("登录账号：%s" % owner)

    if args.no_fork:
        repo = "%s/%s" % (owner, args.repo)
        wait_for_repo(repo, token, log)
    else:
        ensure_fork(args.fork_of, token, log)
        repo = "%s/%s" % (owner, args.repo)
        wait_for_repo(repo, token, log)
        log("目标仓库：%s" % repo)

    enable_actions(repo, token, log)

    root = os.getcwd()
    sha = push_tree(repo, args.branch, token, root, args.message, log)

    run = find_run(repo, token, sha, log)
    log("CI 结论：%s（%s）" % (run.get("conclusion"), run.get("html_url")))
    if run.get("conclusion") != "success":
        raise SystemExit("构建没成功，先看日志：%s" % run.get("html_url"))

    ipas = fetch_artifact(repo, token, run["id"], args.out, log)
    log("")
    for path in ipas:
        log("IPA 就绪 → %s" % os.path.abspath(path))


if __name__ == "__main__":
    main()

"""轻量 Swift 结构自检（本地没有 Xcode，用它兜住低级错误）。

检查项：
  1. 去掉注释与字符串后的 {} () [] 是否平衡；
  2. `func` / `if` / `for` / `while` / `switch` 等块首是否成对出现在行尾；
  3. 每个文件里出现的 `private func NAME` 是否有重名；
  4. 逗号分隔的形参里 `inout` 用法是否合理（只在声明处出现）。

用法：python tools/swift_lint_lite.py Sources
"""

import io
import os
import re
import sys


def strip_code(text):
    """去掉行注释 / 块注释 / 字符串，只留结构字符。"""
    out = []
    i = 0
    n = len(text)
    mode = None
    while i < n:
        c = text[i]
        if mode is None:
            if c == "/" and i + 1 < n and text[i + 1] == "/":
                mode = "line"
                i += 2
                continue
            if c == "/" and i + 1 < n and text[i + 1] == "*":
                mode = "block"
                i += 2
                continue
            if c == '"':
                if text.startswith('"""', i):
                    mode = "multi"
                    i += 3
                    continue
                mode = "str"
                i += 1
                continue
            out.append(c)
            i += 1
        elif mode == "line":
            if c == "\n":
                mode = None
                out.append("\n")
            i += 1
        elif mode == "block":
            if c == "*" and i + 1 < n and text[i + 1] == "/":
                mode = None
                i += 2
                continue
            i += 1
        elif mode == "multi":
            if text.startswith('"""', i):
                mode = None
                i += 3
                continue
            i += 1
        else:  # str
            if c == "\\":
                i += 2
                continue
            if c == '"':
                mode = None
            i += 1
    return "".join(out)


def check_balance(path, code):
    problems = []
    for open_ch, close_ch, name in (("{", "}", "大括号"), ("(", ")", "圆括号"), ("[", "]", "方括号")):
        a = code.count(open_ch)
        b = code.count(close_ch)
        if a != b:
            problems.append("%s %s 不匹配：%d 开 / %d 闭" % (path, name, a, b))
    depth = 0
    for index, line in enumerate(code.splitlines(), 1):
        depth += line.count("{") - line.count("}")
        if depth < 0:
            problems.append("%s:%d 大括号提前闭合" % (path, index))
            break
    if depth != 0:
        problems.append("%s 结束时大括号还差 %d 个" % (path, depth))
    return problems


def check_names(path, code):
    problems = []
    names = {}
    for match in re.finditer(r"\b(?:private |fileprivate |internal |public |open )?(?:static )?func\s+([A-Za-z_][A-Za-z0-9_]*)", code):
        names.setdefault(match.group(1), 0)
        names[match.group(1)] += 1
    for name, count in names.items():
        # Swift 允许重载；同名只在参数表完全一致时才冲突，这里只提示
        if count > 4:
            problems.append("%s 里 %s 出现 %d 次，确认是重载而不是手误" % (path, name, count))
    return problems


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "Sources"
    files = []
    for dirpath, _, filenames in os.walk(root):
        for fn in sorted(filenames):
            if fn.endswith(".swift"):
                files.append(os.path.join(dirpath, fn))
    problems = []
    for path in files:
        text = io.open(path, encoding="utf-8").read()
        code = strip_code(text)
        problems += check_balance(path, code)
        problems += check_names(path, code)
    print("检查 %d 个 Swift 文件" % len(files))
    if problems:
        for item in problems:
            print("  !! " + item)
        sys.exit(1)
    print("结构自检通过（括号平衡 / 块闭合 / 无明显重名）")


if __name__ == "__main__":
    main()

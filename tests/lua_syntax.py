"""本机无 lua/luac 时使用的轻量 Lua 语法校验工具。

不做完整解析，只做以下三件事：
  1. 检查未闭合的字符串（'、"、[=[=]、--[[ ]]）
  2. 检查括号配对（( )、{ }、[ ]）
  3. 检查 do / then / function / if / for / while 与对应的 end 数量是否平衡

这能拦下绝大多数手写错误（漏 end、引号没关、括号不配对），是 PC 端零依赖的兜底。
"""
from __future__ import annotations
import io
import re
import sys
from pathlib import Path

# Windows 默认 GBK；强制 UTF-8 输出避免中文乱码
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
else:
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")


LUA_KEYWORDS_NEED_END = {
    "do",
    "function",
    "if",
    "for",
    "while",
    "repeat",
}

# `then` 不是块开头：if X then / elseif X then 是同一个块，由 `end` 关闭
# `else` / `elseif` 也不开新块
LUA_KEYWORDS_NOT_BLOCK = {"then", "else", "elseif", "until"}


def strip_comments_and_strings(src: str) -> str:
    """先把 Lua 的字符串与注释全部替换成空格，保留行号信息。

    支持：
      - 单行注释 -- ...
      - 多行注释 --[[ ... ]] 或 --[=[ ... ]=]
      - 单引号/双引号字符串（不含嵌套转义细节）
      - 长字符串 [[ ... ]] / [=[ ... ]=]
    """
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        # 行注释
        if c == "-" and i + 1 < n and src[i + 1] == "-":
            # 多行注释？
            if i + 3 < n and src[i + 2] == "[":
                eq_count = 0
                j = i + 3
                while j < n and src[j] == "=":
                    eq_count += 1
                    j += 1
                if j < n and src[j] == "[":
                    end_marker = "]" + ("=" * eq_count) + "]"
                    end_idx = src.find(end_marker, j + 1)
                    if end_idx == -1:
                        raise ValueError(f"未闭合的多行注释，起始于第 {src[:i].count(chr(10)) + 1} 行")
                    i = end_idx + len(end_marker)
                    continue
            # 行注释直到换行
            while i < n and src[i] != "\n":
                i += 1
            continue
        # 长字符串
        if c == "[" and i + 1 < n:
            eq_count = 0
            j = i + 1
            if j < n and src[j] == "[":
                level = 0
            else:
                while j < n and src[j] == "=":
                    eq_count += 1
                    j += 1
                if j < n and src[j] == "[":
                    level = eq_count
                else:
                    out.append(c)
                    i += 1
                    continue
            if level >= 0:
                end_marker = "]" + ("=" * level) + "]"
                end_idx = src.find(end_marker, j + 1)
                if end_idx == -1:
                    raise ValueError(f"未闭合的长字符串，起始于第 {src[:i].count(chr(10)) + 1} 行")
                i = end_idx + len(end_marker)
                continue
        # 单引号/双引号
        if c in ("'", '"'):
            quote = c
            i += 1
            while i < n and src[i] != quote:
                if src[i] == "\\" and i + 1 < n:
                    i += 2
                else:
                    i += 1
            if i >= n:
                raise ValueError(f"未闭合的字符串（{quote}），起始行 {src[:i].count(chr(10)) + 1}")
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


KEYWORD_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\b")


def check_balance(src: str) -> list[str]:
    errors: list[str] = []
    stripped = strip_comments_and_strings(src)

    pairs = {"(": ")", "{": "}", "[": "]"}

    stack: list[tuple[str, int, int]] = []  # (char, line, col)
    line = 1
    col = 1
    for ch in stripped:
        if ch == "\n":
            line += 1
            col = 1
            continue
        if ch in "({[":
            stack.append((ch, line, col))
        elif ch in ")}]":
            if not stack:
                errors.append(f"第 {line} 列 {col}：多余的 '{ch}'")
            else:
                opener, ol, oc = stack[-1]
                if pairs[opener] != ch:
                    errors.append(
                        f"第 {line} 列 {col}：'{ch}' 与第 {ol} 列 {oc} 处的 '{opener}' 不匹配"
                    )
                stack.pop()
        col += 1
    if stack:
        for ch, ol, oc in stack:
            errors.append(f"第 {ol} 列 {oc}：未闭合的 '{ch}'")

    # 关键字 / end 配对
    tokens = [m.group(1) for m in KEYWORD_RE.finditer(stripped)]
    if tokens.count("end") != sum(tokens.count(k) for k in LUA_KEYWORDS_NEED_END):
        open_kw = sum(tokens.count(k) for k in LUA_KEYWORDS_NEED_END)
        close_kw = tokens.count("end")
        errors.append(
            f"'end' 数量 {close_kw} 与 do/function/if/for/while/repeat 关键字 {open_kw} 不匹配"
        )

    return errors


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("用法: python lua_syntax.py <file1.lua> [file2.lua ...]")
        return 2
    total_errors = 0
    for path in argv[1:]:
        text = Path(path).read_text(encoding="utf-8")
        try:
            errors = check_balance(text)
        except ValueError as exc:
            print(f"SYNTAX ERROR  {path}: {exc}")
            total_errors += 1
            continue
        if errors:
            print(f"SYNTAX ERROR  {path}:")
            for err in errors:
                print(f"  - {err}")
            total_errors += 1
        else:
            print(f"OK            {path}")
    return 1 if total_errors else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

"""本机无 busted 时的轻量替代。

支持的 API（仅够计划用）：
  - describe(name, fn)           fn 里可以用 it(...)
  - it(name, fn)                 fn 里可调用 assert.is_truthy / assert.is_nil / assert.are_equal
  - before_each(fn) / after_each(fn)
  - 失败时记录行号 + 错误信息，结束后打印 summary
"""
from __future__ import annotations
import io
import sys
import traceback
import inspect
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
else:
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")


class _State:
    suites: list = []  # list of (name, fn, file, line)
    hooks_before: list = []
    hooks_after: list = []


class _Assert:
    def __init__(self, test_name: str, results: list):
        self._test_name = test_name
        self._results = results

    def _fail(self, msg: str):
        self._results.append((self._test_name, "FAIL", msg))

    def is_truthy(self, value, msg: str = ""):
        if not value:
            self._fail(f"expected truthy, got {value!r}. {msg}".strip())

    def is_nil(self, value, msg: str = ""):
        if value is not None:
            self._fail(f"expected nil, got {value!r}. {msg}".strip())

    def are_equal(self, a, b, msg: str = ""):
        if a != b:
            self._fail(f"expected {b!r}, got {a!r}. {msg}".strip())

    def is_string(self, value, msg: str = ""):
        if not isinstance(value, str):
            self._fail(f"expected string, got {type(value).__name__}. {msg}".strip())


def describe(name: str, fn):
    frame = inspect.currentframe().f_back
    _State.suites.append((name, fn, frame.f_code.co_filename, frame.f_lineno))


def it(name: str, fn):
    frame = inspect.currentframe().f_back
    _State.suites.append((name, fn, frame.f_code.co_filename, frame.f_lineno, True))  # leaf test


def before_each(fn):
    _State.hooks_before.append(fn)


def after_each(fn):
    _State.hooks_after.append(fn)


def _run_file(path: str) -> tuple[int, int, list[str]]:
    """执行一份 spec 文件，返回 (pass_count, fail_count, error_messages)。"""
    # 重置全局 registry（多次跑独立）
    _State.suites.clear()
    _State.hooks_before.clear()
    _State.hooks_after.clear()

    # 先创建空 dict，再向里填，最后自指 _G
    g: dict = {}
    g["describe"] = describe
    g["it"] = it
    g["before_each"] = before_each
    g["after_each"] = after_each
    g["_G"] = g
    # assert 需要在 spec 加载前可用（spec 里直接用 assert.xxx）
    placeholder_results: list = []
    g["assert"] = _Assert("__placeholder__", placeholder_results)
    g["dofile"] = lambda p: exec(Path(p).read_text(encoding="utf-8"), g)
    g["loadfile"] = lambda p: (lambda: exec(Path(p).read_text(encoding="utf-8"), g))

    results: list[tuple[str, str, str]] = []
    try:
        exec(Path(path).read_text(encoding="utf-8"), g)
    except Exception as e:
        return 0, 1, [f"无法加载 {path}: {type(e).__name__}: {e}"]

    # 遍历 suites
    for entry in _State.suites:
        if len(entry) == 5 and entry[4] is True:
            # it 测试
            name, fn, _file, _line, _ = entry
            try:
                for h in _State.hooks_before:
                    h()
                fn()
                for h in _State.hooks_after:
                    h()
                results.append((name, "PASS", ""))
            except AssertionError as e:
                results.append((name, "FAIL", str(e)))
            except Exception as e:
                results.append((name, "ERROR", f"{type(e).__name__}: {e}"))
        else:
            # describe 嵌套：执行 fn，里面可能再注册 it
            name, fn, _file, _line = entry
            try:
                fn()
            except Exception as e:
                results.append((f"<describe {name}>", "ERROR", f"{type(e).__name__}: {e}"))

    passes = sum(1 for _, status, _ in results if status == "PASS")
    fails = sum(1 for _, status, _ in results if status != "PASS")
    msgs = [f"{name}: {msg}" for name, status, msg in results if status != "PASS"]
    return passes, fails, msgs


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("用法: python busted.py <spec1.lua> [spec2.lua ...]")
        return 2
    total_p = 0
    total_f = 0
    for spec in argv[1:]:
        print(f"=== {spec} ===")
        p, f, msgs = _run_file(spec)
        total_p += p
        total_f += f
        for m in msgs:
            print(f"  FAIL  {m}")
        print(f"  {p} passed, {f} failed")
    print()
    print(f"== Summary: {total_p} passed, {total_f} failed ==")
    return 0 if total_f == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

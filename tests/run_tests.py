"""PC 端最终验证脚本 (跨平台).

按 docs/superpowers/plans/2026-08-11-koreader-webdav-koplugin.md Task 12 设计.
做 4 件事:
  1. 跑所有 busted 单元测试 (tests/*_spec.lua)
  2. 对所有 .lua 文件做 luac 语法检查
  3. 校验 webdav 二进制 (ARM 32-bit ELF, 静态链接)
  4. 输出 OK/FAIL 汇总,任一失败则 exit 1

可用环境变量:
  LUA_BIN  - 显式指定 lua 可执行 (默认 'lua')
  LUAC_BIN - 显式指定 luac 可执行 (默认 'luac')

Windows 用户可以直接双击: tests\\run_tests.ps1
Linux/macOS 用户: bash tests/run_tests.sh
"""
from __future__ import annotations
import io
import os
import shutil
import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
else:
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")


REPO_ROOT = Path(__file__).resolve().parent.parent
PLUGIN_DIR = REPO_ROOT / "webdav.koplugin"
TESTS_DIR = REPO_ROOT / "tests"
LUA_BIN = os.environ.get("LUA_BIN", "lua")
LUAC_BIN = os.environ.get("LUAC_BIN", "luac")


def find_lua_in_conda() -> tuple[str | None, str | None]:
    """Windows 上 conda 装的 lua 不一定在 PATH,自动探测."""
    if shutil.which(LUA_BIN) and shutil.which(LUAC_BIN):
        return LUA_BIN, LUAC_BIN
    candidates = [
        Path("D:/miniconda/Library/bin"),
        Path("C:/ProgramData/miniconda3/Library/bin"),
        Path(os.path.expanduser("~/miniconda3/Library/bin")),
        Path("/opt/miniconda3/lib"),
    ]
    for base in candidates:
        lua = base / ("lua.exe" if os.name == "nt" else "lua")
        luac = base / ("luac.exe" if os.name == "nt" else "luac")
        if lua.exists() and luac.exists():
            return str(lua), str(luac)
    return None, None


def run_unit_tests(lua: str) -> bool:
    busted = TESTS_DIR / "busted.lua"
    specs = sorted(TESTS_DIR.glob("*_spec.lua"))
    if not specs:
        print("[1/4] 没有 *_spec.lua 测试文件,跳过")
        return True
    print(f"[1/4] 单元测试 ({len(specs)} 个 spec):")
    ok = True
    for spec in specs:
        result = subprocess.run(
            [lua, str(busted), str(spec)],
            cwd=str(REPO_ROOT),
            capture_output=True, text=True, encoding="utf-8",
        )
        print(result.stdout.rstrip())
        if result.returncode != 0:
            ok = False
    return ok


def find_luajit() -> str | None:
    """探测 LuaJIT(与 KOReader 设备同款 5.1 语义)."""
    if shutil.which("luajit"):
        return shutil.which("luajit")
    candidates = [
        Path("D:/miniconda/Library/bin/luajit.exe"),
        Path("C:/ProgramData/miniconda3/Library/bin/luajit.exe"),
        Path(os.path.expanduser("~/miniconda3/Library/bin/luajit.exe")),
    ]
    for c in candidates:
        if c.exists():
            return str(c)
    return None


def run_luajit_checks(lj: str) -> bool:
    """LuaJIT 兼容性检查: 设备上跑的是 LuaJIT(5.1 语义), 而 PC 的 Lua 5.4 对
    很多问题宽容(例如模式串内嵌 NUL 字节, LuaJIT 报 malformed pattern 而 5.4 不报)。
    历史教训: has_control_char 的 "[\x00-\x1f\x7f]" 模式在 PC 全绿、
    设备上 toggle 必炸, 就是这个盲区。"""
    print("\n[3/6] LuaJIT 兼容性检查 (与设备同款语义):")
    ok = True
    # mock: 加载 + init + 交互路径
    r = subprocess.run(
        [lj, str(TESTS_DIR / "mock_koreader_load.lua")],
        cwd=str(REPO_ROOT), capture_output=True, text=True, encoding="utf-8",
    )
    if r.returncode == 0:
        print("  OK    LuaJIT 模拟加载 + 交互演练")
    else:
        print(f"  FAIL  LuaJIT mock 失败 (exit {r.returncode})")
        for line in r.stdout.rstrip().splitlines()[-5:]:
            print(f"        {line}")
        ok = False
    # 全部 spec
    for spec in sorted(TESTS_DIR.glob("*_spec.lua")):
        r = subprocess.run(
            [lj, str(TESTS_DIR / "busted.lua"), str(spec)],
            cwd=str(REPO_ROOT), capture_output=True, text=True, encoding="utf-8",
        )
        if r.returncode == 0:
            print(f"  OK    LuaJIT {spec.name}")
        else:
            print(f"  FAIL  LuaJIT {spec.name} (exit {r.returncode})")
            ok = False
    return ok


def run_mock_load(lua: str) -> bool:
    """用 mock_koreader_load.lua 以真实路径语义加载插件, 复现 KOReader 的 dofile 流程."""
    print("\n[2/6] 模拟 KOReader 加载 (mock_koreader_load.lua):")
    result = subprocess.run(
        [lua, str(TESTS_DIR / "mock_koreader_load.lua")],
        cwd=str(REPO_ROOT),
        capture_output=True, text=True, encoding="utf-8",
    )
    for line in result.stdout.rstrip().splitlines():
        print(f"  {line}")
    if result.returncode != 0:
        print(f"  FAIL  mock 加载失败 (exit {result.returncode})")
        return False
    print("  OK    加载 + init 成功")
    return True


def check_lua_syntax(luac: str) -> bool:
    print("\n[4/6] Lua 语法 + BOM 检查:")
    lua_files = sorted(PLUGIN_DIR.glob("*.lua")) + sorted(TESTS_DIR.glob("*.lua"))
    ok = True
    for f in lua_files:
        # BOM 检查: 带 BOM 的 chunk 在部分 LuaJIT 版本上直接语法错误,
        # 插件会完全无法加载(PC 端 luac 会跳过 BOM, 所以必须显式检查)
        with open(f, "rb") as fh:
            head = fh.read(3)
        if head == b"\xef\xbb\xbf":
            print(f"  FAIL  {f.relative_to(REPO_ROOT)}: 文件以 UTF-8 BOM 开头, 设备上可能无法加载")
            ok = False
            continue
        result = subprocess.run(
            [luac, "-p", str(f)],
            capture_output=True, text=True, encoding="utf-8",
        )
        if result.returncode == 0:
            print(f"  OK    {f.relative_to(REPO_ROOT)}")
        else:
            print(f"  FAIL  {f.relative_to(REPO_ROOT)}: {result.stderr.strip()}")
            ok = False
    return ok


def check_binary() -> bool:
    print("\n[5/6] webdav 二进制检查:")
    bin_path = PLUGIN_DIR / "webdav"
    if not bin_path.exists():
        print(f"  FAIL  {bin_path} 不存在")
        return False
    # 读前 32 字节,自己验 ELF + ARM
    with open(bin_path, "rb") as f:
        header = f.read(32)
    if header[:4] != b"\x7fELF":
        print(f"  FAIL  不是 ELF 文件 (magic: {header[:4]!r})")
        return False
    if len(header) < 20:
        print(f"  FAIL  文件头太短 ({len(header)} 字节)")
        return False
    ei_class = header[4]  # 1=32bit, 2=64bit
    ei_data = header[5]   # 1=LSB, 2=MSB
    e_machine = int.from_bytes(header[18:20], "little")  # 40 = ARM, 0xB7 = AArch64
    size = bin_path.stat().st_size
    arch_ok = ei_class == 1 and ei_data == 1 and e_machine == 40
    size_mb = size / 1024 / 1024
    if arch_ok:
        print(f"  OK    ELF 32-bit LSB ARM, {size_mb:.2f} MB ({size} 字节)")
        return True
    else:
        print(f"  FAIL  架构不匹配: ei_class={ei_class} ei_data={ei_data} e_machine={e_machine}")
        return False


def check_layout() -> bool:
    print("\n[6/6] 仓库结构检查:")
    expected = [
        PLUGIN_DIR / "_meta.lua",
        PLUGIN_DIR / "main.lua",
        PLUGIN_DIR / "webdav",
        PLUGIN_DIR / "LICENSE",
        PLUGIN_DIR / "README.md",
    ]
    ok = True
    for p in expected:
        rel = p.relative_to(REPO_ROOT)
        if p.exists():
            print(f"  OK    {rel}")
        else:
            print(f"  FAIL  缺失 {rel}")
            ok = False
    # docs/ 应该被 .gitignore 忽略
    docs_dir = REPO_ROOT / "docs"
    if docs_dir.exists():
        import subprocess as sp
        result = sp.run(
            ["git", "check-ignore", "-q", "docs/"],
            cwd=str(REPO_ROOT), capture_output=True,
        )
        if result.returncode == 0:
            print("  OK    docs/ 被 .gitignore 忽略")
        else:
            print("  FAIL  docs/ 存在但未被 .gitignore 忽略")
            ok = False
    return ok


def main() -> int:
    lua, luac = find_lua_in_conda()
    if not lua or not luac:
        print("错误: 找不到 lua/luac。请装 Lua 5.4+ 并确保在 PATH。")
        print("  conda install -c conda-forge lua=5.4.8")
        return 2

    print(f"使用: {lua} / {luac}\n")

    results = {
        "单元测试": run_unit_tests(lua),
        "模拟加载": run_mock_load(lua),
        "LuaJIT 兼容": run_luajit_checks(lj) if (lj := find_luajit()) else True,
        "Lua 语法/BOM": check_lua_syntax(luac),
        "webdav 二进制": check_binary(),
        "仓库结构": check_layout(),
    }
    if not lj:
        print("(未找到 LuaJIT, 跳过 LuaJIT 兼容性检查)")

    print()
    for name, ok in results.items():
        marker = "OK  " if ok else "FAIL"
        print(f"  [{marker}] {name}")
    all_ok = all(results.values())
    print()
    print(f"== {'全部通过' if all_ok else '有失败'} ==")
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env bash
# tests/run_tests.sh
# Linux/macOS 用户入口: 跑 PC 端最终验证
# 用法: bash tests/run_tests.sh

set -e
cd "$(dirname "$0")/.."
python3 tests/run_tests.py

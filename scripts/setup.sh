#!/bin/bash
# KAJIBA セットアップ — ワンコマンドで使える状態にする
set -e

HAYABUSA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
HAYABUSA_HOME="$HOME/.hayabusa"

echo "╔══════════════════════════════════════════╗"
echo "║  KAJIBA Setup                            ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# 1. ビルド
echo "[1/5] Building Hayabusa..."
cd "$HAYABUSA_DIR"

if [ ! -f vendor/llama.cpp/build/src/libllama.a ]; then
    echo "  Building llama.cpp..."
    cd vendor/llama.cpp
    cmake -B build -DGGML_METAL=ON -DBUILD_SHARED_LIBS=OFF 2>/dev/null
    cmake --build build --config Release -j$(sysctl -n hw.ncpu) 2>/dev/null
    cd "$HAYABUSA_DIR"
fi

swift build -c release --product Hayabusa 2>&1 | tail -1
swift build -c release --product HayabusaCLI 2>&1 | tail -1
echo "  Done."

# 2. シンボリックリンク作成
echo "[2/5] Installing commands..."
mkdir -p "$BIN_DIR"

# hayabusa コマンド（サーバー）
ln -sf "$HAYABUSA_DIR/.build/release/Hayabusa" "$BIN_DIR/hayabusa-server" 2>/dev/null || \
ln -sf "$HAYABUSA_DIR/.build/arm64-apple-macosx/release/Hayabusa" "$BIN_DIR/hayabusa-server"

# hayabusa CLI
ln -sf "$HAYABUSA_DIR/.build/release/HayabusaCLI" "$BIN_DIR/hayabusa" 2>/dev/null || \
ln -sf "$HAYABUSA_DIR/.build/arm64-apple-macosx/release/HayabusaCLI" "$BIN_DIR/hayabusa"

echo "  hayabusa     → $BIN_DIR/hayabusa"
echo "  hayabusa-server → $BIN_DIR/hayabusa-server"

# 3. PATHに追加
echo "[3/5] Updating PATH..."
SHELL_RC="$HOME/.zshrc"
[ -f "$HOME/.bashrc" ] && SHELL_RC="$HOME/.bashrc"

if ! grep -q ".local/bin" "$SHELL_RC" 2>/dev/null; then
    echo '' >> "$SHELL_RC"
    echo '# KAJIBA' >> "$SHELL_RC"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
    echo "  Added to $SHELL_RC"
else
    echo "  Already in PATH"
fi

export PATH="$BIN_DIR:$PATH"

# 4. 設定ディレクトリ
echo "[4/5] Creating config..."
mkdir -p "$HAYABUSA_HOME"

# デフォルト設定ファイル
if [ ! -f "$HAYABUSA_HOME/config.json" ]; then
    cat > "$HAYABUSA_HOME/config.json" << 'CONF'
{
  "default_model": "models/Qwen3.5-9B-Q4_K_M.gguf",
  "default_backend": "llama",
  "default_port": 8080,
  "kv_quantize": "int8",
  "project_dir": ""
}
CONF
    # プロジェクトディレクトリを自動設定
    python3 -c "
import json
with open('$HAYABUSA_HOME/config.json') as f:
    cfg = json.load(f)
cfg['project_dir'] = '$HAYABUSA_DIR'
with open('$HAYABUSA_HOME/config.json', 'w') as f:
    json.dump(cfg, f, indent=2)
"
    echo "  Config: $HAYABUSA_HOME/config.json"
fi

# 5. スラッシュコマンドのパスを更新
echo "[5/5] Updating slash commands..."
for cmd in "$HAYABUSA_DIR/.claude/commands/"*.md; do
    if grep -q "/Users/" "$cmd" 2>/dev/null; then
        sed -i '' "s|/Users/[^/]*/Desktop/hayabusa/.build/[^/]*/release/HayabusaCLI|hayabusa|g" "$cmd"
        sed -i '' "s|/Users/[^/]*/Desktop/hayabusa/.build/arm64-apple-macosx/release/HayabusaCLI|hayabusa|g" "$cmd"
        echo "  Updated: $(basename $cmd)"
    fi
done

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Setup Complete!                         ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "使い方:"
echo "  hayabusa server start    サーバー起動"
echo "  hayabusa classify \"...\"  タスク分類"
echo "  hayabusa compress \"...\"  圧縮"
echo "  hayabusa judge ...       品質比較"
echo "  hayabusa bench ...       ベンチマーク"
echo "  hayabusa savings         節約レポート"
echo "  hayabusa health          ヘルスチェック"
echo ""
echo "新しいターミナルを開くか、以下を実行:"
echo "  source $SHELL_RC"

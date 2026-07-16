#!/usr/bin/env bash
# =========================================================
# iPhone 16 256GB ピンク（SIMフリー）[整備済製品] 在庫監視
# =========================================================
set -uo pipefail

# ---- 監視対象 ----
URL="https://www.apple.com/jp/shop/product/fydy3j/a/iphone-16-256gb-%E3%83%94%E3%83%B3%E3%82%AF-sim%E3%83%95%E3%83%AA%E3%83%BC-%E6%95%B4%E5%82%99%E6%B8%88%E8%A3%BD%E5%93%81"
PART="FYDY3J/A"          # 品番。ページが正しく取れたかの確認に使う
NAME="iPhone 16 256GB ピンク（整備済製品）"

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"

LOOPS="${LOOPS:-5}"        # 1回の起動で何回チェックするか
INTERVAL="${INTERVAL:-55}" # チェックの間隔（秒）
STATE_FILE="state.txt"     # 前回の状態を覚えておくファイル

# ---- ntfyに通知を送る ----
notify() {
  local title="$1" message="$2" priority="$3" tags="$4"
  jq -n \
    --arg topic    "$NTFY_TOPIC" \
    --arg title    "$title" \
    --arg message  "$message" \
    --arg click    "$URL" \
    --arg tags     "$tags" \
    --argjson priority "$priority" \
    '{topic:$topic, title:$title, message:$message,
      priority:$priority, tags:($tags|split(",")), click:$click}' \
  | curl -s -m 15 -X POST -H "Content-Type: application/json" -d @- https://ntfy.sh > /dev/null
  echo ">>> 通知を送信: $title"
}

# ---- 1回だけ在庫を見る。結果を IN / OUT / ERR で返す ----
check_once() {
  local body code
  body=$(mktemp)
  code=$(curl -sL -o "$body" -w '%{http_code}' -m 25 \
           -A "$UA" \
           -H 'Accept-Language: ja-JP,ja;q=0.9' \
           -H 'Accept: text/html,application/xhtml+xml' \
           "$URL")

  # HTTPステータスが200以外＝取得失敗
  if [ "$code" != "200" ]; then
    echo "  HTTP $code が返りました" >&2
    rm -f "$body"; echo "ERR"; return
  fi

  # 品番が無い＝別のページ（ボット判定ページ等）を掴んでいる
  if ! grep -qF "$PART" "$body"; then
    echo "  品番 $PART が見つかりません（ブロックの可能性）" >&2
    rm -f "$body"; echo "ERR"; return
  fi

  # 在庫切れ
  if grep -qF 'schema.org/OutOfStock' "$body"; then
    rm -f "$body"; echo "OUT"; return
  fi

  # 在庫あり
  if grep -qF 'schema.org/InStock' "$body"; then
    rm -f "$body"; echo "IN"; return
  fi

  # どちらでもない＝仕様が変わったかも。念のためERR扱いで知らせる
  echo "  OutOfStock/InStock のどちらも見つかりません" >&2
  rm -f "$body"; echo "ERR"
}

# ---- ここから本体 ----
old="OUT"
[ -f "$STATE_FILE" ] && old="$(cat "$STATE_FILE")"
echo "前回の状態: $old"

# 手動実行のときだけテスト通知を飛ばす
if [ "${TEST_NOTIFY:-0}" = "1" ]; then
  notify "テスト通知" "監視は正常に動いています。現在の状態: ${old}" 3 "white_check_mark"
fi

for i in $(seq 1 "$LOOPS"); do
  now="$(check_once)"
  echo "[$(date -u '+%H:%M:%S') UTC] チェック#${i} -> ${now}"

  if [ "$now" = "IN" ]; then
    # 在庫あり: 状態が変わった瞬間 + 在庫がある間は5分おきにリマインド
    if [ "$old" != "IN" ] || [ $(( i % 5 )) -eq 1 ]; then
      notify "入荷しました！" "${NAME} が在庫ありになりました。今すぐ購入してください。" 5 "rotating_light,tada"
    fi
  elif [ "$now" != "$old" ]; then
    case "$now" in
      OUT)
        if [ "$old" = "IN" ]; then
          notify "売り切れました" "${NAME} は在庫なしに戻りました。監視を続けます。" 2 "x"
        else
          notify "監視が復旧しました" "ページを正常に取得できました。監視を続けます。" 2 "arrows_counterclockwise"
        fi ;;
      ERR)
        notify "監視エラー" "ページを取得できません。GitHubのログを確認してください。" 4 "warning" ;;
    esac
  fi

  if [ "$now" != "$old" ]; then
    old="$now"
    echo "$now" > "$STATE_FILE"
  fi

  [ "$i" -lt "$LOOPS" ] && sleep "$INTERVAL"
done

echo "完了。最終状態: $old"

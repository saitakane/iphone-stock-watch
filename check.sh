#!/usr/bin/env bash
# =========================================================
# iPhone 16 256GB [整備済製品] 在庫監視（複数カラー対応版）
#
# 監視対象：ピンク / ウルトラマリン / ティール / ホワイト
#
# 仕組み
#   1) 整備済iPhone一覧ページを取得
#   2) 各カラーの商品ページURLを一覧から自動発見
#      （品番を事前に知らなくてよい。URLから品番も自動取得）
#   3) 商品ページで在庫判定（従来と同じ条件）
#   4) IN候補なら10秒間隔で追加2回確認 → 3回連続INで通知
#
# 一覧に載っていない = 販売ページなし = OUT 扱い
# =========================================================

set -uo pipefail


# =========================================================
# 監視対象  「キー|カラー名|固定URL(省略可)」
#
# 固定URLを書くと一覧からの自動発見をせず、そのURLを直接見ます。
# 空欄なら一覧ページから自動発見します。
# =========================================================

TARGETS=(
  "pink|ピンク|https://www.apple.com/jp/shop/product/fydy3j/a/iphone-16-256gb-%E3%83%94%E3%83%B3%E3%82%AF-sim%E3%83%95%E3%83%AA%E3%83%BC-%E6%95%B4%E5%82%99%E6%B8%88%E8%A3%BD%E5%93%81"
  "ultramarine|ウルトラマリン|https://www.apple.com/jp/shop/product/fye03j/a/iphone-16-256gb-%E3%82%A6%E3%83%AB%E3%83%88%E3%83%A9%E3%83%9E%E3%83%AA%E3%83%B3-sim%E3%83%95%E3%83%AA%E3%83%BC-%E6%95%B4%E5%82%99%E6%B8%88%E8%A3%BD%E5%93%81"
  "teal|ティール|https://www.apple.com/jp/shop/product/fye13j/a/iphone-16-256gb-%E3%83%86%E3%82%A3%E3%83%BC%E3%83%AB-sim%E3%83%95%E3%83%AA%E3%83%BC-%E6%95%B4%E5%82%99%E6%B8%88%E8%A3%BD%E5%93%81"
  "white|ホワイト|https://www.apple.com/jp/shop/product/fydx3j/a/iphone-16-256gb-%E3%83%9B%E3%83%AF%E3%82%A4%E3%83%88-sim%E3%83%95%E3%83%AA%E3%83%BC-%E6%95%B4%E5%82%99%E6%B8%88%E8%A3%BD%E5%93%81"
  "black|ブラック|https://www.apple.com/jp/shop/product/fydw3j/a/iphone-16-256gb-%E3%83%96%E3%83%A9%E3%83%83%E3%82%AF-sim%E3%83%95%E3%83%AA%E3%83%BC-%E6%95%B4%E5%82%99%E6%B8%88%E8%A3%BD%E5%93%81"
)


LIST_URL="https://www.apple.com/jp/shop/refurbished/iphone"

# 一覧から探す商品名の接頭辞（iPhone 16 Plus / 16e を拾わないよう "16-256gb-" で固定）
MODEL_SLUG="iphone-16-256gb"

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"


# =========================================================
# 基本設定
# =========================================================

LOOPS="${LOOPS:-55}"
INTERVAL="${INTERVAL:-60}"
CONFIRM_INTERVAL="${CONFIRM_INTERVAL:-10}"

# テスト用
#   TEST_NOTIFY=1       … 開始時にテスト通知を1通送る
#   SIMULATE_IN=<キー>  … そのカラーが入荷した体で通知経路をテスト
#                         （状態はコミットされない一時フォルダに保存）
TEST_NOTIFY="${TEST_NOTIFY:-0}"
SIMULATE_IN="${SIMULATE_IN:-}"

if [ -n "$SIMULATE_IN" ]; then
  STATE_DIR="$(mktemp -d)"
else
  STATE_DIR="state"
  mkdir -p "$STATE_DIR"
fi

LISTING_FILE="$(mktemp)"
LISTING_OK=0


# =========================================================
# ntfyへ通知
#   notify タイトル 本文 優先度 タグ クリック先URL
# =========================================================

notify() {

  local title="$1"
  local message="$2"
  local priority="$3"
  local tags="$4"
  local click="$5"

  local payload
  local attempt

  payload="$(
    jq -n \
      --arg topic "${NTFY_TOPIC:-}" \
      --arg title "$title" \
      --arg message "$message" \
      --arg click "$click" \
      --arg tags "$tags" \
      --argjson priority "$priority" \
      '{
        topic:$topic,
        title:$title,
        message:$message,
        priority:$priority,
        tags:($tags|split(",")),
        click:$click
      }'
  )"

  # 失敗（通信エラー・HTTP 4xx/5xx）したら最大3回リトライ
  for attempt in 1 2 3; do
    if printf '%s' "$payload" | curl -sS -f \
         -m 8 \
         -X POST \
         -H "Content-Type: application/json" \
         -d @- \
         https://ntfy.sh \
         > /dev/null; then
      echo ">>> 通知を送信: $title"
      return 0
    fi
    echo ">>> 通知失敗（${attempt}/3回目）" >&2
    sleep 2
  done

  return 1
}


# =========================================================
# 一覧ページを取得（1ループにつき1回）
# =========================================================

fetch_listing() {

  local code

  LISTING_OK=0

  code="$(
    curl -sS -L \
         -o "$LISTING_FILE" \
         -w '%{http_code}' \
         -m 10 \
         -A "$UA" \
         -H 'Accept-Language: ja-JP,ja;q=0.9' \
         -H 'Accept: text/html,application/xhtml+xml' \
         -H 'Cache-Control: no-cache' \
         -H 'Pragma: no-cache' \
         "$LIST_URL"
  )" || {
    echo "  一覧ページ取得失敗（curl）" >&2
    return
  }

  if [ "$code" != "200" ]; then
    echo "  一覧ページ HTTP $code" >&2
    return
  fi

  # 商品リンクが1件もなければ、HTML仕様変更やブロックの可能性
  if ! grep -qiF '/shop/product/' "$LISTING_FILE"; then
    echo "  一覧ページに商品リンクがありません（仕様変更・ブロックの可能性）" >&2
    return
  fi

  LISTING_OK=1
}


# =========================================================
# 一覧からカラーの商品ページURLを探す
#   見つかればURLを出力、なければ何も出力しない
# =========================================================

find_url() {

  local color="$1"
  local enc
  local path

  enc="$(jq -rn --arg s "$color" '$s|@uri')"

  path="$(
    grep -oiE "/shop/product/[a-z0-9]+/a/${MODEL_SLUG}-${enc}[^\"'? <>]*" "$LISTING_FILE" \
    | head -n1
  )"

  if [ -n "$path" ]; then
    echo "https://www.apple.com/jp${path}"
  fi
}


# =========================================================
# 商品ページを1回確認
#   check_once URL
#   結果: IN / OUT / ERR
# =========================================================

check_once() {

  local url="$1"
  local body
  local code
  local curl_rc
  local seg
  local part

  # URLから品番を自動取得  /product/fydy3j/a/ → FYDY3J/A
  seg="$(printf '%s' "$url" | sed -nE 's#.*/product/([A-Za-z0-9]+)/a/.*#\1#p')"
  part="$(printf '%s' "$seg" | tr '[:lower:]' '[:upper:]')/A"

  body="$(mktemp)"

  code="$(
    curl -sS \
         -L \
         -o "$body" \
         -w '%{http_code}' \
         -m 10 \
         -A "$UA" \
         -H 'Accept-Language: ja-JP,ja;q=0.9' \
         -H 'Accept: text/html,application/xhtml+xml' \
         -H 'Cache-Control: no-cache' \
         -H 'Pragma: no-cache' \
         "$url"
  )"

  curl_rc=$?

  if [ "$curl_rc" -ne 0 ]; then
    echo "  curl失敗（exit=${curl_rc}）" >&2
    rm -f "$body"
    echo "ERR"
    return
  fi

  if [ "$code" != "200" ]; then
    echo "  HTTP $code が返りました" >&2
    rm -f "$body"
    echo "ERR"
    return
  fi

  # 対象商品か確認（ボット判定ページ等の誤判定防止）
  if ! grep -qF "$part" "$body"; then
    echo "  品番 $part が見つかりません" >&2
    echo "  別ページ・ブロック・HTML仕様変更の可能性があります" >&2
    rm -f "$body"
    echo "ERR"
    return
  fi

  # 在庫切れ判定（最優先）
  if grep -qF 'schema.org/OutOfStock' "$body" \
     || grep -qF '在庫切れ' "$body"; then
    rm -f "$body"
    echo "OUT"
    return
  fi

  # 在庫あり判定（InStock かつ 「バッグに追加」）
  if grep -qF 'schema.org/InStock' "$body" \
     && grep -qF 'バッグに追加' "$body"; then
    rm -f "$body"
    echo "IN"
    return
  fi

  # 矛盾・判定不能
  if grep -qF 'schema.org/InStock' "$body"; then
    echo "  InStock はありますが『バッグに追加』がありません → ERR扱い" >&2
  elif grep -qF 'バッグに追加' "$body"; then
    echo "  『バッグに追加』はありますが InStock がありません → ERR扱い" >&2
  else
    echo "  在庫状態を確定できるシグナルがありません" >&2
  fi

  rm -f "$body"
  echo "ERR"
}


# =========================================================
# IN候補を追加確認（10秒間隔で2回、計3回連続INで成功）
# =========================================================

confirm_in_stock() {

  local url="$1"
  local r2
  local r3

  echo "  IN候補を検出 → ${CONFIRM_INTERVAL}秒後に再確認"

  sleep "$CONFIRM_INTERVAL"
  r2="$(check_once "$url")"
  echo "  確認2/3 -> $r2"
  [ "$r2" = "IN" ] || { echo "  2回目がINではないため中止"; return 1; }

  sleep "$CONFIRM_INTERVAL"
  r3="$(check_once "$url")"
  echo "  確認3/3 -> $r3"
  [ "$r3" = "IN" ] || { echo "  3回目がINではないため中止"; return 1; }

  echo "  ★ 3回連続で購入可能条件を確認"
  return 0
}


# =========================================================
# OUT再確認（IN→OUTの揺れ対策）
# =========================================================

confirm_out_of_stock() {

  local url="$1"
  local r2

  echo "  OUT候補を検出 → ${CONFIRM_INTERVAL}秒後に再確認"

  sleep "$CONFIRM_INTERVAL"
  r2="$(check_once "$url")"
  echo "  OUT再確認 -> $r2"

  [ "$r2" = "OUT" ]
}


# =========================================================
# 1カラー分の処理
#   process_target キー カラー名 固定URL
# =========================================================

process_target() {

  local key="$1"
  local color="$2"
  local fixed="$3"

  local state_file="${STATE_DIR}/${key}.txt"
  local old="OUT"
  local url="$fixed"
  local now

  # 前回の確定状態を読み込み
  if [ -f "$state_file" ]; then
    old="$(tr -d '\r\n' < "$state_file")"
  elif [ "$key" = "pink" ] && [ -f "state.txt" ] && [ -z "$SIMULATE_IN" ]; then
    # 旧バージョン(state.txt)からの引き継ぎ
    old="$(tr -d '\r\n' < state.txt)"
  fi

  case "$old" in
    IN|OUT) ;;
    *) old="OUT" ;;
  esac


  # ---------------------------------------------------
  # 今回の状態を判定
  # ---------------------------------------------------

  if [ "$SIMULATE_IN" = "$key" ]; then

    # 通知経路テスト用：入荷した体にする
    echo "  [$color] ★シミュレーション：INとして扱います"
    now="IN"
    [ -n "$url" ] || url="$LIST_URL"

  else

    if [ -z "$url" ]; then
      if [ "$LISTING_OK" -ne 1 ]; then
        echo "  [$color] 一覧ページを取得できず判定不能"
        echo "  [$color] -> ERR（確定状態 $old を維持）"
        return
      fi
      url="$(find_url "$color")"
      if [ -z "$url" ]; then
        echo "  [$color] 一覧に掲載なし -> OUT"
        now="OUT"
      fi
    fi

    if [ -z "${now:-}" ]; then
      now="$(check_once "$url")"
    fi

    echo "  [$color] -> ${now}  ($url)"

  fi


  # ---------------------------------------------------
  # 状態遷移
  # ---------------------------------------------------

  case "$now" in

    IN)

      if [ "$old" = "IN" ]; then

        echo "  [$color] 在庫あり継続中（通知済み）"

      else

        if [ "$SIMULATE_IN" = "$key" ] || confirm_in_stock "$url"; then

          local title="入荷しました！（${color}）"
          if [ "$SIMULATE_IN" = "$key" ]; then
            title="【テスト】${title}"
          fi

          # 通知が成功した場合だけ「通知済み(IN)」として記録する。
          # 失敗時はOUTのまま → 次のループで再確認して再通知を試みる
          if notify \
               "$title" \
               "iPhone 16 256GB ${color}（整備済製品）の購入可能状態を3回連続で確認しました。今すぐ購入ページを確認してください。" \
               5 \
               "rotating_light,tada" \
               "$url"; then
            echo "IN" > "$state_file"
          else
            echo "  [$color] 通知に失敗。次のループで再試行します"
          fi

        else

          echo "  [$color] 誤検知または一時的な表示揺れと判断。通知しません"

        fi

      fi
      ;;

    OUT)

      if [ "$old" = "IN" ]; then

        if confirm_out_of_stock "$url"; then
          echo "OUT" > "$state_file"
          echo "  [$color] 在庫なしを2回連続確認。確定状態をOUTに戻しました"
        else
          echo "  [$color] OUTは一時的な揺れと判断。確定状態INを維持"
        fi

      else

        if [ ! -f "$state_file" ] \
           || [ "$(tr -d '\r\n' < "$state_file" 2>/dev/null || true)" != "OUT" ]; then
          echo "OUT" > "$state_file"
        fi

      fi
      ;;

    ERR)

      echo "  [$color] 判定不能。確定状態は $old のまま維持（通知なし）"
      ;;

  esac
}


# =========================================================
# 本体
# =========================================================

echo "========================================"
echo "iPhone 16 256GB 在庫監視開始（複数カラー）"
echo "対象: ${#TARGETS[@]} カラー / ループ ${LOOPS}回 / 間隔 ${INTERVAL}秒"
[ -n "$SIMULATE_IN" ] && echo "シミュレーションモード: $SIMULATE_IN"
echo "========================================"


# プローブ：指定URLを1回だけ判定して終了（IN判定の検証用。在庫ありページで試す）
if [ -n "${PROBE_URL:-}" ]; then
  echo "プローブ対象: $PROBE_URL"
  probe_body="$(mktemp)"
  curl -sS -L -o "$probe_body" -m 10 -A "$UA" \
       -H 'Accept-Language: ja-JP,ja;q=0.9' \
       -H 'Accept: text/html,application/xhtml+xml' \
       -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
       "$PROBE_URL" || echo "  curl失敗"
  echo "  サイズ: $(wc -c < "$probe_body") bytes"
  echo "  schema.org/InStock    : $(grep -cF 'schema.org/InStock' "$probe_body") 行"
  echo "  schema.org/OutOfStock : $(grep -cF 'schema.org/OutOfStock' "$probe_body") 行"
  echo "  バッグに追加          : $(grep -cF 'バッグに追加' "$probe_body") 行"
  echo "  在庫切れ              : $(grep -cF '在庫切れ' "$probe_body") 行"
  echo "判定結果: $(check_once "$PROBE_URL")"
  rm -f "$probe_body"
  exit 0
fi


# テスト通知（手動実行時）
if [ "$TEST_NOTIFY" = "1" ]; then
  notify \
    "【テスト】在庫監視は動作中" \
    "このメッセージが届けば、GitHub Actions → ntfy の通知経路は正常です。" \
    3 \
    "white_check_mark" \
    "$LIST_URL"
fi


for i in $(seq 1 "$LOOPS"); do

  loop_start="$(date +%s)"

  echo "[$(date -u '+%H:%M:%S') UTC] チェック#${i}"

  fetch_listing

  if [ "$LISTING_OK" -eq 1 ]; then
    n="$(grep -oiE '/shop/product/[a-z0-9]+/a/' "$LISTING_FILE" | sort -u | wc -l | tr -d ' ')"
    echo "  一覧ページ取得OK（商品リンク ${n} 件）"
  fi

  for t in "${TARGETS[@]}"; do
    IFS='|' read -r key color fixed <<< "$t"
    process_target "$key" "$color" "$fixed"
  done

  # 処理時間を差し引いて、開始から INTERVAL 秒ごとに回す
  if [ "$i" -lt "$LOOPS" ]; then
    elapsed=$(( $(date +%s) - loop_start ))
    wait_sec=$(( INTERVAL - elapsed ))
    if [ "$wait_sec" -gt 0 ]; then
      sleep "$wait_sec"
    fi
  fi

done

rm -f "$LISTING_FILE"

echo "========================================"
echo "監視終了"
echo "========================================"

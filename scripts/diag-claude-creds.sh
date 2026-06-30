#!/usr/bin/env bash
# QuotaBar — Claude 자격증명 진단 v3 (읽기 전용)
# 토큰 '값'은 절대 출력하지 않음 (존재 여부 / 길이 / 키 이름만).
# 결과를 scripts/diag-output.txt 에도 저장 → Claude가 직접 읽음.
# 사용법:  bash scripts/diag-claude-creds.sh
set -uo pipefail

SVC="Claude Code-credentials"
OUT="$(cd "$(dirname "$0")" && pwd)/diag-output.txt"

run() {
echo "QuotaBar Claude credential diagnostic v3"
echo "date: $(date)"
echo

echo "=== 1) 자격증명 파일 ==="
for f in "$HOME/.claude/.credentials.json" "$HOME/.claude.json" "$HOME/.config/claude/credentials.json"; do
  if [ -f "$f" ]; then
    python3 - "$f" <<'PY'
import json, sys, datetime
f = sys.argv[1]
try:
    d = json.load(open(f)); o = d.get("claudeAiOauth", d)
    acc = o.get("accessToken") or o.get("access_token")
    ref = o.get("refreshToken") or o.get("refresh_token")
    exp = o.get("expiresAt") or o.get("expires_at")
    topkeys = sorted(list(d.keys()))[:20]
    print(f"{f}")
    print(f"   access:{'있음' if acc else '없음'}  refresh:{'있음' if ref else '없음'}  expiresAt:{exp}")
    print(f"   top-level keys: {topkeys}")
except Exception as e:
    print(f"{f}\n   파싱 실패: {e}")
PY
  else
    echo "$f"; echo "   없음"
  fi
done
echo

echo "=== 2) 키체인: '$SVC' 항목 전체 ==="
ACCTS=$(security dump-keychain 2>/dev/null \
  | grep -B8 "\"svce\"<blob>=\"$SVC\"" \
  | grep '"acct"' \
  | sed -E 's/^.*"acct"<blob>="?([^"]*)"?.*/\1/' | sort -u)
CNT=$(security dump-keychain 2>/dev/null | grep -c "\"svce\"<blob>=\"$SVC\"")
echo "   매칭 항목 개수: $CNT"
if [ -z "$ACCTS" ]; then
  echo "   (account 라벨 못 읽음 — 기본 매칭만 검사)"
  ACCTS="__DEFAULT__"
fi
while IFS= read -r a; do
  if [ "$a" = "__DEFAULT__" ]; then
    RAW=$(security find-generic-password -s "$SVC" -w 2>/dev/null); RC=$?
    label="(기본 매칭)"
  else
    RAW=$(security find-generic-password -s "$SVC" -a "$a" -w 2>/dev/null); RC=$?
    label="acct='$a'"
  fi
  LEN=$(printf '%s' "$RAW" | wc -c | tr -d ' ')
  has() { case "$RAW" in *"$1"*) echo "O";; *) echo "X";; esac; }
  if [ "$RC" -ne 0 ]; then
    echo "   $label  읽기실패(rc=$RC)"
  else
    echo "   $label  길이=$LEN  access=$(has accessToken)$(has access_token)  refresh=$(has refreshToken)$(has refresh_token)  exp=$(has expiresAt)$(has expires_at)"
  fi
done <<< "$ACCTS"
echo

echo "=== 3) claude 실행파일 / 로그인 추정 ==="
if command -v claude >/dev/null 2>&1; then
  echo "   bin: $(command -v claude)"
else
  echo "   PATH에서 claude 못 찾음"
fi
# ~/.claude.json 의 oauthAccount 유무로 '로그인된 적 있는지' 추정
python3 - "$HOME/.claude.json" <<'PY' 2>/dev/null || echo "   (.claude.json 없음/파싱불가)"
import json,sys
d=json.load(open(sys.argv[1]))
oa=d.get("oauthAccount") or d.get("oauth_account")
print("   .claude.json oauthAccount:", "있음" if oa else "없음")
PY
echo
echo "끝."
}

run | tee "$OUT"
echo
echo ">>> 결과가 저장됐습니다: $OUT"
echo ">>> 이 파일은 토큰 값 없이 안전합니다. Claude가 직접 읽습니다."

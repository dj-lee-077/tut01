#!/usr/bin/env bash
# 과제 2: NeoFirm 조사 → AI 에이전트 토론 → 사업계획 → 검증 → 발표자료를 NotebookLM CLI로 완전 자동 실행
# 사용법: neofirm/run.sh ["아이템 설명"]        (기본: 임차인 보증금 보호·반환(전월세))
#   환경변수  RUN=neofirm/auto   결과 폴더 / URLS=neofirm/sources/urls.txt  조사 소스 URL 목록
#            NLM=~/notebooklm-cli/nlm   (Dokkabei97/notebooklm-cli, 소스 추가·인용 질의)
# 역할 분담
#   nlm        : 노트북 생성, 소스 추가, 인용 포함 질의(조사·검증)
#   notebooklm : 딥 리서치(nlm의 research는 v0.1.0에서 동작 안 함), 한국어 슬라이드 생성·다운로드
#   claude -p  : 에이전트 토론(서브에이전트 4개), 사업계획서·원고 작성, 주장 추출·정정
# 단계마다 완료 표시(.done_*)를 남겨, 중간에 멈춰도 다시 실행하면 이어서 진행한다.
# 사람 개입이 필요한 것은 로그인뿐이다(만료 시 안내 후 종료).
set -euo pipefail
cd "$(dirname "$0")/.."

# nlm과 notebooklm(py)은 둘 다 ~/.notebooklm 을 쓰고, py가 nlm의 로그인 파일을 옮겨 버리는 충돌이 있어
# py의 저장 위치를 분리한다(nlm은 ~/.notebooklm 그대로).
export NOTEBOOKLM_HOME="${NOTEBOOKLM_HOME:-$HOME/.notebooklm-py}"

TOPIC="${1:-임차인 보증금 보호·반환(전월세 계약 전 점검부터 만기 미반환 분쟁까지)}"
RUN="${RUN:-neofirm/auto}"
URLS="${URLS:-neofirm/sources/urls.txt}"
NLM="${NLM:-$HOME/notebooklm-cli/nlm}"
RES="$RUN/research"; DEB="$RUN/debate"; OUT="$RUN/output"; LOG="$RUN/logs"
mkdir -p "$RES" "$DEB" "$OUT" "$LOG"
: > /dev/null

say()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG/run.log"; }
stage() { local n="$1"; shift; if [ -f "$LOG/.done_$n" ]; then say "건너뜀(완료됨): $n"; return 0; fi
          say "== 단계 시작: $n"; local t0=$SECONDS; "$@"; touch "$LOG/.done_$n"; say "== 단계 완료: $n ($((SECONDS-t0))초)"; }
# claude -p 호출: 결과 텍스트를 $3 파일로 저장(에이전트가 직접 파일을 쓰지 않는다 — 자동 실행에서는 서브에이전트의 쓰기 권한이 거부됨)
claude_text() {  # $1=라벨 $2=프롬프트 $3=결과 텍스트 파일
  local out
  out="$(claude -p "$2" --permission-mode acceptEdits --output-format json 2>>"$LOG/claude.err")" || { say "claude 호출 실패: $1"; return 1; }
  [ -f "$LOG/claude_calls.csv" ] || echo "label,input,cache_create,cache_read,output,turns,cost_usd" > "$LOG/claude_calls.csv"
  echo "$out" | jq -r --arg l "$1" '[$l,(.usage.input_tokens//0),(.usage.cache_creation_input_tokens//0),(.usage.cache_read_input_tokens//0),(.usage.output_tokens//0),(.num_turns//0),(.total_cost_usd//0)]|@csv' >> "$LOG/claude_calls.csv"
  echo "$out" | jq -r '.result' > "$3"
  [ -s "$3" ] || { say "빈 응답: $1"; return 1; }
}
# 응답 속의 '<<<FILE 이름>>>' 구분선 단위로 파일을 나눠 저장
split_files() {  # $1=응답 파일 $2=저장 폴더
  awk -v out="$2" '/^<<<FILE /{ if (f) close(f); n=$2; sub(/>>>$/,"",n); f=out"/"n; printf "" > f; next } f { print > f }' "$1"
}

# ---------------------------------------------------------------- 0. 사전 점검
preflight() {
  command -v jq >/dev/null     || { echo "jq가 필요합니다" >&2; exit 3; }
  command -v claude >/dev/null || { echo "claude가 필요합니다" >&2; exit 3; }
  [ -x "$NLM" ]                || { echo "nlm 없음: $NLM (cd ~/notebooklm-cli && make build)" >&2; exit 3; }
  [ -f neofirm/input/NeoFirm-2026-Report.md ] || { echo "neofirm/input/NeoFirm-2026-Report.md 가 없습니다" >&2; exit 3; }
  "$NLM" auth status >/dev/null 2>&1 || { echo "nlm 로그인 필요: $NLM auth login --reuse" >&2; exit 3; }
  [ -f "$LOG/.done_deep_research" ] || notebooklm auth check --test >/dev/null 2>&1 || { echo "notebooklm 로그인 필요: NOTEBOOKLM_HOME=$NOTEBOOKLM_HOME notebooklm login --browser-cookies chrome --account a74658@gachon.ac.kr" >&2; exit 3; }
}
say "NeoFirm 자동 파이프라인 시작 — 아이템: $TOPIC"
preflight

# ---------------------------------------------------------------- 1. 노트북 + 소스
setup_notebook() {
  local nb
  nb="$("$NLM" --json notebook create "NeoFirm-자동-$(date +%m%d-%H%M)" | jq -r '.id')"
  [ -n "$nb" ] && [ "$nb" != null ] || { echo "노트북 ID를 읽지 못했습니다" >&2; exit 1; }
  echo "$nb" > "$LOG/notebook_id"
  "$NLM" use "$nb" >/dev/null
  "$NLM" source add neofirm/input/NeoFirm-2026-Report.md --wait -n "$nb" >/dev/null && say "  소스: NeoFirm 리포트"
  if [ -f "$URLS" ]; then
    while IFS= read -r u; do [ -z "$u" ] && continue
      if "$NLM" source add "$u" --wait -n "$nb" >/dev/null 2>&1; then say "  소스: $u"; else say "  소스 실패(건너뜀): $u"; fi
    done < "$URLS"
  fi
}
stage notebook setup_notebook
NB="$(cat "$LOG/notebook_id")"

# ---------------------------------------------------------------- 2. 조사 (NotebookLM 딥 리서치 + 인용 질의)
deep_research() {
  notebooklm source add-research "$TOPIC 의 국내 시장 규모, 소비자 불만, 기존 서비스 가격, 관련 법규와 최근 판례·제도 변화" \
    --mode deep --import-all --cited-only -n "$NB" --timeout 900 >> "$LOG/deep_research.log" 2>&1 \
    || say "  딥 리서치 실패(기사 URL 소스만으로 진행): $LOG/deep_research.log 참고"
}
stage deep_research deep_research

ask() {  # $1=파일 접두어 $2=질문 [$3...=nlm chat ask 추가 인자]
  local k="$1" q="$2"; shift 2
  "$NLM" --json chat ask "$q" -n "$NB" "$@" > "$RES/nlm_$k.json"
  { echo "# $q"; echo; jq -r '.answer' "$RES/nlm_$k.json"; echo; echo "## 인용"
    jq -r '(.sources // [])[] | "- [" + .source_name + "] " + (.text | .[0:140] | gsub("\n";" "))' "$RES/nlm_$k.json"; } > "$RES/nlm_$k.md"
  say "  질의 저장: $RES/nlm_$k.md"
}
research_qa() {
  ask value_chain "$TOPIC: 고객이 구매하는 결과, 현재 업무 단계, 단계별 담당자·소요시간, 소비자가 가장 불편해하는 점을 소스에 근거해 정리해줘. 근거가 없으면 없다고 말해줘."
  ask market      "$TOPIC: 시장 규모(건수·금액), 현재 소비자가 쓰는 비용과 소요기간, 최근 추세를 소스에 근거해 정리해줘. 확인되지 않는 수치는 확인되지 않는다고 말해줘."
  ask regulation  "$TOPIC: 관련 법규와 판례·제도 변화를 소스에 근거해 정리하고, 비자격자 회사가 할 수 있는 일과 자격사 책임이 필요한 일을 구분해줘. 판결을 허용 근거로 확대 해석하지 말고 소스에 적힌 그대로 말해줘."
  ask alternatives "$TOPIC: 소스에 나타난 기존·대안 서비스(공공 서비스, 플랫폼, 전문가)와 그 한계를 정리해줘. 소스에 없으면 없다고 말해줘."
  ask neofirm_fit "NeoFirm 리포트의 판별 6개 질문과 단위경제 식을 기준으로, 이 아이템이 어떤 조건을 충족·미충족하는지 소스에 근거해 정리해줘."
}
stage research_qa research_qa

# ---------------------------------------------------------------- 3. AI 에이전트 토론 (서브에이전트 4개)
debate_round() {  # $1=라운드 $2=역할(founder|vc|regulator) $3=지시
  local tmp="$LOG/last_debate.txt"
  claude_text "debate_r$1_$2" "neofirm-$2 서브에이전트를 사용해 토론 라운드 $1 발언을 작성하게 해줘. 아이템: $TOPIC. 서브에이전트는 먼저 $RES/nlm_*.md(NotebookLM 인용 답변)와 $DEB/debate.md를 읽고, 근거는 nlm 답변의 인용 또는 '가정'으로만 쓴다. 지시: $3.
출력 규칙: 서브에이전트가 돌려준 발언 본문만 그대로 출력해줘. 파일에 쓰지 말고, 머리말·설명·맺음말을 붙이지 마. 300~500자." "$tmp" || return 1
  { echo; echo "## 라운드 $1 — $2"; echo; cat "$tmp"; } >> "$DEB/debate.md"
  say "  토론 라운드 $1 $2 추가 ($(wc -c < "$tmp")바이트)"
}
run_debate() {
  echo "# 에이전트 토론 기록 — $TOPIC" > "$DEB/debate.md"
  debate_round 1 founder   "사업안(결과 정의, 과금 모델, 토큰 가격 1/100 가정에서의 단위경제, 해자, GTM)을 제시"
  debate_round 1 vc        "시장성·단위경제·복리형 성장 여부를 검증하고 가장 큰 약점 1개를 지적"
  debate_round 1 regulator "책임 주체·업무범위·데이터 권리 위험을 검증하고 판결·법규는 소스 그대로 인용"
  debate_round 2 founder   "VC와 규제 전문가의 지적 중 가장 아픈 점에 직접 반박 또는 수용"
  debate_round 2 vc        "창업자 반박에서 가장 약한 지점을 재반박"
  debate_round 2 regulator "창업자 반박에서 법적으로 가장 약한 지점을 재반박"
  debate_round 3 founder   "반박을 반영해 사업안을 수정(과금·해자·GTM·책임 구조)"
  debate_round 3 vc        "수정안에 남은 우려 1개"
  debate_round 3 regulator "수정안에 남은 우려 1개와 출시 전 확정해야 할 법률 자문 항목"
  claude_text "debate_judge" "neofirm-judge 서브에이전트를 사용해 $DEB/debate.md 를 읽고 평가 기준 5개(결과 명확, 정상경로·예외 분리, 책임, 데이터 해자, 가격-생산성 이해 일치)로 각 1~5점 채점하게 하고, 근거를 인용해 최종안과 총점(25점 만점)을 마크다운으로 작성하게 해줘. 출력 규칙: 서브에이전트가 돌려준 판정 본문만 그대로 출력하고 파일에 쓰지 마." "$DEB/verdict.md"
  [ -s "$DEB/verdict.md" ] || { echo "verdict.md 가 생성되지 않았습니다" >&2; exit 1; }
}
stage debate run_debate

# ---------------------------------------------------------------- 4. 사업계획서·발표 원고
write_docs() {
  claude_text "write_docs" "아이템: $TOPIC. $DEB/verdict.md, $DEB/debate.md, $RES/nlm_*.md 를 읽고 근거로 삼아 3개 문서를 작성해줘.
1) plan.md — 사업계획서. 필수 섹션: 문제정의문(neofirm/input/NeoFirm-2026-Report.md 의 템플릿 사용) / 시장과 현재 지출 / 첫 표준화 업무 / 과금 모델과 서비스 혁신 / 토큰 가격 1/100 단위경제(오늘 vs 1/100 표, 계산식 명시) / AI-전문가 작업 배분과 전문가 개입률 / 책임·보험·규제 구조 / 해자 / GTM 전략 / KPI / 리스크.
2) script.md — 5분 발표 원고, 슬라이드 10장(표지, 문제, 왜 지금·토큰 1/100, 서비스·과금 혁신, 분업, 단위경제, 해자, GTM, 토론의 반론과 대응, 결론), 장당 30초.
3) qa.md — 예상 질문 5개와 답.
규칙: 출처가 nlm 답변 인용에 있는 수치만 사실로 쓰고, 나머지 모든 수치는 '가정'이라고 표시한다. 판결·법규는 nlm 답변의 표현 그대로 쓰고 허용 근거로 확대 해석하지 않는다. 소스에 없는 수치를 만들지 않는다.
출력 형식: 파일에 쓰지 말고, 각 문서를 한 줄짜리 구분선 '<<<FILE plan.md>>>', '<<<FILE script.md>>>', '<<<FILE qa.md>>>' 다음에 이어서 전부 출력해줘. 구분선 외의 머리말·설명·맺음말은 붙이지 마." "$LOG/write_docs.txt"
  split_files "$LOG/write_docs.txt" "$OUT"
  [ -s "$OUT/plan.md" ] && [ -s "$OUT/script.md" ] || { echo "plan.md/script.md 분할 실패: $LOG/write_docs.txt 확인" >&2; exit 1; }
}
stage write_docs write_docs

# ---------------------------------------------------------------- 5. NotebookLM 사실 검증 (계획서를 소스에 올리기 전 → 순환 방지)
verify_docs() {
  claude_text "extract_claims" "$OUT/plan.md 와 $OUT/script.md 를 읽고 **사실 주장**(수치, 통계, 법규·판결 해석, 시장 설명)만 번호 목록으로 뽑아줘. 가정·계획·의견은 제외하고 최대 15개, 각 항목은 한 문장으로 출처 없이 주장만. 출력은 번호 목록만, 파일에 쓰지 말고 다른 설명은 붙이지 마." "$RES/claims.txt"
  local q; q="아래 주장 목록을 노트북 소스(기사·리포트)와 대조해 표(주장 / 소스 근거 / 판정: 일치·불일치·소스에 없음)로 정리해줘. 소스에 없는 것은 없다고, 지역·기간·범위가 다른 것은 불일치로 판정해줘.
$(cat "$RES/claims.txt")"
  ask verification "$q"
  claude_text "apply_fixes" "$RES/nlm_verification.md 의 판정을 반영해 $OUT/plan.md, $OUT/script.md, $OUT/qa.md 를 읽고 정정본을 작성해줘: '불일치'는 소스대로 고치고, '소스에 없음'은 삭제하거나 '가정'으로 표시한다. 그리고 review.md 에 항목별 처리 결과 표(주장 / 판정 / 조치)와 남은 한계를 쓴다.
출력 형식: 파일에 쓰지 말고 '<<<FILE plan.md>>>', '<<<FILE script.md>>>', '<<<FILE qa.md>>>', '<<<FILE review.md>>>' 구분선 다음에 각 문서 전체를 이어서 출력해줘. 구분선 외의 설명은 붙이지 마." "$LOG/apply_fixes.txt"
  split_files "$LOG/apply_fixes.txt" "$OUT"
  [ -s "$OUT/review.md" ] || { echo "review.md 분할 실패: $LOG/apply_fixes.txt 확인" >&2; exit 1; }
}
stage verify_docs verify_docs

# ---------------------------------------------------------------- 6. 발표자료 (NotebookLM 슬라이드)
make_slides() {
  notebooklm auth check --test >/dev/null 2>&1 || { echo "notebooklm 로그인이 만료됐습니다(슬라이드 단계). 아래 명령으로 로그인한 뒤 같은 명령으로 다시 실행하면 이 단계부터 이어집니다:" >&2; echo "  NOTEBOOKLM_HOME=$NOTEBOOKLM_HOME notebooklm login --browser-cookies chrome --account a74658@gachon.ac.kr" >&2; exit 3; }
  if [ ! -f "$LOG/.sources_added" ]; then
    for f in plan.md script.md qa.md; do "$NLM" source add "$OUT/$f" --wait -n "$NB" >/dev/null && say "  소스: $f(정정본)"; done
    touch "$LOG/.sources_added"
  fi
  cat > "$LOG/slide_prompt.txt" <<EOF
script.md의 슬라이드 구성을 그대로 따라 한국어 발표 슬라이드 10장을 만들어줘. 5분 발표용이라 장당 핵심 메시지 1개와 짧은 문장, 숫자 위주로 구성한다.
[필수 규칙]
1. 자리표시자(XX, ○○, 000 등)를 절대 쓰지 마. 수치가 필요하면 plan.md에 적힌 실제 수치를 쓰고, 없으면 그 항목은 빼.
2. 단위경제 슬라이드는 plan.md 5절의 실제 표를 그대로 옮겨(결과물 가격 50만~100만 원, AI 추론비 수백~수천 원에서 수~수십 원, 정상경로 공헌이익률 70~80%) 각 수치에 '가정' 또는 출처를 표시하고, 제목은 plan.md의 결론을 따라 "토큰 1/100은 마진을 거의 바꾸지 않는다, 마진을 정하는 것은 전문가 예외검토비와 정상경로 비중"이라는 취지로 써.
3. 과장 표현 금지: '압도적', '철저히', '혁신적', '확보', '보장' 같은 단정·홍보 문구를 쓰지 마. 해자는 '가설이며 파일럿으로 검증해야 한다'고 써.
4. 출처는 소스에 있는 공공기관·언론·리포트만 표기하고 유튜브 같은 비공식 출처는 인용하지 마.
5. plan.md에 없는 수치는 만들지 마. 판결·법규는 소스 표현 그대로 쓰고 허용 근거로 확대 해석하지 마. 차트는 실제 수치 비율과 맞게 그려.
EOF
  notebooklm generate slide-deck --prompt-file "$LOG/slide_prompt.txt" --format presenter --language ko --wait --timeout 900 --retry 2 -n "$NB" >> "$LOG/slides.log" 2>&1
  notebooklm download slide-deck "$OUT/slides.pdf" -n "$NB" --force >> "$LOG/slides.log" 2>&1
  notebooklm download slide-deck "$OUT/slides.pptx" --format pptx -n "$NB" --force >> "$LOG/slides.log" 2>&1
  [ -s "$OUT/slides.pdf" ] || { echo "슬라이드 다운로드 실패: $LOG/slides.log" >&2; exit 1; }
}
stage slides make_slides

# ---------------------------------------------------------------- 7. 실행 보고
{
  echo "# 자동 실행 보고 ($(date '+%Y-%m-%d %H:%M'))"
  echo; echo "- 아이템: $TOPIC"; echo "- NotebookLM 노트북 ID: $NB"
  echo "- 사용 CLI: nlm(소스·인용 질의), notebooklm(딥 리서치·슬라이드), claude -p(토론·작성·정정)"
  echo; echo "## 산출물"; ls -1 "$OUT" "$DEB" "$RES" | sed 's/^/- /'
  if [ -f "$LOG/claude_calls.csv" ]; then
    echo; echo "## Claude 호출 토큰·비용"; awk -F, 'NR>1{i+=$2;c+=$3;r+=$4;o+=$5;t+=$6;k+=$7;n++} END{printf "- 호출 %d회, 입력 %d + 캐시생성 %d + 캐시읽기 %d, 출력 %d, 턴 %d, 비용 $%.2f\n",n,i,c,r,o,t,k}' "$LOG/claude_calls.csv"
  fi
} > "$OUT/RUN_REPORT.md"
say "완료. 결과: $OUT  (보고서: $OUT/RUN_REPORT.md)"

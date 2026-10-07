# 슬라이드 v1(정정 전) 점검 결과

대상: `output/slides.pdf` (= `slides_v1_정정전.pdf`와 동일). `script.md`와 `plan.md` 기준으로 비교했습니다.

## 발견한 문제
| 슬라이드 | 문제 | 위반한 규칙 |
|---|---|---|
| 9 (단위경제) | 목표 객단가·전환율·전문가 개입률이 모두 `XX`로 남아 있고, 제목에 "철저히", "압도적"이 있음. plan.md §5의 실제 수치(50만~100만 원, 70~80% 등)와 "토큰 1/100은 마진을 거의 바꾸지 않는다"는 결론이 없음 | 자리표시자 금지, 과장 금지, 단위경제 표 그대로 |
| 10 (해자) | "넘을 수 없는 진입장벽", "압도적 경쟁 우위 확보" | 해자는 "가설, 파일럿으로 검증"으로 써야 함 |
| 4 | 출처가 "유튜브 '보증보험 이행청구 거절 당하는 5가지 유형'" | 비공식 출처 금지 |
| 5 | 판례 문구가 "엄격한 법리적 기준" 정도로 요약됨 | 법규는 소스 표현 그대로 |
| 전체 | `script.md`의 9번(토론 반론과 대응: 15/25점), GTM(의견서 → 첫 100건 → 확장/중단), 10번(결론과 미확인 3가지)이 없음. 슬라이드 순서와 구성이 script.md와 다름 | script.md 구성을 그대로 따를 것 |

## `run.sh` 문제 (수정함)
슬라이드 프롬프트 heredoc이 첫 `EOF`에서 끝난 뒤 옛 프롬프트 두 줄과 `EOF`가 명령으로 남아 있었습니다. 제거했고 `bash -n` 문법 검사를 통과했습니다.

## 재생성 방법 (맥북)
정정된 프롬프트는 이미 `run.sh`에 들어 있습니다. 슬라이드 단계만 다시 돌립니다.
```bash
cd ~/Downloads/gcs-assignments
# 이 저장소의 run.sh로 교체한 뒤
rm neofirm/auto/logs/.done_slides neofirm/auto/logs/.sources_added   # 정정본 plan/script/qa를 소스로 다시 추가
NOTEBOOKLM_HOME=$HOME/.notebooklm-py notebooklm login --browser-cookies chrome --account a74658@gachon.ac.kr
./neofirm/run.sh
```
- `.done_slides` 위치는 `run.sh`의 `stage` 함수 기준 확인 필요(로그 폴더 아래 `.done_*`).
- 이 저장소의 `plan.md`에는 이번에 추가한 §9 판정 규칙이 있으므로, 재생성 전에 `neofirm/auto/output/`에 덮어써야 슬라이드에 반영됩니다.
- 재생성 뒤 확인할 것: `XX` 없음, "압도적/철저히/확보/보장" 없음, 유튜브 출처 없음, 슬라이드 9~10에 토론 반론과 결론이 있음.

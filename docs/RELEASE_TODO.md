# 출시 전 채워야 할 값 / 남은 작업

이 문서는 코드로는 결정할 수 없고 **사람이 값을 정해야만** 끝나는 항목만 모읍니다.
코드 쪽 결함과 UI/UX 개선 목록은 별도입니다.

## 1. 개인정보 처리방침 플레이스홀더 (P0)

파일: [`backend/app/legal/privacy_policy_ko.md`](../backend/app/legal/privacy_policy_ko.md)

| 플레이스홀더 | 필요한 값 | 비고 |
|---|---|---|
| `{{시행일: 예 2026-08-01}}` (3행) | 처리방침 시행일 | 문서 상단 |
| `{{시행일}}` (60행) | 위와 같은 날짜 | 문서 하단 |
| `{{담당자명}}` (59행) | 개인정보 보호책임자 성명 | PIPA 필수 기재 |
| `{{연락처_이메일}}` (59행) | 보호책임자 연락처 | PIPA 필수 기재 |

이미 채운 값: `{{서비스명}}` → `Daylog`, `{{디버그_보존일}}` → `7`
(`Settings.debug_runs_retention_days` 기본값과 일치. 그 설정을 바꾸면 문서도 함께 고칠 것.)

**안전장치 (구현됨):** `ENVIRONMENT=production`에서 `{{...}}`가 하나라도 남아 있으면
`GET /legal/privacy-policy`가 **503**을 반환합니다
([`backend/app/routers/legal.py`](../backend/app/routers/legal.py)).
개발 환경 응답에는 `pending_placeholders` 배열이 함께 내려오므로 무엇이 남았는지 바로 보입니다.

**남은 실무:** 값 채운 뒤 변호사/전문가 검토. 문서 상단의 "초안입니다" 배너는
검토가 끝난 뒤에 지울 것. 본문 변경 시
`legal.PRIVACY_POLICY_VERSION`도 함께 올려야 동의 이력이 버전과 맞습니다.

## 2. 릴리스 서명 키스토어 (P0)

파일: [`mobile/android/key.properties.example`](../mobile/android/key.properties.example)

`android/key.properties`를 만들고 `storeFile / storePassword / keyAlias / keyPassword`를 채웁니다.
키스토어 생성 명령은 example 파일 주석에 있습니다.

- `.jks`와 비밀번호는 **5년 뒤에도 갖고 있어야** 합니다. 분실 시 Play 업데이트가 영구 불가능합니다.
- `.gitignore`가 `key.properties`·`*.jks`·`*.keystore`를 이미 제외합니다.
- `key.properties`가 없으면 릴리스는 디버그 키로 서명되고, `bundleRelease`는
  가드에 걸려 실패합니다(로컬 스모크 테스트는 `-PallowDebugSigning=true`).

## 3. 보류 중인 결정 (P0이지만 사용자가 보류)

### 패키지 ID
현재 `com.example.graphrag_mobile` — Play 등록 불가.
보유 도메인이 정해지면 역순 표기로 교체합니다. 변경 시 함께 고쳐야 하는 곳:
- `mobile/android/app/build.gradle.kts` (`namespace`, `applicationId`)
- `mobile/android/app/src/main/kotlin/.../MainActivity.kt` (패키지 선언 + 디렉터리 경로)
- `mobile/ios/Runner.xcodeproj/project.pbxproj` (`PRODUCT_BUNDLE_IDENTIFIER` 3곳)

**주의:** 스토어 등록 후에는 영구히 못 바꿉니다. 등록 전에 확정할 것.

### TTS 공급자
현재 `edge-tts` — Microsoft의 비공식 무료 엔드포인트라 상용 약관/SLA가 없습니다.
선택지: 온디바이스 `flutter_tts`(비용 0, 음질 기기별 상이, 기존 캐시 mp3 무용지물)
또는 Azure Speech(음질·약관 명확, 사용량 과금).

## 4. 운영 계정 화이트리스트

`OPERATOR_HANDLES` 환경변수(기본 `main`)가 개발자 도구를 볼 수 있는 핸들을 정합니다.
서버가 `LearningProfileOut.is_operator`로 내려주며 앱은 그 답만 렌더합니다.
운영진 핸들이 여럿이면 쉼표로 나열하고, 아무도 못 보게 하려면 빈 문자열로 둡니다.

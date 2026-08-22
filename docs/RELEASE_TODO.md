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

이미 채운 값: `{{서비스명}}` → `Daynode`, `{{디버그_보존일}}` → `7`
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

## 3. 보류 중인 결정

### 앱 이름 — Daynode

일기(day)가 지식 그래프의 노드(node)가 된다는 제품 컨셉에서 왔습니다.
`Daylog`에서 교체했습니다 — 동명 앱이 여럿이라 스토어에서 묻힐 이름이었습니다.

웹 검색 기준으로 Play/App Store·상표·회사 모두 충돌이 없었습니다.
**단, 검색은 법적 상표 조사가 아닙니다.** 스토어 등록 전에 Play 스토어 직접 검색과
[KIPRIS](http://www.kipris.or.kr) 국내 상표 검색을 반드시 해보세요.

표시 이름이 들어간 곳(전부 출시 후에도 변경 가능):
`AndroidManifest.xml`의 `android:label`, iOS `CFBundleDisplayName`/`CFBundleName`,
`web/manifest.json`, `web/index.html`, `web/push_sw.js`,
`backend/app/routers/push.py`(알림 제목), Windows `Runner.rc`/`main.cpp`,
처리방침 국·영문 본문.

내부 Dart 패키지명 `graphrag_mobile`은 **일부러 두었습니다** — 168개 import에
걸려 있고 사용자에게 노출되지 않는 식별자입니다. 노출되던 두 곳(iOS `CFBundleName`,
Windows 제품명)만 Daynode로 바꿨습니다.

### 패키지 ID — 확정됨

`io.github.twobitcreat.daynode` (Android `applicationId`/`namespace`, iOS `PRODUCT_BUNDLE_IDENTIFIER`).
`com.example.*`에서 교체 완료. 반영된 곳:

- `mobile/android/app/build.gradle.kts` (`namespace`, `applicationId`)
- `mobile/android/app/src/main/kotlin/io/github/twobitcreat/daynode/MainActivity.kt`
  (패키지 선언 + 디렉터리 경로 이동)
- `mobile/ios/Runner.xcodeproj/project.pbxproj` (`PRODUCT_BUNDLE_IDENTIFIER` 6곳
  — Runner 3곳 + RunnerTests 3곳)

**아직 바꿀 수 있습니다.** 잠기는 시점은 코드가 아니라 **Play Console에 이 ID로
앱을 만들고 AAB를 올리는 순간**입니다. 그 뒤에는 영구히 못 바꾸며, 바꾸려면
새 스토어 등재를 만들어야 해서 설치 수·리뷰가 전부 사라집니다.

사용자에게 보이는 **앱 이름은 별개**입니다(`AndroidManifest.xml`의 `android:label`,
iOS `CFBundleDisplayName` — 둘 다 현재 "Daynode"). 출시 후에도 자유롭게 변경 가능합니다.

> 이 ID를 바꾼다면 **Google OAuth Android 클라이언트**(구글 로그인)도 같이 고쳐야
> 합니다. 그 클라이언트는 패키지명 + 서명 SHA-1로 등록되기 때문입니다.

### TTS 공급자
현재 `edge-tts` — Microsoft의 비공식 무료 엔드포인트라 상용 약관/SLA가 없습니다.
선택지: 온디바이스 `flutter_tts`(비용 0, 음질 기기별 상이, 기존 캐시 mp3 무용지물)
또는 Azure Speech(음질·약관 명확, 사용량 과금).

## 4. 운영 계정 화이트리스트

`OPERATOR_HANDLES` 환경변수(기본 `main`)가 개발자 도구를 볼 수 있는 핸들을 정합니다.
서버가 `LearningProfileOut.is_operator`로 내려주며 앱은 그 답만 렌더합니다.
운영진 핸들이 여럿이면 쉼표로 나열하고, 아무도 못 보게 하려면 빈 문자열로 둡니다.

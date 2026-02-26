# LiveTranslator - 실시간 화상회의 통역 앱

## 목표 개요
화상회의 중 상대방의 영어 음성을 실시간으로 캡처하여 한국어로 번역된 텍스트를 플로팅 오버레이로 보여주는 macOS 네이티브 앱

## 해결하고자 하는 문제 (니즈)
- 화상회의(Zoom, Google Meet 등)에서 영어로 대화하는 상대방의 말을 실시간으로 이해해야 함
- 특정 화상회의 앱에 종속되지 않고, 시스템 오디오를 캡처하여 범용적으로 동작해야 함
- 번역 속도와 정확성을 모두 확보해야 함 (이중 번역 전략)

## 현 상태
- 프로젝트 신규 생성 (코드 없음)

## 솔루션 (목표)

### 기술 스택
- **언어/프레임워크**: Swift, SwiftUI, AppKit (NSPanel)
- **오디오 캡처**: ScreenCaptureKit (macOS 13+, 시스템 오디오 캡처)
- **음성인식 (STT)**: 프로토콜 기반 교체 가능 구조
  - **기본**: Apple Speech Framework (SFSpeechRecognizer) - 무료, 실시간 스트리밍 부분 결과
  - **대안 1**: OpenAI Whisper API - 최고 정확도, 청크 기반
  - **대안 2**: Gemini Live API - 스트리밍 지원, 빠름
- **1차 번역 (초벌)**: Gemini 2.5 Flash Lite (gemini-2.5-flash-lite) - 최고 속도
- **2차 번역 (재벌)**: Gemini 3 Pro Preview (gemini-3-pro-preview) - 맥락 기반 정교 번역
- **사용자 보유 API 키**: OpenAI, Gemini, Claude (DeepL 없음)

### 아키텍처

```
[시스템 오디오] → [ScreenCaptureKit] → [Audio Buffer]
                                            ↓
                                   [STT Provider (교체 가능)]
                                   (Apple Speech / Whisper / Gemini Live)
                                     ↓ (부분 결과)              ↓ (문장 완성)
                           [gemini-2.5-flash-lite]    [gemini-3-pro-preview]
                              초벌 번역                  맥락 기반 재벌 번역
                                     ↓                         ↓
                              [UI: 초벌 표시]          [UI: 재벌로 교체]
```

### UI 설계
- **플로팅 패널**: NSPanel (always on top, 드래그 가능, 반투명 배경)
- **크기**: 약 400x300pt, 리사이즈 가능
- **내용**: 스크롤 가능한 리스트, 각 항목에 원문(영어) + 번역(한국어) 표시
- **번역 상태 표시**: 초벌 번역은 연한 색, 재벌 완료 시 진한 색으로 전환
- **컨트롤**: 시작/정지 버튼, 설정 버튼 (메뉴바 아이콘에서도 접근)

## 비목표 - 하면 안 되는 것
- 마이크 입력 캡처 (시스템 오디오만 캡처)
- 화상회의 앱별 특수 연동 (범용 시스템 오디오 캡처만)
- 번역 결과 파일 저장/내보내기
- App Store 배포를 위한 샌드박싱

## 비목표 - 범위 밖이지만 추후 가능
- 다국어 지원 (현재는 EN→KO만)
- 폰트 크기/테마 커스터마이징
- 번역 로그 저장/내보내기
- 화자 구분 (다중 화자 식별)

## 확정된 주요 의사결정 사항
1. **오디오 캡처**: ScreenCaptureKit 사용 (가상 오디오 드라이버 불필요, macOS 13+ 필요)
2. **STT**: 프로토콜 기반 교체 가능 (기본: Apple Speech, 대안: Whisper API, Gemini Live API)
3. **이중 번역**: gemini-2.5-flash-lite(초벌, 1초 이내) + gemini-3-pro-preview(재벌, 3초 이내)
4. **UI**: NSPanel 기반 플로팅 오버레이
5. **빌드**: Xcode 프로젝트 (XcodeGen으로 생성)
6. **API 키 관리**: 앱 내 설정에서 입력, UserDefaults에 저장 (개인 사용 용도)
7. **보유 API 키**: OpenAI, Gemini, Claude (DeepL 없음)

## 상세 실행 계획

### Task 1: 프로젝트 구조 및 기본 앱 셸 (의존: 없음)
- Xcode 프로젝트 구조 생성 (XcodeGen 또는 수동)
- SwiftUI App 진입점
- 메뉴바 아이콘 + 플로팅 패널 기본 구조
- Info.plist (권한 설정: 화면 녹화 권한 설명)
- 빌드 확인

### Task 2: 시스템 오디오 캡처 서비스 (의존: Task 1)
- ScreenCaptureKit을 이용한 시스템 오디오 캡처
- 오디오 버퍼를 PCM 포맷으로 변환
- 시작/정지 제어
- 권한 요청 처리

### Task 3: 음성인식(STT) 서비스 (의존: Task 2)
- STTProvider 프로토콜 정의 (교체 가능 구조)
- Apple Speech 구현: SFSpeechRecognizer 실시간 영어 음성인식, 부분 결과 콜백, 문장 완성 감지
- OpenAI Whisper 구현: 오디오 청크 → Whisper API, 정확한 전사
- Gemini Live 구현: 스트리밍 오디오 → Gemini Live API, 실시간 전사
- 설정에서 STT 제공자 선택 가능

### Task 4: 번역 서비스 (의존: 없음, Task 3과 병렬 가능)
- Gemini API 공통 클라이언트
- 초벌 번역: gemini-2.5-flash-lite (빠른 단어/구 단위 번역)
- 재벌 번역: gemini-3-pro-preview (맥락 포함 문장 단위 번역)
- 맥락 관리 (최근 N개 문장 유지)
- 에러 처리 및 타임아웃

### Task 5: 이중 번역 오케스트레이터 (의존: Task 3, Task 4)
- STT 부분 결과 → 초벌 번역 트리거
- 문장 완성 → 재벌 번역 트리거
- 번역 결과를 TranslationEntry 모델에 반영
- 디바운싱 (너무 짧은 부분 결과는 스킵)

### Task 6: UI 구현 (의존: Task 1, Task 5)
- 플로팅 패널 (NSPanel, always on top, 드래그)
- 번역 항목 리스트 (원문 + 번역, 스크롤)
- 초벌/재벌 상태 시각적 구분
- 시작/정지 토글
- API 키 설정 화면
- 메뉴바 아이콘

### Task 7: 통합 및 전체 파이프라인 연결 (의존: Task 2~6)
- 전체 파이프라인 연결: 오디오 → STT → 번역 → UI
- 에러 핸들링 통합
- 앱 상태 관리 (시작/정지/에러)

## 상세 검증 계획

### V1: 빌드 검증
- Xcode 프로젝트가 정상적으로 빌드되는지 확인
- 앱이 실행되고 메뉴바 아이콘이 표시되는지 확인

### V2: 오디오 캡처 검증
- 시스템 오디오가 정상적으로 캡처되는지 확인
- 권한 요청이 정상적으로 동작하는지 확인

### V3: STT 검증
- 영어 음성이 텍스트로 변환되는지 확인
- 부분 결과가 실시간으로 전달되는지 확인

### V4: 번역 검증
- gemini-2.5-flash-lite 초벌 번역이 1초 이내에 응답하는지 확인
- gemini-3-pro-preview 재벌 번역이 3초 이내에 응답하는지 확인
- 번역 품질이 적절한지 확인

### V5: UI 검증
- 플로팅 패널이 항상 위에 표시되는지 확인
- 드래그가 정상 동작하는지 확인
- 번역 결과가 실시간으로 표시되는지 확인
- 초벌/재벌 전환이 시각적으로 구분되는지 확인

### V6: 전체 파이프라인 검증
- 실제 화상회의 시나리오에서 end-to-end 동작 확인
- 응답 속도 요구사항 충족 확인 (초벌 1초, 재벌 3초)

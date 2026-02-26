import Foundation
import AVFoundation

/// STT 관련 에러 정의
enum STTError: LocalizedError {
    case recognitionNotAvailable
    case permissionDenied
    case recognitionFailed(Error)
    case apiKeyMissing
    case networkError(Error)
    case audioEncodingFailed
    case connectionFailed(Error)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .recognitionNotAvailable:
            return "음성 인식을 사용할 수 없습니다."
        case .permissionDenied:
            return "음성 인식 권한이 거부되었습니다."
        case .recognitionFailed(let error):
            return "음성 인식 실패: \(error.localizedDescription)"
        case .apiKeyMissing:
            return "API 키가 설정되지 않았습니다."
        case .networkError(let error):
            return "네트워크 에러: \(error.localizedDescription)"
        case .audioEncodingFailed:
            return "오디오 인코딩에 실패했습니다."
        case .connectionFailed(let error):
            return "연결 실패: \(error.localizedDescription)"
        case .invalidResponse:
            return "서버 응답이 유효하지 않습니다."
        }
    }
}

/// STT(Speech-to-Text) 제공자 프로토콜
/// 모든 STT 구현체는 이 프로토콜을 준수해야 한다.
protocol STTProvider: AnyObject {
    /// 프로바이더 이름
    var name: String { get }

    /// 현재 인식 중인지 여부
    var isRecognizing: Bool { get }

    /// 음성 인식을 시작한다.
    func startRecognition() async throws

    /// 음성 인식을 정지한다.
    func stopRecognition()

    /// 오디오 버퍼를 STT 엔진에 전달한다.
    /// AudioCaptureService의 onAudioPCMBuffer 콜백에서 호출된다.
    /// - Parameter buffer: PCM 포맷의 오디오 버퍼
    func feedAudioBuffer(_ buffer: AVAudioPCMBuffer)

    /// 부분 결과 콜백 (실시간 업데이트)
    var onPartialResult: ((String) -> Void)? { get set }

    /// 문장 완성 콜백
    var onFinalResult: ((String) -> Void)? { get set }

    /// 에러 콜백
    var onError: ((Error) -> Void)? { get set }
}

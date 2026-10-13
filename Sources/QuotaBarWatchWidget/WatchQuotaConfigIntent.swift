import AppIntents
import WidgetKit

// MARK: - 구성 (표시할 쿼터 선택)

/// 컴플리케이션 구성. watchOS는 파라미터 편집 UI가 없어 recommendations()로만 값이 정해진다.
/// AppEntity 파라미터를 추천에 넣으면 WidgetKit이 추천을 만들다가 익스텐션이 크래시하므로(→ 위젯 전체가 목록에서 사라짐)
/// 단순 String/Bool 파라미터만 쓴다.
///
/// 이 파일은 워치 위젯 익스텐션과 워치 앱 두 타깃에 모두 들어간다. 시스템이 페이스에 저장된 구성을
/// 위젯에 넘길 때 앱 번들의 App Intents 메타데이터를 참조할 수 있어, 앱에 없으면 구성된
/// 컴플리케이션이 타임라인을 받지 못하고 placeholder로만 남는다.
struct WatchQuotaConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "QuotaBar 설정"
    static var description = IntentDescription("컴플리케이션에 표시할 쿼터를 선택합니다.")

    /// 표시할 쿼터 id ("<accountID>::<quotaKey>", 스냅샷과 동일). nil이면 가장 높은 사용률.
    @Parameter(title: "쿼터 ID")
    var quotaID: String?

    /// 모든 쿼터를 번갈아 표시
    @Parameter(title: "전체 순환", default: false)
    var rotateAll: Bool
}

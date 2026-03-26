import Foundation

enum Strings {
    // MARK: - Wizard
    enum Wizard {
        static let welcomeTitle = "Hayabusa へようこそ"
        static let welcomeSubtitle = "Apple Silicon で動く高速AIサーバー"
        static let welcomeDescription = "病院内のMacでAIを安全に使えるようにします。\nインターネット不要で、患者データは外部に出ません。"
        static let getStarted = "はじめる"

        static let modelSelectTitle = "AIモデルを選択"
        static let modelSelectDescription = "お使いのMacに合ったモデルを選んでください"

        static let modelInstalledTab = "インストール済み"
        static let modelDownloadTab = "新しくダウンロード"
        static let modelNoneInstalled = "インストール済みのモデルが見つかりません"

        static let modelLightName = "軽量モデル"
        static let modelLightDescription = "メモリ8GBのMacで動作"
        static let modelLightDetail = "簡単な質問応答に最適"
        static let modelLightMemory = "必要メモリ: 4GB"

        static let modelRecommendedName = "おすすめモデル"
        static let modelRecommendedDescription = "メモリ16GBのMacに最適"
        static let modelRecommendedDetail = "日常業務での利用に推奨"
        static let modelRecommendedMemory = "必要メモリ: 8GB"
        static let modelRecommendedBadge = "おすすめ"

        static let modelHighName = "高性能モデル"
        static let modelHighDescription = "メモリ32GB以上のMacで動作"
        static let modelHighDetail = "高度な分析・文書作成に最適"
        static let modelHighMemory = "必要メモリ: 20GB"

        static let downloadTitle = "モデルをダウンロード中"
        static let downloadProgress = "ダウンロード中..."
        static let downloadRemaining = "残り約%@"
        static let downloadCancel = "キャンセル"
        static let downloadRetry = "再試行"
        static let downloadComplete = "ダウンロード完了"

        static let clusterTitle = "接続設定"
        static let clusterDescription = "他のMacと連携してAIの処理能力を上げることができます"
        static let clusterStandalone = "このMacだけで使う"
        static let clusterStandaloneDescription = "1台のMacで動作します"
        static let clusterConnect = "他のMacと連携する"
        static let clusterConnectDescription = "複数のMacでAI処理を分散します"
        static let clusterScanning = "周辺のMacを探しています..."
        static let clusterFound = "%d台のMacが見つかりました"
        static let clusterNoneFound = "他のMacが見つかりませんでした"
        static let clusterConnectButton = "接続"

        static let completeTitle = "セットアップ完了"
        static let completeDescription = "準備が整いました。サーバーを起動しましょう。"
        static let startServer = "サーバーを起動"
        static let serverStarted = "サーバーが起動しました"
        static let skipStart = "あとで起動する"
        static let closeWindow = "閉じる"

        static let back = "戻る"
        static let next = "次へ"
    }

    // MARK: - Dashboard
    enum Dashboard {
        static let serverRunning = "サーバー稼働中"
        static let serverStopped = "サーバー停止中"
        static let serverStarting = "サーバー起動中..."
        static let serverError = "サーバーエラー"

        static let startButton = "サーバーを起動"
        static let stopButton = "サーバーを停止"

        static let statusComfortable = "快適"
        static let statusModerate = "混雑"
        static let statusBusy = "混み合っています"

        static let activeConnections = "接続中のアプリ"
        static let clusterNodes = "クラスターノード"
        static let tokensPerSecond = "トークン/秒"

        static let advancedMode = "上級者モード"
        static let simpleMode = "かんたんモード"
    }

    // MARK: - Errors
    enum Errors {
        static let downloadFailed = "ダウンロードに失敗しました"
        static let downloadFailedDetail = "ネットワーク接続を確認して、もう一度お試しください。"
        static let serverStartFailed = "サーバーの起動に失敗しました"
        static let modelNotFound = "モデルファイルが見つかりません"
        static let binaryNotFound = "Hayabusa本体が見つかりません"
        static let clusterConnectionFailed = "接続に失敗しました"
    }

    // MARK: - Update
    enum Update {
        static let available = "新しいバージョンがあります"
        static let updateNow = "今すぐ更新"
        static let later = "あとで"
    }
}
